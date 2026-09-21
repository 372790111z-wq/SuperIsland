import AppKit
import Foundation
import UniformTypeIdentifiers

enum ShelfZIPInputResult {
    case file(ShelfItem)
    case unsupported
    case unavailable
}

/// Resolves only existing local files. Unlike ordinary Shelf intake, this path
/// never creates an image file or converts a text snippet into a new document.
@MainActor
enum ShelfZIPDropLoader {
    static func load(
        _ provider: NSItemProvider, existingItems: [ShelfItem],
        timeout: TimeInterval = 5
    ) async -> ShelfZIPInputResult {
        let localType = ShelfStore.localItemTypeIdentifier
        ShelfDropDiagnostics.record("zip.provider", destination: "zip", values: [
            "local": provider.hasItemConformingToTypeIdentifier(localType) ? 1 : 0,
            "types": Int64(provider.registeredTypeIdentifiers.count)
        ])
        if provider.hasItemConformingToTypeIdentifier(localType),
           let value = await localIdentity(provider, type: localType, timeout: timeout),
           let id = UUID(uuidString: value),
           let item = existingItems.first(where: { $0.id == id }) {
            ShelfDropDiagnostics.record("zip.identity", destination: "zip", code: "matched")
            return item.isFileBacked ? .file(item) : .unsupported
        }

        // Finder's text documents can advertise text while returning NSURL.
        // Select one representation; never read file contents as an archive input.
        let types = [UTType.fileURL, .url, .utf8PlainText, .plainText, .text]
        guard let type = types.first(where: {
            provider.hasItemConformingToTypeIdentifier($0.identifier)
        }) else { return .unsupported }
        guard let value = await payload(provider, type: type.identifier, timeout: timeout) else {
            return .unavailable
        }
        let url: URL?
        if let value = value as? URL {
            url = value
        } else if let data = value as? Data, type == .fileURL || type == .url {
            url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let value = value as? String, type == .fileURL || type == .url {
            url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            url = nil
        }
        guard let url, url.isFileURL else { return .unsupported }
        // SwiftUI may omit own-process representations when bridging a drag.
        // Match the original URL exactly to retain managed-image names and
        // bookmarks. Never use basenames or a stale pre-move stored path.
        if let existing = existingItems.first(where: {
            $0.isFileBacked &&
            $0.resolvedFileURL?.standardizedFileURL.path == url.standardizedFileURL.path
        }) {
            return .file(existing)
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return .file(.file(from: url))
    }

    private static func localIdentityString(_ value: NSSecureCoding) -> String? {
        // The native pasteboard bridge can turn our UTF-8 Data into NSString.
        // Both forms carry the same opaque identity; rejecting the string form
        // would fall back to SwiftUI's materialized file in its Drag cache.
        if let value = value as? String { return value }
        if let data = value as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    private static func localIdentity(_ provider: NSItemProvider, type: String,
                                      timeout: TimeInterval) async -> String? {
        // Read the representation we registered. For pasteboard-backed custom
        // types, loadItem may hand back a materialized file URL instead of bytes.
        let data: Data? = await withCheckedContinuation { continuation in
            let request = ShelfZIPProviderRequest(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                request.finish(nil)
            }
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                request.finish(error == nil ? data as NSData? : nil)
            }
        } as? Data
        if let data, let value = String(data: data, encoding: .utf8), UUID(uuidString: value) != nil {
            ShelfDropDiagnostics.record("zip.identity.data", destination: "zip", code: "valid")
            return value
        }
        let item = await payload(provider, type: type, timeout: timeout)
        ShelfDropDiagnostics.record("zip.identity.fallback", destination: "zip", values: [
            "data": item is Data ? 1 : 0, "string": item is String ? 1 : 0,
            "url": item is URL ? 1 : 0
        ])
        return item.flatMap(localIdentityString)
    }

    private static func payload(
        _ provider: NSItemProvider, type: String, timeout: TimeInterval
    ) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            let request = ShelfZIPProviderRequest(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                request.finish(nil)
            }
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                request.finish(error == nil ? value : nil)
            }
        }
    }
}

private final class ShelfZIPProviderRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NSSecureCoding?, Never>?
    init(_ continuation: CheckedContinuation<NSSecureCoding?, Never>) {
        self.continuation = continuation
    }
    func finish(_ value: NSSecureCoding?) {
        lock.lock()
        let saved = continuation
        continuation = nil
        lock.unlock()
        saved?.resume(returning: value)
    }
}

final class ShelfZIPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// UI state is MainActor-owned. File traversal, deflate and verification are
/// confined to a utility task; a security scope lives for that whole operation.
@MainActor
final class ShelfZIPCoordinator: ObservableObject {
    typealias Archive = @Sendable (URL, URL, String?, ShelfZIPCancellation) throws -> URL
    typealias DirectoryPicker = @MainActor (@escaping @MainActor (URL?) -> Void) -> Void

