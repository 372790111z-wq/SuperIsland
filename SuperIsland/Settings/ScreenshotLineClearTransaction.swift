import AppKit
import Foundation
import Darwin

/// File work runs off the main actor. Journals describe only explicitly selected
/// cards; recovery restores staged files and never resumes destructive work.
final class ScreenshotLineClearTransaction: @unchecked Sendable {
    struct Stamp: Codable, Equatable, Hashable, Sendable {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var modified: Int64
        var modifiedNS: Int64
        var changed: Int64
        var changedNS: Int64
        var identity: String { "\(device):\(inode)" }
        static func read(_ url: URL, regular: Bool = true) throws -> Stamp {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let type = info.st_mode & S_IFMT
            guard type == (regular ? S_IFREG : S_IFDIR), !regular || info.st_nlink == 1 else { throw Failure.unsafePath }
            return Stamp(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: info.st_size,
                         modified: Int64(info.st_mtimespec.tv_sec), modifiedNS: Int64(info.st_mtimespec.tv_nsec),
                         changed: Int64(info.st_ctimespec.tv_sec), changedNS: Int64(info.st_ctimespec.tv_nsec))
        }
        // Moving a file changes ctime, but must not change its identity/content.
        func sameContent(as other: Stamp) -> Bool {
            device == other.device && inode == other.inode && size == other.size
                && modified == other.modified && modifiedNS == other.modifiedNS
        }
    }
    struct Selection: Sendable {
        let items: [ScreenshotLineItem]
        let stamp: Stamp?
        let root: URL?
        let rootIdentity: String?
        let error: String?
    }
    struct Plan: Sendable { let selections: [Selection]; let count: Int }
    struct Outcome: Sendable {
        var removed: [ScreenshotLineItem] = []
        var moved = 0
        var missing = 0
        var journal: UUID?
        var error: String?
    }
    struct Recovery: Sendable {
        var removed: [ScreenshotLineItem] = []
        var journals: [UUID] = []
        var restored = 0
        var uncertain = 0
        var errors: [String] = []
    }
    struct Entry: Codable {
        enum Phase: String, Codable { case prepared, staged, moved, reference }
        var id: UUID
        var items: [ScreenshotLineItem]
        var stamp: Stamp?
        var root: URL?
        var rootIdentity: String?
        var stageName: String?
        var phase: Phase
    }
    enum Failure: Error, LocalizedError {
        case unsafePath, changed, writing, invalidJournal, restore, busy
        var errorDescription: String? {
            switch self {
            case .unsafePath: "无法确认托管文件边界或文件包含链接，已保留。"
            case .changed: "文件在确认后发生变化，已保留，请重试。"
            case .writing: "文件仍在写入或编辑，已保留，请稍后重试。"
            case .invalidJournal: "清理恢复记录不可用，未继续清理。"
            case .restore: "待恢复文件已保留，请重试恢复；没有继续删除。"
            case .busy: "项目正在使用，已保留，请稍后重试。"
            }
        }
    }
    let support: URL
    let roots: [URL]
    let directory: URL
    private let trash: @Sendable (URL) throws -> Void
    private let save: @Sendable (Data, URL) throws -> Void

    init(support: URL, roots: [URL],
         trash: @escaping @Sendable (URL) throws -> Void = { url in
             try FileManager.default.trashItem(at: url, resultingItemURL: nil)
         }, save: @escaping @Sendable (Data, URL) throws -> Void = ScreenshotLineClearTransaction.durableWrite) {
        self.support = support
        self.roots = roots
        directory = support.appendingPathComponent("ClearTransactions", isDirectory: true)
        self.trash = trash
        self.save = save
    }

