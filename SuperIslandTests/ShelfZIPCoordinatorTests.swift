import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import SuperIsland

@MainActor
final class ShelfZIPDropLoaderTests: XCTestCase {
    func testNativePasteboardRecoversIdentityFromFileOnlySwiftUIProvider() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = ShelfItem(kind: .file, displayName: "原名称.txt", path: "/tmp/original/原名称.txt")
        let native = NSPasteboardItem()
        native.setString(item.id.uuidString, forType: .init(ShelfStore.localItemTypeIdentifier))
        native.setString("file:///tmp/SwiftUI.Drag-cache/copy.txt", forType: .fileURL)
        pasteboard.writeObjects([native])
        let provider = NSItemProvider(object: URL(fileURLWithPath: "/tmp/SwiftUI.Drag-cache/copy.txt") as NSURL)
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(ShelfStore.localItemTypeIdentifier))
        let identity = try XCTUnwrap(ShelfZIPDropLoader.nativePasteboardItemID(pasteboard))
        let result = await ShelfZIPDropLoader.load(provider, existingItems: [item], nativeItemID: identity)
        guard case .file(let resolved) = result else { return XCTFail("Expected original file") }
        XCTAssertEqual(resolved.id, item.id)
        XCTAssertEqual(resolved.path, item.path)
        XCTAssertEqual(resolved.displayName, item.displayName)
    }

    func testNextExternalDragAndMultiplePasteboardItemsCannotBorrowIdentity() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString(UUID().uuidString, forType: .init(ShelfStore.localItemTypeIdentifier))
        pasteboard.writeObjects([item])
        XCTAssertNotNil(ShelfZIPDropLoader.nativePasteboardItemID(pasteboard))
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/external.txt") as NSURL])
        XCTAssertNil(ShelfZIPDropLoader.nativePasteboardItemID(pasteboard))
        pasteboard.clearContents()
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setString(UUID().uuidString, forType: .init(ShelfStore.localItemTypeIdentifier))
        second.setString("file:///tmp/external.txt", forType: .fileURL)
        pasteboard.writeObjects([first, second])
        XCTAssertNil(ShelfZIPDropLoader.nativePasteboardItemID(pasteboard))
    }

    func testRemovedNativeItemDoesNotFallBackToDragCache() async {
        let provider = NSItemProvider(object: URL(fileURLWithPath: "/tmp/SwiftUI.Drag-cache/copy.txt") as NSURL)
        let result = await ShelfZIPDropLoader.load(provider, existingItems: [], nativeItemID: UUID())
        guard case .unavailable = result else { return XCTFail("Removed original must not become cache input") }
    }

    func testTextTypedFinderNSURLRemainsAFile() async throws {
        let url = URL(fileURLWithPath: "/tmp/中文 # 空格\n测试.txt")
        let provider = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.plainText.identifier)
        let result = await ShelfZIPDropLoader.load(provider, existingItems: [])
        guard case .file(let item) = result else { return XCTFail("Expected file") }
        XCTAssertEqual(item.resolvedFileURL?.path, url.path)
    }

    func testTextAndWebURLAreRejectedWithoutCreatingDocuments() async {
        for provider in [
            NSItemProvider(object: "plain text" as NSString),
            NSItemProvider(item: "file:///tmp/do-not-read.txt" as NSString,
                           typeIdentifier: UTType.plainText.identifier),
            NSItemProvider(object: URL(string: "https://example.invalid/file.zip")! as NSURL)
        ] {
            let result = await ShelfZIPDropLoader.load(provider, existingItems: [])
            guard case .unsupported = result else { return XCTFail("Must reject non-file") }
        }
    }

    func testLocalProviderPreservesManagedImageNameAndBookmarkIdentity() async {
        let item = ShelfItem(kind: .image, displayName: "粘贴图片.png", path: "/tmp/internal-uuid.png")
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: ShelfStore.localItemTypeIdentifier, visibility: .ownProcess
        ) { completion in
            completion(Data(item.id.uuidString.utf8), nil)
            return nil
        }
        let result = await ShelfZIPDropLoader.load(provider, existingItems: [item])
        guard case .file(let resolved) = result else { return XCTFail("Expected local item") }
        XCTAssertEqual(resolved.id, item.id)
        XCTAssertEqual(resolved.displayName, item.displayName)
    }

    func testNativeStringIdentityBeatsMaterializedDragCacheURL() async {
        let item = ShelfItem(kind: .image, displayName: "粘贴图片.png", path: "/tmp/original/uuid.png")
        let provider = NSItemProvider(item: item.id.uuidString as NSString,
                                      typeIdentifier: ShelfStore.localItemTypeIdentifier)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) {
            completion in
            completion(URL(fileURLWithPath: "/tmp/SwiftUI.Drag-cache/uuid.png").dataRepresentation, nil)
            return nil
        }
        let result = await ShelfZIPDropLoader.load(provider, existingItems: [item])
        guard case .file(let resolved) = result else { return XCTFail("Expected original item") }
        XCTAssertEqual(resolved.id, item.id)
        XCTAssertEqual(resolved.path, item.path)
        XCTAssertEqual(resolved.displayName, "粘贴图片.png")
    }

    func testStalledProviderTimesOutAndLateReplyCannotResumeTwice() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) {
            completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                completion(URL(fileURLWithPath: "/tmp/late.txt").dataRepresentation, nil)
            }
            return nil
        }
        let result = await ShelfZIPDropLoader.load(provider, existingItems: [], timeout: 0.02)
        guard case .unavailable = result else { return XCTFail("Expected bounded failure") }
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testShelfExportProvidesOriginalFileURLInsteadOfContents() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("保留名称.zip")
        try Data("fixture".utf8).write(to: url)
        let source = ShelfItem.file(from: url)
        let originalURL = try XCTUnwrap(source.resolvedFileURL)
        let provider = ShelfStore.dragProvider(for: source)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertEqual(provider.suggestedName, url.lastPathComponent)
        let result = await ShelfZIPDropLoader.load(provider, existingItems: [])
        guard case .file(let item) = result else { return XCTFail("Expected original URL") }
        XCTAssertEqual(item.path, originalURL.path)
        XCTAssertEqual(item.displayName, url.lastPathComponent)
    }

    func testURLOnlyBridgeRecoversManagedImageIdentity() async {
        let item = ShelfItem(kind: .image, displayName: "粘贴图片.png", path: "/tmp/owned-uuid.png")
        let provider = NSItemProvider(object: URL(fileURLWithPath: item.path!) as NSURL)
        let result = await ShelfZIPDropLoader.load(provider, existingItems: [item])
        guard case .file(let resolved) = result else { return XCTFail("Expected file") }
        XCTAssertEqual(resolved.id, item.id)
        XCTAssertEqual(resolved.displayName, "粘贴图片.png")
    }

    func testSameFilenameAtDifferentPathDoesNotBorrowShelfIdentity() async {
        let item = ShelfItem(kind: .image, displayName: "original", path: "/tmp/owned/photo.png")
        let url = URL(fileURLWithPath: "/tmp/other/photo.png")
        let result = await ShelfZIPDropLoader.load(NSItemProvider(object: url as NSURL), existingItems: [item])
        guard case .file(let resolved) = result else { return XCTFail("Expected file") }
        XCTAssertNotEqual(resolved.id, item.id)
        XCTAssertEqual(resolved.path, url.path)
    }

    func testResolvedBookmarkTakesPriorityOverStaleStoredPath() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("current.txt")
        let old = directory.appendingPathComponent("old.txt")
        try Data("current".utf8).write(to: current)
        try Data("different file now at old location".utf8).write(to: old)
        let bookmark = try current.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let item = ShelfItem(kind: .file, displayName: "moved", path: old.path, bookmarkData: bookmark)
        let result = await ShelfZIPDropLoader.load(NSItemProvider(object: old as NSURL), existingItems: [item])
        guard case .file(let resolved) = result else { return XCTFail("Expected file") }
        XCTAssertNotEqual(resolved.id, item.id)
        XCTAssertEqual(resolved.path, old.path)
    }
}