    static let shared = ShelfZIPCoordinator(
        existingItems: { ShelfStore.shared.items },
        addResults: { _ = ShelfStore.shared.add($0) },
        didReceive: { AppState.shared.presentShelfAfterDrop() }
    )

    @Published private(set) var title = "ZIP 压缩"
    @Published private(set) var detail = "拖放以压缩"
    @Published private(set) var isBusy = false
    @Published private(set) var progress: Double?
    @Published private(set) var canCancel = false
    @Published private(set) var canRetryFailed = false
    @Published private(set) var canChooseOutputDirectory = false

    private struct Failure {
        let item: ShelfItem?
        let message: String
        let canChangeDirectory: Bool
    }
    private let existingItems: () -> [ShelfItem]
    private let addResults: ([ShelfItem]) -> Void
    private let didReceive: () -> Void
    private let archive: Archive
    private let pickDirectory: DirectoryPicker
    private var operation: Task<Void, Never>?
    private var cancellation: ShelfZIPCancellation?
    private var failures: [Failure] = []
    private var completedCount = 0
    private var lastOutputDirectory: URL?
    private var lastOnlyManaged = true
    private var pending: [ShelfItem] = []
    private var pickerGeneration = UUID()

    init(
        existingItems: @escaping () -> [ShelfItem] = { [] },
        addResults: @escaping ([ShelfItem]) -> Void = { _ in },
        didReceive: @escaping () -> Void = {},
        archive: @escaping Archive = { source, directory, name, cancellation in
            try ShelfZIPArchive.create(
                source: source, outputDirectory: directory, preferredName: name,
                isCancelled: { cancellation.isCancelled }
            )
        },
        pickDirectory: @escaping DirectoryPicker = ShelfZIPCoordinator.openDirectoryPicker
    ) {
        self.existingItems = existingItems
        self.addResults = addResults
        self.didReceive = didReceive
        self.archive = archive
        self.pickDirectory = pickDirectory
    }