    static func durableWrite(_ data: Data, _ url: URL) throws {
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.EACCES) }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw POSIXError(.EIO) }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
    }
    private func ensureDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        _ = try Stamp.read(directory, regular: false)
        guard chmod(directory.path, 0o700) == 0 else { throw Failure.invalidJournal }
    }
    private func journalURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func write(_ entry: Entry) throws {
        try ensureDirectory()
        try save(JSONEncoder().encode(entry), journalURL(entry.id))
    }
    func acknowledge(_ ids: [UUID]) throws {
        for id in ids {
            let url = journalURL(id)
            if FileManager.default.fileExists(atPath: url.path) {
                let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
                if let stage = try stageURL(entry) {
                    let folder = stage.deletingLastPathComponent()
                    if FileManager.default.fileExists(atPath: folder.path) {
                        _ = try Stamp.read(folder, regular: false)
                        guard try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty else { throw Failure.restore }
                        try FileManager.default.removeItem(at: folder)
                    }
                }
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    var hasRecovery: Bool {
        // A malformed/non-directory path is also a recovery obligation.
        FileManager.default.fileExists(atPath: directory.path)
            && ((try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) != true)
    }
    private func rootFor(_ url: URL) throws -> (URL, Stamp) {
        let path = url.standardizedFileURL.path
        guard let root = roots.first(where: { path.hasPrefix($0.standardizedFileURL.path + "/") }) else { throw Failure.unsafePath }
        let stamp = try Stamp.read(root, regular: false)
        guard root.standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL,
              url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { throw Failure.unsafePath }
        return (root, stamp)
    }
    private func validate(_ selection: Selection) throws -> Stamp {
        guard let item = selection.items.first, let expectedRoot = selection.root,
              let expectedIdentity = selection.rootIdentity else { throw Failure.unsafePath }
        let (root, stamp) = try rootFor(item.url)
        guard root == expectedRoot, stamp.identity == expectedIdentity else { throw Failure.changed }
        return try Stamp.read(item.url)
    }

    func plan(_ items: [ScreenshotLineItem], busyIDs: Set<UUID>, now: Date = Date()) -> Plan {
        // An external reference to the same inode always protects that file.
        let external = Set(items.filter { !$0.owned }.compactMap { try? Stamp.read($0.url.resolvingSymlinksInPath()).identity })
        var selections: [Selection] = []
        for item in items {
            do {
                guard !busyIDs.contains(item.id) else { throw Failure.busy }
                if !item.owned {
                    selections.append(.init(items: [item], stamp: nil, root: nil, rootIdentity: nil, error: nil)); continue
                }
                let (root, rootStamp) = try rootFor(item.url)
                let stamp: Stamp
                do { stamp = try Stamp.read(item.url) }
                catch let error as POSIXError where error.code == .ENOENT {
                    // Root/ancestors are verified; a missing owned file is a stale reference.
                    selections.append(.init(items: [item], stamp: nil, root: root, rootIdentity: rootStamp.identity, error: nil)); continue
                }
                if external.contains(stamp.identity) {
                    selections.append(.init(items: [item], stamp: nil, root: nil, rootIdentity: nil, error: nil)); continue
                }
                guard now.timeIntervalSince1970 - Double(stamp.modified) - Double(stamp.modifiedNS) / 1e9 >= 1 else { throw Failure.writing }
                if let index = selections.firstIndex(where: { $0.stamp?.identity == stamp.identity && $0.error == nil }) {
                    let old = selections[index]
                    selections[index] = .init(items: old.items + [item], stamp: old.stamp, root: old.root, rootIdentity: old.rootIdentity, error: nil)
                } else {
                    selections.append(.init(items: [item], stamp: stamp, root: root, rootIdentity: rootStamp.identity, error: nil))
                }
            } catch {
                selections.append(.init(items: [item], stamp: nil, root: nil, rootIdentity: nil, error: error.localizedDescription))
            }
        }
        return Plan(selections: selections, count: items.count)
    }

    func execute(_ selection: Selection) -> Outcome {
        if let error = selection.error { return Outcome(error: error) }
        guard let item = selection.items.first else { return Outcome() }
        var entry = Entry(id: UUID(), items: selection.items, stamp: selection.stamp, root: selection.root,
                          rootIdentity: selection.rootIdentity, stageName: nil, phase: .reference)
        var moved = false
        do {
            if selection.stamp == nil {
                if selection.root != nil {
                    let (root, stamp) = try rootFor(item.url)
                    guard root == selection.root, stamp.identity == selection.rootIdentity else { throw Failure.changed }
                    var info = stat()
                    guard lstat(item.path, &info) != 0, errno == ENOENT else { throw Failure.changed }
                }
                try write(entry)
                return Outcome(removed: selection.items, missing: selection.root == nil ? 0 : selection.items.count, journal: entry.id)
            }
            guard try validate(selection) == selection.stamp else { throw Failure.changed }
            entry.phase = .prepared
            entry.stageName = ".sc2-clear-" + entry.id.uuidString
            try write(entry) // Durable intent before any filesystem side effect.
            let stagingFolder = item.url.deletingLastPathComponent().appendingPathComponent(entry.stageName!, isDirectory: true)
            try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let stage = stagingFolder.appendingPathComponent(item.url.lastPathComponent)
            var coordinationError: NSError?
            var operationError: Error?
            NSFileCoordinator().coordinate(writingItemAt: item.url, options: .forMoving, error: &coordinationError) { coordinated in
                do {
                    guard coordinated.standardizedFileURL == item.url.standardizedFileURL,
                          try self.validate(selection) == selection.stamp else { throw Failure.changed }
                    // Exclusive rename keeps the operation on the same volume. The
                    // post-rename identity check precedes Trash, including ctime changes.
                    try self.renameExclusive(item.url, stage)
                    guard try Stamp.read(stage).sameContent(as: selection.stamp!) else { throw Failure.changed }
                    entry.phase = .staged; try self.write(entry)
                    guard try self.stageURL(entry) == stage,
                          try Stamp.read(stage).sameContent(as: selection.stamp!) else { throw Failure.changed }
                    try self.trash(stage)
                    moved = true
                    entry.phase = .moved; try self.write(entry)
                } catch { operationError = error }
            }
            if let error = coordinationError ?? operationError as NSError? { throw error }
            return Outcome(removed: selection.items, moved: 1, journal: entry.id)
        } catch {
            if moved {
                // The intent/staged journal survives a failed final journal write.
                // Commit the list before acknowledging it; never retry Trash here.
                return Outcome(removed: selection.items, moved: 1, journal: entry.id,
                               error: "文件已移入废纸篓；清理恢复记录保存失败，正在核对列表。")
            }
            do {
                try restoreStage(entry)
                try acknowledge([entry.id])
            } catch { return Outcome(error: Failure.restore.localizedDescription) }
            return Outcome(error: error.localizedDescription)
        }
    }
    private func renameExclusive(_ source: URL, _ target: URL) throws {
        guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    private func stageURL(_ entry: Entry) throws -> URL? {
        guard let name = entry.stageName else { return nil }
        guard let item = entry.items.first, name == ".sc2-clear-" + entry.id.uuidString else { throw Failure.invalidJournal }
        let (root, stamp) = try rootFor(item.url)
        guard root == entry.root, stamp.identity == entry.rootIdentity else { throw Failure.changed }
        let folder = item.url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { _ = try Stamp.read(folder, regular: false) }
        return folder.appendingPathComponent(item.url.lastPathComponent)
    }
    private func restoreStage(_ entry: Entry) throws {
        guard let stage = try stageURL(entry), FileManager.default.fileExists(atPath: stage.path) else { return }
        guard let expected = entry.stamp, try Stamp.read(stage).sameContent(as: expected), let item = entry.items.first else { throw Failure.restore }
        // Never overwrite an original that another app has recreated.
        try renameExclusive(stage, item.url)
    }
    func recover() -> Recovery {
        var result = Recovery()
        guard hasRecovery else { return result }
        do {
            _ = try Stamp.read(directory, regular: false)
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard urls.count <= 4096 else { throw Failure.invalidJournal }
            for url in urls {
                do {
                    guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                          (try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])).isSymbolicLink != true,
                          (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 2 * 1024 * 1024 else { throw Failure.invalidJournal }
                    let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
                    guard entry.id == id, !entry.items.isEmpty else { throw Failure.invalidJournal }
                    if let stage = try stageURL(entry), FileManager.default.fileExists(atPath: stage.path) {
                        try restoreStage(entry); result.restored += 1
                    } else if entry.phase == .reference {
                        result.removed += entry.items
                    } else if entry.items.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) {
                        result.removed += entry.items
                        if entry.phase != .moved { result.uncertain += 1 }
                    }
                    result.journals.append(id)
                } catch { result.errors.append(error.localizedDescription) }
            }
        } catch { result.errors.append(error.localizedDescription) }
        return result
    }
}