@MainActor
final class ShelfZIPCoordinatorTests: XCTestCase {
    func testNativeIdentityIsCapturedBeforeAsyncLoadAndArchivesAtOriginalLocation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeFile("原名称.txt", directory)
        let original = ShelfItem.file(from: source)
        var draggedID: UUID? = original.id
        var results: [ShelfItem] = []
        let coordinator = ShelfZIPCoordinator(existingItems: { [original] }, addResults: { results += $0 },
                                               nativeDraggedItemID: { draggedID })
        coordinator.handleDrop(providers: [provider(directory.appendingPathComponent("nonexistent-cache-copy.txt"))])
        draggedID = nil
        try await idle(coordinator)
        XCTAssertEqual(results.map(\.displayName), ["原名称.txt.zip"])
        XCTAssertEqual(results.first?.resolvedFileURL?.resolvingSymlinksInPath().path,
                       directory.appendingPathComponent("原名称.txt.zip").resolvingSymlinksInPath().path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMultiProviderDropDoesNotReadSingleNativeIdentity() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makeFile("first.txt", directory)
        let second = try makeFile("second.txt", directory)
        var reads = 0
        var results: [ShelfItem] = []
        let coordinator = ShelfZIPCoordinator(addResults: { results += $0 }, nativeDraggedItemID: {
            reads += 1
            return UUID()
        })
        coordinator.handleDrop(providers: [provider(first), provider(second)])
        try await idle(coordinator)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(results.map(\.displayName), ["first.txt.zip", "second.txt.zip"])
    }

