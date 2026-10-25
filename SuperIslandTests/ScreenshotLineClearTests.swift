import AppKit
import SwiftUI
import XCTest
@testable import SuperIsland

final class ScreenshotLineClearTests: XCTestCase {
    private final class IO: @unchecked Sendable {
        let lock = NSLock()
        var failureName: String?
        var journalFailurePhase: String?
        private var stored: [String] = []
        var entered = false
        var delay: TimeInterval = 0
        var trashFolder: URL
        init(_ folder: URL) { trashFolder = folder }
        var names: [String] { lock.lock(); defer { lock.unlock() }; return stored }
        func move(_ url: URL) throws {
            lock.lock(); entered = true; let pause = delay; let failing = failureName == url.lastPathComponent; lock.unlock()
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            if failing { throw POSIXError(.EACCES) }
            try FileManager.default.moveItem(at: url, to: trashFolder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
            lock.lock(); stored.append(url.lastPathComponent); lock.unlock()
        }
        func save(_ data: Data, _ url: URL) throws {
            if let phase = journalFailurePhase,
               (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["phase"] as? String == phase { throw POSIXError(.ENOSPC) }
            try ScreenshotLineClearTransaction.durableWrite(data, url)
        }
    }
    @MainActor private final class Fixture {
        let name = "SC2-" + UUID().uuidString
        let root: URL
        let defaults: UserDefaults
        let pasteboard = NSPasteboard.withUniqueName()
        let io: IO
        var records: [ScreenshotLineItem] = []
        var failIndex = false
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(name)
            defaults = UserDefaults(suiteName: name)!
            for dir in [root, root.appendingPathComponent("Screenshots"), root.appendingPathComponent("Clipboard"), root.appendingPathComponent("TestTrash"), root.appendingPathComponent("External"), root.appendingPathComponent("Originals"), root.appendingPathComponent("ClipboardExports")] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            io = IO(root.appendingPathComponent("TestTrash"))
            defaults.set(false, forKey: "screenshotLine.watch")
            defaults.set(false, forKey: "screenshotLine.peek")
        }
        func file(_ name: String, folder: String = "Screenshots", owned: Bool = true, listed: Bool = true, kind: ScreenshotLineItem.Kind = .image) throws -> ScreenshotLineItem {
            let url = root.appendingPathComponent(folder).appendingPathComponent(name)
            try Data("SC2 isolated sample \(name)".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: url.path)
            let item = ScreenshotLineItem(id: UUID(), path: url.path, kind: kind, owned: owned, createdAt: Date())
            if listed { records.append(item) }
            return item
        }
        func index() throws { try JSONEncoder().encode(records).write(to: root.appendingPathComponent("index.json"), options: .atomic) }
        func store() -> ScreenshotLineClearTransaction {
            ScreenshotLineClearTransaction(support: root, roots: [root.appendingPathComponent("Screenshots"), root.appendingPathComponent("Clipboard")], trash: { [io] in try io.move($0) }, save: { [io] in try io.save($0, $1) })
        }
        func line(preferenceFailure: Bool = false, indexInjection: Bool = false) -> ScreenshotLineFeature {
            ScreenshotLineFeature(defaults: defaults, supportDirectory: root, pasteboard: pasteboard,
                readCapture: { _ in .init() }, writeCapture: { _, _ in },
                clearTrash: { [io] in try io.move($0) }, clearSave: { [io] in try io.save($0, $1) },
                clearPreferenceWriter: preferenceFailure ? { _ in throw POSIXError(.ENOSPC) } : nil,
                clearIndexWriter: indexInjection ? { [unowned self] data, url in
                    if failIndex { throw POSIXError(.ENOSPC) }
                    try ScreenshotLineClearTransaction.durableWrite(data, url)
                } : nil)
        }
        func exists(_ item: ScreenshotLineItem) -> Bool { FileManager.default.fileExists(atPath: item.path) }
        func dispose() { defaults.removePersistentDomain(forName: name); pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        func journal(_ item: ScreenshotLineItem, phase: ScreenshotLineClearTransaction.Entry.Phase, staged: Bool) throws -> UUID {
            let store = store(), plan = store.plan([item], busyIDs: [])
            let selection = try XCTUnwrap(plan.selections.first)
            let id = UUID(), name = ".sc2-clear-" + id.uuidString
            let entry = ScreenshotLineClearTransaction.Entry(id: id, items: [item], stamp: selection.stamp,
                root: selection.root, rootIdentity: selection.rootIdentity, stageName: name, phase: phase)
            let dir = store.directory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ScreenshotLineClearTransaction.durableWrite(JSONEncoder().encode(entry), dir.appendingPathComponent(id.uuidString + ".json"))
            if staged {
                let folder = item.url.deletingLastPathComponent().appendingPathComponent(name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                try FileManager.default.moveItem(at: item.url, to: folder.appendingPathComponent(item.url.lastPathComponent))
            }
            return id
        }
    }
    @MainActor private func wait(_ line: ScreenshotLineFeature) async { await line.clearTask?.value }

    @MainActor func testAllKindsAndOffPageItemsClearWithoutTouchingUnlistedFilesOrClipboard() async throws {
        let f = try Fixture(); defer { f.dispose() }
        for i in 0..<14 { _ = try f.file("sample-\(i).png", folder: i % 2 == 0 ? "Screenshots" : "Clipboard") }
        _ = try f.file("video.mov", kind: .recording)
        _ = try f.file("audio-scope.m4a", kind: .recording) // Existing-record fixture, not audio ingestion.
        let external = try f.file("external.png", folder: "External", owned: false)
        let unlisted = try f.file("unlisted.png", listed: false)
        let backup = try f.file("backup.png", folder: "Originals", listed: false)
        let export = try f.file("export.mov", folder: "ClipboardExports", listed: false)
        try f.index()
        f.pasteboard.setString("private SC2 fixture", forType: .string)
        let change = f.pasteboard.changeCount
        let line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        XCTAssertGreaterThan(line.items.count, line.visibleItems.count)
        line.requestClearAll { _ in .alertSecondButtonReturn }; await wait(line)
        XCTAssertTrue(line.items.isEmpty, line.status); XCTAssertEqual(f.io.names.count, 16, line.status)
        XCTAssertTrue(f.io.names.contains("video.mov")); XCTAssertTrue(f.io.names.contains("audio-scope.m4a"))
        for item in [external, unlisted, backup, export] { XCTAssertTrue(f.exists(item)) }
        XCTAssertEqual(f.pasteboard.changeCount, change)
        XCTAssertFalse(line.clearRecoveryPending); XCTAssertFalse(line.canClearAll)
        let saved = try JSONDecoder().decode([ScreenshotLineItem].self, from: Data(contentsOf: f.root.appendingPathComponent("index.json")))
        XCTAssertTrue(saved.isEmpty); XCTAssertFalse(f.store().hasRecovery)
    }
    @MainActor func testCancelDoesNotSaveSuppressionOrMoveAnything() async throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("cancel.png"); try f.index()
        let line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        line.requestClearAll { alert in alert.suppressionButton?.state = .on; return .alertFirstButtonReturn }; await wait(line)
        XCTAssertEqual(line.items, [item]); XCTAssertTrue(f.exists(item)); XCTAssertTrue(line.askBeforeClearAll); XCTAssertTrue(f.io.names.isEmpty)
    }
    @MainActor func testSuppressionPersistsAndSettingsRestoreAsking() async throws {
        let f = try Fixture(); defer { f.dispose() }; _ = try f.file("one.png"); try f.index()
        var line = f.line(); line.start(appName: "SC2Test", installUI: false)
        line.requestClearAll { alert in alert.suppressionButton?.state = .on; return .alertSecondButtonReturn }; await wait(line)
        XCTAssertFalse(line.askBeforeClearAll); line.stop()
        f.records = []; _ = try f.file("two.png"); try f.index()
        line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        XCTAssertFalse(line.askBeforeClearAll)
        line.requestClearAll { _ in XCTFail("Suppressed alert must not appear"); return .alertFirstButtonReturn }; await wait(line)
        XCTAssertTrue(line.items.isEmpty); XCTAssertTrue(line.setAskBeforeClearAll(true))
        line.setEnabled(false); XCTAssertFalse(line.setAskBeforeClearAll(false)); line.setEnabled(true)
        XCTAssertTrue(line.askBeforeClearAll)
    }
    @MainActor func testPreferenceSaveFailureStillAsksNextTime() async throws {
        let f = try Fixture(); defer { f.dispose() }; _ = try f.file("one.png"); try f.index()
        let line = f.line(preferenceFailure: true); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        line.requestClearAll { alert in alert.suppressionButton?.state = .on; return .alertSecondButtonReturn }; await wait(line)
        XCTAssertTrue(line.askBeforeClearAll); XCTAssertTrue(line.status.contains("询问偏好未保存")); XCTAssertTrue(line.items.isEmpty)
    }
    @MainActor func testDisabledAndEmptyCannotStartBatch() async throws {
        let f = try Fixture(); defer { f.dispose() }; _ = try f.file("one.png"); try f.index()
        let line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        line.setEnabled(false); line.requestClearAll { _ in XCTFail(); return .alertSecondButtonReturn }
        XCTAssertNil(line.clearTask); XCTAssertEqual(line.items.count, 1)
        line.setEnabled(true); line.requestClearAll { _ in .alertSecondButtonReturn }; await wait(line)
        line.requestClearAll { _ in XCTFail(); return .alertSecondButtonReturn }; XCTAssertNil(line.clearTask)
    }
    @MainActor func testPartialFailureRetainsFailedCardAndRetryOnlyProcessesRemaining() async throws {
        let f = try Fixture(); defer { f.dispose() }; let a = try f.file("a.png"), b = try f.file("b.mov", kind: .recording); try f.index()
        f.io.failureName = "a.png"
        let line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        line.requestClearAll { _ in .alertSecondButtonReturn }; await wait(line)
        XCTAssertEqual(line.items, [a]); XCTAssertTrue(f.exists(a)); XCTAssertFalse(f.exists(b)); XCTAssertTrue(line.status.contains("未能清理")); XCTAssertFalse(line.clearRecoveryPending)
        f.io.failureName = nil; line.requestClearAll { _ in .alertSecondButtonReturn }; await wait(line)
        XCTAssertTrue(line.items.isEmpty); XCTAssertEqual(Set(f.io.names), ["a.png", "b.mov"])
    }
    @MainActor func testIdentityChangeAfterConfirmationIsRetained() async throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("one.png"); try f.index()
        let line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        line.requestClearAll { _ in try! Data("replacement".utf8).write(to: item.url, options: .atomic); return .alertSecondButtonReturn }; await wait(line)
        XCTAssertEqual(line.items, [item]); XCTAssertTrue(f.exists(item)); XCTAssertTrue(f.io.names.isEmpty)
    }
    @MainActor func testDuplicateSubmitAndSingleItemMutationsBlockedWhileWorkingWithoutBlockingMainActor() async throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("one.png"); try f.index(); f.io.delay = 0.5
        let line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        var presentations = 0
        line.requestClearAll { _ in presentations += 1; return .alertSecondButtonReturn }
        line.requestClearAll { _ in presentations += 1; return .alertSecondButtonReturn }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(line.clearInProgress, "Background file work must leave main actor responsive")
        line.close(item); line.trash(item); line.edit(item); line.saveToFolder(item)
        XCTAssertEqual(line.items.count, 1)
        await wait(line); XCTAssertEqual(presentations, 1); XCTAssertEqual(f.io.names.count, 1)
    }
    @MainActor func testNewClipboardArrivalDuringConfirmationSurvivesAndPersists() async throws {
        let f = try Fixture(); defer { f.dispose() }; _ = try f.file("old.png"); try f.index()
        f.defaults.set(true, forKey: "screenshotLine.clipboard")
        let line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        // Exercise a nested modal loop as macOS does, so the real clipboard timer can run.
        line.requestClearAll { _ in
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let entry = NSPasteboardItem(); entry.setData(rep.representation(using: .png, properties: [:])!, forType: .png)
            f.pasteboard.clearContents(); f.pasteboard.writeObjects([entry])
            RunLoop.current.run(until: Date().addingTimeInterval(0.9))
            return .alertSecondButtonReturn
        }; await wait(line)
        XCTAssertEqual(line.items.count, 1); XCTAssertTrue(line.items.first?.path.contains("Clipboard/") == true)
        let saved = try JSONDecoder().decode([ScreenshotLineItem].self, from: Data(contentsOf: f.root.appendingPathComponent("index.json")))
        XCTAssertEqual(saved, line.items)
    }
    @MainActor func testDisableDuringConfirmationCancelsWithoutSavingPreference() async throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("one.png"); try f.index()
        let line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        line.requestClearAll { alert in alert.suppressionButton?.state = .on; line.setEnabled(false); return .alertSecondButtonReturn }; await wait(line)
        XCTAssertEqual(line.items, [item]); XCTAssertTrue(line.askBeforeClearAll); XCTAssertTrue(f.exists(item)); XCTAssertFalse(line.isEnabled)
    }
    @MainActor func testTerminationStopsUnstartedItemsAndWaitsForInFlightWork() async throws {
        let f = try Fixture(); defer { f.dispose() }; _ = try f.file("a.png"); _ = try f.file("b.png"); try f.index(); f.io.delay = 0.5
        let line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        line.requestClearAll { _ in .alertSecondButtonReturn }
        try await Task.sleep(for: .milliseconds(150)); await line.prepareClearForTermination()
        XCTAssertFalse(line.clearInProgress); XCTAssertEqual(line.items.count, 1); XCTAssertEqual(f.io.names.count, 1)
        XCTAssertFalse(f.store().hasRecovery)
    }
    @MainActor func testIndexFailureIsNotReportedAsCompleteAndRecoverySurvivesRestart() async throws {
        let f = try Fixture(); defer { f.dispose() }; _ = try f.file("a.png"); _ = try f.file("external.png", folder: "External", owned: false); try f.index(); f.failIndex = true
        let line = f.line(indexInjection: true); line.start(appName: "SC2Test", installUI: false)
        line.requestClearAll { _ in .alertSecondButtonReturn }; await wait(line)
        XCTAssertTrue(line.clearRecoveryPending); XCTAssertTrue(line.status.contains("记录保存失败")); XCTAssertTrue(f.store().hasRecovery)
        line.stop(); f.failIndex = false
        let recovered = f.line(indexInjection: true); recovered.start(appName: "SC2Test", installUI: false); defer { recovered.stop() }; await wait(recovered)
        XCTAssertFalse(recovered.clearRecoveryPending); XCTAssertEqual(recovered.items.count, 1); XCTAssertFalse(f.store().hasRecovery)
        XCTAssertEqual(f.io.names.count, 1, "Recovery must not repeat destructive operations")
    }
    @MainActor func testMissingFileRemovedAsReferenceNotSuccessfulTrash() throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("gone.png"); try FileManager.default.removeItem(at: item.url)
        let store = f.store(), plan = store.plan([item], busyIDs: [])
        let result = store.execute(try XCTUnwrap(plan.selections.first))
        XCTAssertEqual(result.removed, [item]); XCTAssertEqual(result.moved, 0); XCTAssertEqual(result.missing, 1); try store.acknowledge([try XCTUnwrap(result.journal)])
    }
    @MainActor func testOwnedOutsideRootsAndPrefixSiblingAreProtected() throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("outside.png", folder: "External")
        let sibling = f.root.appendingPathComponent("Screenshots-other"); try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        let other = try f.file("other.png", folder: "Screenshots-other")
        let store = f.store()
        for selection in store.plan([item, other], busyIDs: []).selections { XCTAssertNotNil(store.execute(selection).error) }
        XCTAssertTrue(f.exists(item)); XCTAssertTrue(f.exists(other)); XCTAssertTrue(f.io.names.isEmpty)
    }
    @MainActor func testSymlinkAndHardlinkNeverDeleteExternalTargets() throws {
        let f = try Fixture(); defer { f.dispose() }; let outside = try f.file("outside.png", folder: "External", owned: false)
        let link = f.root.appendingPathComponent("Screenshots/link.png"), hard = f.root.appendingPathComponent("Clipboard/hard.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)
        try FileManager.default.linkItem(at: outside.url, to: hard)
        let items = [link, hard].map { ScreenshotLineItem(id: UUID(), path: $0.path, kind: .image, owned: true, createdAt: Date()) }
        let store = f.store()
        for selection in store.plan(items, busyIDs: []).selections { XCTAssertNotNil(store.execute(selection).error) }
        XCTAssertTrue(f.exists(outside)); XCTAssertTrue(f.io.names.isEmpty)
    }
    @MainActor func testExternalAliasProtectsManagedFileAndDuplicateCardsTrashOnce() throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("one.png")
        var duplicate = ScreenshotLineItem(id: UUID(), path: item.path, kind: .recording, owned: true, createdAt: Date())
        let store = f.store(), merged = store.plan([item, duplicate], busyIDs: [])
        XCTAssertEqual(merged.selections.count, 1)
        duplicate.owned = false
        for selection in store.plan([item, duplicate], busyIDs: []).selections {
            let out = store.execute(selection); XCTAssertNil(out.error); XCTAssertEqual(out.moved, 0); try store.acknowledge([try XCTUnwrap(out.journal)])
        }
        XCTAssertTrue(f.exists(item)); XCTAssertTrue(f.io.names.isEmpty)
    }
    @MainActor func testRecentlyModifiedAndBusyItemsAreRetained() throws {
        let f = try Fixture(); defer { f.dispose() }; let recent = try f.file("recent.png"), busy = try f.file("busy.png")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: recent.path)
        for selection in f.store().plan([recent, busy], busyIDs: [busy.id]).selections { XCTAssertNotNil(selection.error) }
        XCTAssertTrue(f.exists(recent)); XCTAssertTrue(f.exists(busy))
    }
    @MainActor func testJournalWriteFailureHappensBeforeAnyFileMutation() throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("one.png"); f.io.journalFailurePhase = "prepared"
        let store = f.store(); let out = store.execute(try XCTUnwrap(store.plan([item], busyIDs: []).selections.first))
        XCTAssertNotNil(out.error); XCTAssertTrue(f.exists(item)); XCTAssertTrue(f.io.names.isEmpty)
    }
    @MainActor func testStagedWriteFailureRestoresOriginalWithoutTrashing() throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("one.png"); f.io.journalFailurePhase = "staged"
        let store = f.store(); let out = store.execute(try XCTUnwrap(store.plan([item], busyIDs: []).selections.first))
        XCTAssertNotNil(out.error); XCTAssertTrue(f.exists(item)); XCTAssertFalse(store.hasRecovery); XCTAssertTrue(f.io.names.isEmpty)
    }
    @MainActor func testFinalJournalWriteFailureDoesNotRepeatTrash() async throws {
        let f = try Fixture(); defer { f.dispose() }; _ = try f.file("one.png"); try f.index(); f.io.journalFailurePhase = "moved"
        let line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        line.requestClearAll { _ in .alertSecondButtonReturn }; await wait(line)
        XCTAssertTrue(line.items.isEmpty); XCTAssertEqual(f.io.names.count, 1); XCTAssertFalse(f.store().hasRecovery)
    }
    @MainActor func testRecoveryOfPreparedAndStagedTransactionsRestoresFilesAndNeverTrashes() throws {
        for phase in [ScreenshotLineClearTransaction.Entry.Phase.prepared, .staged] {
            let f = try Fixture(); defer { f.dispose() }; let item = try f.file("one.png"); _ = try f.journal(item, phase: phase, staged: true)
            let store = f.store(), recovery = store.recover()
            XCTAssertEqual(recovery.restored, 1); XCTAssertTrue(recovery.removed.isEmpty); XCTAssertTrue(recovery.errors.isEmpty)
            XCTAssertTrue(f.exists(item)); XCTAssertTrue(f.io.names.isEmpty); try store.acknowledge(recovery.journals); XCTAssertFalse(store.hasRecovery)
        }
    }
    @MainActor func testRecoveryNeverOverwritesRecreatedOriginal() throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("one.png"); _ = try f.journal(item, phase: .staged, staged: true)
        let replacement = Data("replacement".utf8); try replacement.write(to: item.url)
        let result = f.store().recover()
        XCTAssertFalse(result.errors.isEmpty); XCTAssertTrue(result.journals.isEmpty); XCTAssertEqual(try Data(contentsOf: item.url), replacement); XCTAssertTrue(f.store().hasRecovery)
    }
    @MainActor func testMalformedJournalBlocksWithoutReadingOtherFiles() throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("one.png")
        try FileManager.default.createDirectory(at: f.store().directory, withIntermediateDirectories: false)
        try Data("invalid".utf8).write(to: f.store().directory.appendingPathComponent(UUID().uuidString + ".json"))
        let result = f.store().recover(); XCTAssertFalse(result.errors.isEmpty); XCTAssertTrue(f.exists(item)); XCTAssertTrue(result.removed.isEmpty)
    }
    @MainActor func testJournalPermissionsArePrivateAndTrashPreservesOriginalFileName() throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("recognizable.mov", kind: .recording)
        let store = f.store(), out = store.execute(try XCTUnwrap(store.plan([item], busyIDs: []).selections.first))
        let id = try XCTUnwrap(out.journal)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent(id.uuidString + ".json").path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(f.io.names, ["recognizable.mov"]); try store.acknowledge([id])
    }
    @MainActor func testRealMacOSTrashPreservesNameAndBytesAndCanBeRestored() throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("SC2-" + UUID().uuidString + ".png")
        let original = try Data(contentsOf: item.url)
        final class ResultBox: @unchecked Sendable { var url: URL? }
        let result = ResultBox()
        let store = ScreenshotLineClearTransaction(support: f.root, roots: [f.root.appendingPathComponent("Screenshots")], trash: { url in
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            result.url = trashed as URL?
        })
        let out = store.execute(try XCTUnwrap(store.plan([item], busyIDs: []).selections.first))
        XCTAssertNil(out.error); XCTAssertEqual(out.moved, 1)
        let trashed = try XCTUnwrap(result.url)
        // Restore this test's own sample even if a subsequent assertion fails.
        defer { if FileManager.default.fileExists(atPath: trashed.path) { try? FileManager.default.moveItem(at: trashed, to: item.url) } }
        XCTAssertEqual(trashed.lastPathComponent, item.url.lastPathComponent)
        XCTAssertTrue(trashed.path.contains(".Trash"))
        XCTAssertEqual(try Data(contentsOf: trashed), original)
        try FileManager.default.moveItem(at: trashed, to: item.url)
        XCTAssertEqual(try Data(contentsOf: item.url), original)
        try store.acknowledge([try XCTUnwrap(out.journal)])
    }
    @MainActor func testNativeEscapeCancelsSimpleAlert() async throws {
        let f = try Fixture(); defer { f.dispose() }
        let line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        let alert = line.makeClearAlert(count: 2)
        var delivered = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: alert.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            delivered = true
            NSApp.postEvent(event, atStart: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if NSApp.modalWindow === alert.window { NSApp.abortModal() }
        }
        let response = await line.presentClearAlert(alert)
        XCTAssertTrue(delivered); XCTAssertEqual(response, .alertFirstButtonReturn)
    }
    @MainActor func testNativeConfirmationYieldsToOtherMainActorTasksAndSubmitsOnlyExplicitClear() async throws {
        let f = try Fixture(); defer { f.dispose() }
        let line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }
        let alert = line.makeClearAlert(count: 2)
        var heartbeatRan = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            heartbeatRan = true
            alert.buttons[1].performClick(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if NSApp.modalWindow === alert.window { NSApp.abortModal() }
        }
        let result = await line.presentClearAlert(alert)
        XCTAssertTrue(heartbeatRan); XCTAssertEqual(result, .alertSecondButtonReturn)
    }
    @MainActor func testRootSwapAfterPlanningDoesNotTouchReplacement() throws {
        let f = try Fixture(); defer { f.dispose() }; let item = try f.file("one.png")
        let store = f.store(), selection = try XCTUnwrap(store.plan([item], busyIDs: []).selections.first)
        let originalRoot = item.url.deletingLastPathComponent(), renamed = f.root.appendingPathComponent("OldScreenshots")
        try FileManager.default.moveItem(at: originalRoot, to: renamed)
        try FileManager.default.createDirectory(at: originalRoot, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: item.url)
        XCTAssertNotNil(store.execute(selection).error)
        XCTAssertTrue(f.exists(item)); XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.appendingPathComponent("one.png").path)); XCTAssertTrue(f.io.names.isEmpty)
    }
    @MainActor func testStartupStagedRecoveryKeepsAllCardsAndFiles() async throws {
        let f = try Fixture(); defer { f.dispose() }; let a = try f.file("a.png"), b = try f.file("b.png"); try f.index()
        _ = try f.journal(a, phase: .prepared, staged: true)
        let line = f.line(); line.start(appName: "SC2Test", installUI: false); defer { line.stop() }; await wait(line)
        XCTAssertEqual(Set(line.items.map(\.id)), [a.id, b.id]); XCTAssertTrue(f.exists(a)); XCTAssertTrue(f.exists(b))
        XCTAssertFalse(line.clearRecoveryPending); XCTAssertTrue(f.io.names.isEmpty)
    }
    @MainActor func testNativeMenuAlertAndSettingsRenderAtTwoWidths() async throws {
        let f = try Fixture(); defer { f.dispose() }; _ = try f.file("sample.png"); try f.index()
        let line = f.line(); line.start(appName: "SuperIsland", installUI: false); defer { line.stop() }
        let menu = NSMenu(); line.menuNeedsUpdate(menu)
        let clear = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("清空挂绳") }); XCTAssertTrue(clear.isEnabled)
        XCTAssertEqual(clear.accessibilityIdentifier(), "data-annotation-id=si.sc.clear-all")
        let alert = line.makeClearAlert(count: 17)
        XCTAssertEqual(alert.messageText, "清空挂绳上的 17 项内容？"); XCTAssertEqual(alert.informativeText, "托管副本将移到废纸篓，外部原文件保留。")
        XCTAssertEqual(alert.buttons.map(\.title), ["取消", "清空"]); XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r")
        XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[0].cell)
        XCTAssertEqual(alert.suppressionButton?.title, "下次不再询问"); XCTAssertEqual(alert.suppressionButton?.state, .off)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/SC2NativeValidation/NativeViews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func capture(_ view: NSView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        alert.layout(); try capture(try XCTUnwrap(alert.window.contentView), name: "clear-alert")
        XCTAssertEqual(alert.window.accessibilityIdentifier(), "data-annotation-id=si.sc.clear-confirm")
        XCTAssertEqual(alert.suppressionButton?.accessibilityIdentifier(), "data-annotation-id=si.sc.clear-confirm-suppress")
        func identifiers(_ root: NSObject) -> Set<String> {
            var seen = Set<ObjectIdentifier>(), ids = Set<String>()
            func visit(_ object: NSObject) {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return }
                let key = NSSelectorFromString("accessibilityIdentifier")
                if object.responds(to: key), let value = object.perform(key)?.takeUnretainedValue() as? String { ids.insert(value) }
                let children = NSSelectorFromString("accessibilityChildren")
                if object.responds(to: children), let values = object.perform(children)?.takeUnretainedValue() as? [NSObject] { values.forEach(visit) }
                if let view = object as? NSView { view.subviews.forEach(visit) }
            }
            visit(root); return ids
        }
        var viewIDs: [String: [String]] = [:]
        for width in [640.0, 960.0] {
            let host = NSHostingView(rootView: ScreenshotLineSettingsView(line: line)); host.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(100)); try capture(host, name: "settings-\(Int(width))")
            let ids = identifiers(window)
            XCTAssertTrue(ids.contains("data-annotation-id=si.sc.clear-ask-before"), "Native settings must expose the new switch")
            viewIDs[String(Int(width))] = ids.sorted()
            window.close()
        }
        try JSONSerialization.data(withJSONObject: viewIDs, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("settings-accessibility.json"))
        line.setEnabled(false); line.menuNeedsUpdate(menu)
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title.hasPrefix("清空挂绳") }).isEnabled)
        XCTAssertNotNil(menu.items.first { $0.title == "启用截图挂绳" })
    }
}