    /// Claim the destination even for unsupported/busy inputs so a rejected ZIP
    /// drop can never fall through to the outer island's ordinary Shelf intake.
    @discardableResult
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return true }
        guard !isBusy else { return true }
        beginReceiving()
        let token = cancellation!
        operation = Task { [weak self] in
            guard let self else { return }
            var inputs: [ShelfItem] = []
            for (index, provider) in providers.enumerated() {
                guard !token.isCancelled else { break }
                let result = await ShelfZIPDropLoader.load(provider, existingItems: existingItems())
                guard !token.isCancelled else { break }
                switch result {
                case .file(let item): inputs.append(item)
                case .unsupported:
                    failures.append(Failure(item: nil,
                        message: "第 \(index + 1) 项不是本地文件，未压缩。", canChangeDirectory: false))
                case .unavailable:
                    failures.append(Failure(item: nil,
                        message: "第 \(index + 1) 项未能读取，请重新拖入。", canChangeDirectory: false))
                }
            }
            if token.isCancelled { finish(cancelled: true); return }
            // One drag may repeat a file representation. Compress its identity
            // once per drop, but allow a later genuine drop to create (1), (2).
            var seen = Set<String>()
            inputs = inputs.filter { seen.insert($0.dedupeKey).inserted }
            prepare(inputs, token: token)
        }
        return true
    }

    func cancel() {
        guard canCancel else { return }
        cancellation?.cancel()
        title = "正在取消"
        detail = "正在清理未完成的压缩包"
        canCancel = false
    }

    func retryFailed() {
        guard !isBusy else { return }
        let retry = failures.compactMap(\.item)
        guard !retry.isEmpty else { return }
        failures.removeAll { $0.item != nil }
        beginRetry()
        let token = cancellation!
        run(retry, outputDirectory: lastOutputDirectory, onlyManaged: lastOnlyManaged, token: token)
    }

    func chooseOutputDirectory() {
        guard !isBusy else { return }
        // An explicitly chosen replacement directory applies to all currently
        // failed files, including a read failure the user may already have fixed.
        // Successful files are never retried or moved.
        let retry = failures.compactMap(\.item)
        guard !retry.isEmpty else { return }
        beginRetry()
        chooseDirectory(for: retry, retrying: true)
    }

    private func beginReceiving() {
        failures = []
        completedCount = 0
        lastOutputDirectory = nil
        lastOnlyManaged = true
        beginRetry()
        title = "正在接收"
        detail = "读取拖入的文件"
        didReceive()
    }

    private func beginRetry() {
        isBusy = true
        canCancel = true
        canRetryFailed = false
        canChooseOutputDirectory = false
        progress = nil
        cancellation = ShelfZIPCancellation()
    }

    private func prepare(_ items: [ShelfItem], token: ShelfZIPCancellation) {
        guard !items.isEmpty else { finish(cancelled: false); return }
        if items.contains(where: { $0.resolvedFileURL.map(ShelfStore.isManagedImageURL) ?? false }) {
            chooseDirectory(for: items, retrying: false)
        } else {
            run(items, outputDirectory: nil, onlyManaged: true, token: token)
        }
    }

    private func chooseDirectory(for items: [ShelfItem], retrying: Bool) {
        pending = items
        isBusy = true
        canCancel = false
        title = "选择保存位置"
        detail = retrying ? "为未完成的文件选择目录" : "为粘贴图片选择目录"
        progress = nil
        let generation = UUID()
        pickerGeneration = generation
        pickDirectory { [weak self] url in
            guard let self, pickerGeneration == generation else { return }
            let items = pending
            pending = []
            guard let url else { finish(cancelled: true); return }
            if retrying {
                let keys = Set(items.map(\.dedupeKey))
                failures.removeAll { $0.item.map { keys.contains($0.dedupeKey) } ?? false }
            }
            lastOutputDirectory = url
            lastOnlyManaged = !retrying
            canCancel = true
            let token = cancellation ?? ShelfZIPCancellation()
            cancellation = token
            run(items, outputDirectory: url, onlyManaged: !retrying, token: token)
        }
    }

    private func run(
        _ items: [ShelfItem], outputDirectory: URL?, onlyManaged: Bool,
        token: ShelfZIPCancellation
    ) {
        let worker = archive
        operation = Task { [weak self] in
            guard let self else { return }
            // Retain a user-selected destination grant through the entire batch.
            let destinationAccess = outputDirectory?.startAccessingSecurityScopedResource() ?? false
            defer {
                if destinationAccess { outputDirectory?.stopAccessingSecurityScopedResource() }
            }
            for (index, item) in items.enumerated() {
                guard !token.isCancelled else { break }
                title = "正在压缩 \(index + 1)/\(items.count)"
                detail = item.displayName
                progress = items.count > 1 ? Double(index) / Double(items.count) : nil
                guard let source = Self.sourceURL(for: item) else {
                    failures.append(Failure(item: item, message: "\(item.displayName)：原文件不可用。",
                                            canChangeDirectory: false))
                    continue
                }
                let managed = ShelfStore.isManagedImageURL(source)
                let destination = (!onlyManaged || managed) ? outputDirectory : nil
                let directory = destination ?? source.deletingLastPathComponent()
                let preferredName = managed ? item.displayName : nil
                let outcome = await Task.detached(priority: .utility) {
                    let sourceAccess = source.startAccessingSecurityScopedResource()
                    defer { if sourceAccess { source.stopAccessingSecurityScopedResource() } }
                    return Result { try worker(source, directory, preferredName, token) }
                }.value
                switch outcome {
                case .success(let url):
                    // An atomic publication that completed just before Cancel
                    // remains a valid output and must still be listed.
                    let item = ShelfItem.file(from: url)
                    addResults([item])
                    completedCount += 1
                case .failure(let error):
                    if !token.isCancelled {
                        failures.append(Failure(item: item,
                            message: "\(item.displayName)：\(error.localizedDescription)",
                            canChangeDirectory: Self.isOutputError(error)))
                    }
                }
            }
            finish(cancelled: token.isCancelled)
        }
    }

    private func finish(cancelled: Bool) {
        isBusy = false
        canCancel = false
        progress = nil
        operation = nil
        cancellation = nil
        canRetryFailed = failures.contains { $0.item != nil }
        canChooseOutputDirectory = failures.contains(where: \.canChangeDirectory)
        if cancelled {
            title = "已取消"
            detail = completedCount > 0 ? "已完成的 \(completedCount) 个 ZIP 已保留" : "未生成 ZIP，原文件保留"
        } else if !failures.isEmpty {
            title = completedCount > 0 ? "已完成 \(completedCount) 项，\(failures.count) 项失败" : "未能压缩"
            detail = failures.map(\.message).joined(separator: "\n")
        } else {
            title = completedCount == 1 ? "已压缩" : "已压缩 \(completedCount) 项"
            detail = "已加入暂存架"
        }
    }

    private static func isOutputError(_ error: Error) -> Bool {
        if let failure = error as? ShelfZIPArchive.Failure {
            switch failure {
            case .outputUnwritable, .outputFailure: return true
            default: return false
            }
        }
        let cocoa = error as NSError
        return cocoa.domain == NSCocoaErrorDomain &&
            [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(cocoa.code)
    }

    private static func sourceURL(for item: ShelfItem) -> URL? {
        // Bookmark resolution may follow a top-level symlink. Preserve its
        // original identity so the archive engine can reject it explicitly.
        if let path = item.path,
           let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return URL(fileURLWithPath: path)
        }
        return item.resolvedFileURL
    }

    private static func openDirectoryPicker(completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "ZIP 保存位置"
        panel.message = "选择保存 ZIP 的文件夹"
        panel.prompt = "在此压缩"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            MainActor.assumeIsolated { completion(response == .OK ? panel.url : nil) }
        }
    }
}