    func testDropDeduplicatesRepresentationsButNextDropProducesNumberedZIP() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeFile("中文 文档.txt", directory)
        var results: [ShelfItem] = []
        let coordinator = ShelfZIPCoordinator(addResults: { results.append(contentsOf: $0) })
        XCTAssertTrue(coordinator.handleDrop(providers: [provider(source), provider(source)]))
        try await idle(coordinator)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].displayName, "中文 文档.txt.zip")
        XCTAssertTrue(coordinator.handleDrop(providers: [provider(source)]))
        try await idle(coordinator)
        XCTAssertEqual(results.map(\.displayName), ["中文 文档.txt.zip", "中文 文档.txt (1).zip"])
        XCTAssertEqual(try String(contentsOf: source), "Fixture content")
    }

    func testBusyDropIsClaimedWithoutStartingAnotherBatch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makeFile("first.txt", directory)
        let second = try makeFile("second.txt", directory)
        var results: [ShelfItem] = []
        let coordinator = ShelfZIPCoordinator(addResults: { results += $0 })
        XCTAssertTrue(coordinator.handleDrop(providers: [provider(first)]))
        XCTAssertTrue(coordinator.isBusy)
        XCTAssertTrue(coordinator.handleDrop(providers: [provider(second)]))
        try await idle(coordinator)
        XCTAssertEqual(results.map(\.displayName), ["first.txt.zip"])
    }

    func testUnsupportedPartDoesNotReportWholeDropSuccessful() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeFile("valid.txt", directory)
        var results: [ShelfItem] = []
        let coordinator = ShelfZIPCoordinator(addResults: { results += $0 })
        coordinator.handleDrop(providers: [provider(source), NSItemProvider(object: "not a file" as NSString)])
        try await idle(coordinator)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(coordinator.title, "已完成 1 项，1 项失败")
        XCTAssertFalse(coordinator.canRetryFailed)
        XCTAssertFalse(coordinator.canChooseOutputDirectory)
    }

    func testOutputFailureOffersDirectoryPickerAndRetriesOnlyFailedItem() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let newDirectory = directory.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: false)
        let first = try makeFile("first.txt", directory)
        let second = try makeFile("second.txt", directory)
        var results: [ShelfItem] = []
        let coordinator = ShelfZIPCoordinator(addResults: { results += $0 }, archive: { source, output, name, token in
            if source.lastPathComponent == "second.txt", output.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path {
                throw ShelfZIPArchive.Failure.outputUnwritable("fixture")
            }
            return try ShelfZIPArchive.create(source: source, outputDirectory: output,
                                              preferredName: name, isCancelled: { token.isCancelled })
        }, pickDirectory: { $0(newDirectory) })
        coordinator.handleDrop(providers: [provider(first), provider(second)])
        try await idle(coordinator)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(coordinator.canChooseOutputDirectory)
        coordinator.chooseOutputDirectory()
        try await idle(coordinator)
        XCTAssertEqual(results.map(\.displayName), ["first.txt.zip", "second.txt.zip"])
        XCTAssertEqual(results[1].resolvedFileURL?.deletingLastPathComponent().resolvingSymlinksInPath().path, newDirectory.resolvingSymlinksInPath().path)
        XCTAssertFalse(coordinator.canRetryFailed)
        XCTAssertEqual(coordinator.title, "已压缩 2 项")
    }

    func testManagedImagePickerCancellationDoesNotStartAnyArchive() async throws {
        let managedURL = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("SuperIsland/ShelfImages/fixture-not-created.png")
        let managed = ShelfItem(kind: .image, displayName: "粘贴图片.png", path: managedURL.path)
        let localProvider = NSItemProvider()
        localProvider.registerDataRepresentation(
            forTypeIdentifier: ShelfStore.localItemTypeIdentifier, visibility: .ownProcess
        ) { reply in reply(Data(managed.id.uuidString.utf8), nil); return nil }
        var results: [ShelfItem] = []
        var chose = false
        let coordinator = ShelfZIPCoordinator(existingItems: { [managed] }, addResults: { results += $0 },
            archive: { _, _, _, _ in XCTFail("Cancel must not start archiving"); throw ShelfZIPArchive.Failure.cancelled },
            pickDirectory: { chose = true; $0(nil) })
        coordinator.handleDrop(providers: [localProvider])
        try await idle(coordinator)
        XCTAssertTrue(chose)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(coordinator.title, "已取消")
    }

    func testChoosingDirectoryAppliesToAllFailedItemsNotOnlyWriteFailures() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chosen = directory.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
        let first = try makeFile("read.txt", directory), second = try makeFile("write.txt", directory)
        var results: [ShelfItem] = []
        let coordinator = ShelfZIPCoordinator(addResults: { results += $0 }, archive: { source, output, _, _ in
            if output.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path {
                if source.lastPathComponent == "read.txt" { throw ShelfZIPArchive.Failure.sourceUnavailable("fixture") }
                throw ShelfZIPArchive.Failure.outputUnwritable("fixture")
            }
            return try ShelfZIPArchive.create(source: source, outputDirectory: output)
        }, pickDirectory: { $0(chosen) })
        coordinator.handleDrop(providers: [provider(first), provider(second)])
        try await idle(coordinator)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(coordinator.canChooseOutputDirectory)
        coordinator.chooseOutputDirectory()
        try await idle(coordinator)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.resolvedFileURL?.deletingLastPathComponent().resolvingSymlinksInPath().path == chosen.resolvingSymlinksInPath().path })
        XCTAssertFalse(coordinator.canRetryFailed)
    }

    func testTopLevelSymlinkIsRejectedEvenWhenBookmarkResolvesTarget() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try makeFile("target.txt", directory)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var results: [ShelfItem] = []
        let coordinator = ShelfZIPCoordinator(addResults: { results += $0 })
        coordinator.handleDrop(providers: [provider(link)])
        try await idle(coordinator)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(coordinator.detail.contains("符号链接"))
        XCTAssertFalse(coordinator.canChooseOutputDirectory)
    }

    func testCancelKeepsCompletedItemAndDoesNotAddIncompleteItem() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makeFile("first.txt", directory)
        let second = try makeFile("second.txt", directory)
        var results: [ShelfItem] = []
        let coordinator = ShelfZIPCoordinator(addResults: { results += $0 }, archive: { source, output, name, token in
            if source.lastPathComponent == "second.txt" {
                for _ in 0..<400 {
                    if token.isCancelled { throw ShelfZIPArchive.Failure.cancelled }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                throw ShelfZIPArchive.Failure.sourceUnavailable("timed-out-fixture")
            }
            return try ShelfZIPArchive.create(source: source, outputDirectory: output, preferredName: name)
        })
        coordinator.handleDrop(providers: [provider(first), provider(second)])
        try await waitUntil { results.count == 1 }
        coordinator.cancel()
        try await idle(coordinator)
        XCTAssertEqual(coordinator.title, "已取消")
        XCTAssertEqual(results.map(\.displayName), ["first.txt.zip"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("second.txt.zip").path))
        XCTAssertTrue(coordinator.detail.contains("1 个 ZIP"))
    }

    private func provider(_ url: URL) -> NSItemProvider {
        NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
    }
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WE1-ZIP-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func makeFile(_ name: String, _ directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("Fixture content".utf8).write(to: url)
        return url
    }
    private func idle(_ coordinator: ShelfZIPCoordinator) async throws {
        try await waitUntil { !coordinator.isBusy }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(5)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "Timed out")
    }
}
