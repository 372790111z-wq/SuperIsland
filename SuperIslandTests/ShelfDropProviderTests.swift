import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import SuperIsland

/// Exercise AppKit's provider loading without touching the shared shelf,
/// persisted settings, user files, or sharing services.
@MainActor
final class ShelfDropProviderTests: XCTestCase {
    func testFinderFileURLObjectResolvesToExistingFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = try makeFile(named: "Finder 文件.txt", in: directory)
        let provider = NSItemProvider(object: fileURL as NSURL)

        let items = await ShelfStore.extractItems(from: [provider])

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.displayName, fileURL.lastPathComponent)
        assertFileURL(item, equals: fileURL)
        XCTAssertFalse(item.isMissing)
    }

    func testFileURLDataRepresentationPreservesSpacesAndUnicode() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = try makeFile(named: "拖放 测试 #1.txt", in: directory)
        let provider = fileURLDataProvider(fileURL)

        let items = await ShelfStore.extractItems(from: [provider])

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.displayName, fileURL.lastPathComponent)
        assertFileURL(item, equals: fileURL)
        XCTAssertFalse(item.isMissing)
    }

    func testFolderIsKeptAsFolderRatherThanTextOrLink() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folderURL = directory.appendingPathComponent("测试文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let provider = NSItemProvider(object: folderURL as NSURL)

        let items = await ShelfStore.extractItems(from: [provider])

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.kind, .folder)
        assertFileURL(item, equals: folderURL)
        XCTAssertFalse(item.isMissing)
    }

    func testMultipleFileProvidersKeepEveryFileInDropOrder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = try makeFile(named: "first.txt", in: directory)
        let secondURL = try makeFile(named: "second.txt", in: directory)
        let thirdURL = try makeFile(named: "third.txt", in: directory)
        let providers = [
            NSItemProvider(object: firstURL as NSURL),
            fileURLDataProvider(secondURL),
            NSItemProvider(object: thirdURL as NSURL)
        ]

        let items = await ShelfStore.extractItems(from: providers)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.displayName), ["first.txt", "second.txt", "third.txt"])
        XCTAssertTrue(items.allSatisfy { $0.kind == .file && !$0.isMissing })
        XCTAssertEqual(
            items.compactMap { $0.resolvedFileURL?.resolvingSymlinksInPath().path },
            [firstURL, secondURL, thirdURL].map { $0.resolvingSymlinksInPath().path }
        )
    }

    func testUnavailableFileURLPayloadDoesNotCreatePhantomShelfItem() async {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(nil, NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError))
            return nil
        }

        let items = await ShelfStore.extractItems(from: [provider])

        XCTAssertTrue(items.isEmpty)
    }

    func testFailedProviderDoesNotDiscardOtherFilesInSameDrop() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = try makeFile(named: "valid.txt", in: directory)
        let failedProvider = NSItemProvider()
        failedProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(nil, NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError))
            return nil
        }

        let items = await ShelfStore.extractItems(from: [failedProvider, NSItemProvider(object: fileURL as NSURL)])

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        assertFileURL(item, equals: fileURL)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfDropProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("WE1 shelf drop fixture".utf8).write(to: url)
        return url
    }

    private func fileURLDataProvider(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = url.dataRepresentation
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func assertFileURL(
        _ item: ShelfItem,
        equals expectedURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            item.resolvedFileURL?.resolvingSymlinksInPath().path,
            expectedURL.resolvingSymlinksInPath().path,
            file: file,
            line: line
        )
    }
}
