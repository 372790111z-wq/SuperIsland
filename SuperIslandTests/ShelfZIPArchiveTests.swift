import Darwin
import Foundation
import XCTest
@testable import SuperIsland

final class ShelfZIPArchiveTests: XCTestCase {
    func testPreferredDisplayNameIsUsedForArchiveAndItsRootEntry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent(UUID().uuidString + ".png")
        let content = Data("image-fixture".utf8)
        try content.write(to: source)

        let archive = try ShelfZIPArchive.create(source: source, outputDirectory: fixture.root,
                                                preferredName: "粘贴图片.png")

        XCTAssertEqual(archive.lastPathComponent, "粘贴图片.png.zip")
        try assertValid(archive)
        let extracted = try extract(archive, in: fixture)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: extracted.path), ["粘贴图片.png"])
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("粘贴图片.png")), content)
        XCTAssertEqual(try Data(contentsOf: source), content)
    }

    func testUnicodeFileRetainsFullNameAndRoundTripsThroughSystemExtractor() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("中文 空格 #引号'\n😀.txt")
        let content = Data("ZIP 编码测试\n第二行\n".utf8)
        try content.write(to: source)

        let archive = try ShelfZIPArchive.create(source: source, outputDirectory: fixture.root)

        XCTAssertEqual(archive.lastPathComponent, source.lastPathComponent + ".zip")
        try assertValid(archive)
        let extracted = try extract(archive, in: fixture)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(source.lastPathComponent)), content)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: extracted.path), [source.lastPathComponent])
        // The independent ZIP local-header format stores UTF-8 in bit 11.
        let archiveBytes = try Data(contentsOf: archive)
        XCTAssertEqual(UInt16(archiveBytes[6]) | UInt16(archiveBytes[7]) << 8, 0x0808)
        XCTAssertEqual(try Data(contentsOf: source), content)
        try assertNoTemporaryFiles(fixture.root)
    }

    func testDirectoryRetainsRootAndEmptyDirectoriesAndPrunesMacMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("项目", isDirectory: true)
        let empty = folder.appendingPathComponent("子目录/空目录", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let files = ["正常.txt", ".普通隐藏文件", "子目录/中文.md", ".DS_Store", "子目录/._metadata"]
        for file in files { try Data(file.utf8).write(to: folder.appendingPathComponent(file)) }
        for junk in ["__MACOSX", "子目录/__MACOSX", "._metadata-folder", ".DS_Store-directory"] {
            let junkURL = folder.appendingPathComponent(junk, isDirectory: true)
            try FileManager.default.createDirectory(at: junkURL, withIntermediateDirectories: true)
            try Data("inside".utf8).write(to: junkURL.appendingPathComponent("payload.txt"))
        }

        let archive = try ShelfZIPArchive.create(source: folder, outputDirectory: fixture.root)

        try assertValid(archive)
        let extracted = try extract(archive, in: fixture).appendingPathComponent("项目", isDirectory: true)
        for file in ["正常.txt", ".普通隐藏文件", "子目录/中文.md"] {
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(file)), Data(file.utf8))
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("子目录/空目录").path,
                                                    isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        for junk in [".DS_Store", "子目录/._metadata", "__MACOSX", "子目录/__MACOSX", "._metadata-folder"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.appendingPathComponent(junk).path))
        }
        // Filter only the documented exact metadata name; keep ordinary similarly named directories.
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent(".DS_Store-directory/payload.txt").path))
    }

    func testEmptyFileAndEmptyDirectoryAreBothValidArchives() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("空文件.txt")
        try Data().write(to: file)
        let directory = fixture.root.appendingPathComponent("空文件夹")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for source in [file, directory] {
            let archive = try ShelfZIPArchive.create(source: source, outputDirectory: fixture.root)
            try assertValid(archive)
            let extracted = try extract(archive, in: fixture)
            XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent(source.lastPathComponent).path))
        }
    }

    func testNumberingPreservesExistingArchivesBytesAndModificationDates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("报告.pdf")
        try Data("first".utf8).write(to: file)
        let first = try ShelfZIPArchive.create(source: file, outputDirectory: fixture.root)
        let firstBytes = try Data(contentsOf: first)
        let firstDate = try first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try Data("second".utf8).write(to: file)
        let second = try ShelfZIPArchive.create(source: file, outputDirectory: fixture.root)
        let secondBytes = try Data(contentsOf: second)
        let secondDate = try second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let third = try ShelfZIPArchive.create(source: file, outputDirectory: fixture.root)

        XCTAssertEqual([first, second, third].map(\.lastPathComponent), ["报告.pdf.zip", "报告.pdf (1).zip", "报告.pdf (2).zip"])
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        XCTAssertEqual(try Data(contentsOf: second), secondBytes)
        XCTAssertEqual(try first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, firstDate)
        XCTAssertEqual(try second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, secondDate)
        for archive in [first, second, third] { try assertValid(archive) }
    }

    func testConcurrentCreatorsPublishDistinctCompleteArchives() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("共同.txt")
        try Data(repeating: 65, count: 512_000).write(to: source)
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            results.append(Result { try ShelfZIPArchive.create(source: source, outputDirectory: fixture.root) })
        }
        let archives = try results.values.map { try $0.get() }
        XCTAssertEqual(archives.count, 8)
        XCTAssertEqual(Set(archives).count, 8)
        for archive in archives { try assertValid(archive) }
        try assertNoTemporaryFiles(fixture.root)
    }

    func testExistingSymlinkAndDirectoryNamesAreNeverOverwritten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("file.txt")
        try Data("original".utf8).write(to: source)
        let occupied = fixture.root.appendingPathComponent("file.txt.zip")
        try FileManager.default.createSymbolicLink(at: occupied, withDestinationURL: source)
        let occupiedDirectory = fixture.root.appendingPathComponent("file.txt (1).zip")
        try FileManager.default.createDirectory(at: occupiedDirectory, withIntermediateDirectories: false)

        let archive = try ShelfZIPArchive.create(source: source, outputDirectory: fixture.root)

        XCTAssertEqual(archive.lastPathComponent, "file.txt (2).zip")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: occupied.path), source.path)
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        try assertValid(archive)
    }

    func testSymlinksAreRejectedAtRootAndInsideDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("secret.txt")
        try Data("not followed".utf8).write(to: source)
        let folder = fixture.root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        for candidate in [link, folder] {
            XCTAssertThrowsError(try ShelfZIPArchive.create(source: candidate, outputDirectory: fixture.root)) { error in
                guard case .symlink = error as? ShelfZIPArchive.Failure else { return XCTFail("Unexpected \(error)") }
            }
        }
        try assertNoArchivesOrTemporaryFiles(fixture.root)
    }

    func testSpecialFilesAreRejectedWithoutOpeningOrBlocking() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pipe = fixture.root.appendingPathComponent("named-pipe")
        XCTAssertEqual(pipe.path.withCString { mkfifo($0, 0o600) }, 0)
        XCTAssertThrowsError(try ShelfZIPArchive.create(source: pipe, outputDirectory: fixture.root)) { error in
            guard case .unsupportedEntry = error as? ShelfZIPArchive.Failure else { return XCTFail("Unexpected \(error)") }
        }
        try assertNoArchivesOrTemporaryFiles(fixture.root)
    }

    func testCancellationAfterTemporaryCreationRemovesOnlyItsOwnTemporaryFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("file.txt")
        try Data(repeating: 42, count: 500_000).write(to: source)
        let retained = fixture.root.appendingPathComponent("file.txt.zip")
        let retainedBytes = Data("preexisting".utf8)
        try retainedBytes.write(to: retained)
        var sawTemporary = false

        XCTAssertThrowsError(try ShelfZIPArchive.create(source: source, outputDirectory: fixture.root, isCancelled: {
            sawTemporary = (try? FileManager.default.contentsOfDirectory(atPath: fixture.root.path))?
                .contains(where: { $0.hasPrefix(".we1-zip-") }) == true
            return sawTemporary
        })) { error in
            XCTAssertEqual(error as? ShelfZIPArchive.Failure, .cancelled)
        }

        XCTAssertTrue(sawTemporary)
        XCTAssertEqual(try Data(contentsOf: retained), retainedBytes)
        try assertNoTemporaryFiles(fixture.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("file.txt (1).zip").path))
    }

    func testChangingSourceDuringCompressionFailsWithoutPublishing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("changing.txt")
        try Data(repeating: 42, count: 2_000_000).write(to: source)
        var callsAfterTemporary = 0
        var changed = false

        XCTAssertThrowsError(try ShelfZIPArchive.create(source: source, outputDirectory: fixture.root, isCancelled: {
            if (try? FileManager.default.contentsOfDirectory(atPath: fixture.root.path))?
                .contains(where: { $0.hasPrefix(".we1-zip-") }) == true {
                callsAfterTemporary += 1
                if callsAfterTemporary == 6 {
                    let handle = try? FileHandle(forWritingTo: source)
                    _ = try? handle?.seekToEnd()
                    try? handle?.write(contentsOf: Data("changed".utf8))
                    try? handle?.close()
                    changed = true
                }
            }
            return false
        })) { error in
            XCTAssertEqual(error as? ShelfZIPArchive.Failure, .sourceChanged)
        }

        XCTAssertTrue(changed)
        try assertNoArchivesOrTemporaryFiles(fixture.root)
    }

    func testMovingAndReplacingOutputDirectoryCannotPublishOrDeleteReplacementFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("file.txt")
        try Data(repeating: 42, count: 500_000).write(to: source)
        let output = fixture.root.appendingPathComponent("output")
        let movedOutput = fixture.root.appendingPathComponent("moved-output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var replacedName: String?
        var fixtureError: Error?
        let replacementData = Data("unrelated replacement file".utf8)

        XCTAssertThrowsError(try ShelfZIPArchive.create(source: source, outputDirectory: output, isCancelled: {
            if replacedName == nil,
               let temporaryName = (try? FileManager.default.contentsOfDirectory(atPath: output.path))?
                .first(where: { $0.hasPrefix(".we1-zip-") }) {
                do {
                    try FileManager.default.moveItem(at: output, to: movedOutput)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                    try replacementData.write(to: output.appendingPathComponent(temporaryName))
                    replacedName = temporaryName
                } catch { fixtureError = error }
            }
            return false
        })) { error in
            guard case .outputUnwritable = error as? ShelfZIPArchive.Failure else { return XCTFail("Unexpected \(error)") }
        }

        XCTAssertNil(fixtureError)
        let preserved = try XCTUnwrap(replacedName)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(preserved)), replacementData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: movedOutput.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [preserved])
    }

    func testEntryArchiveAndEntryCountLimitsFailWithoutPartialArchive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("file.txt")
        try Data(repeating: 42, count: 500).write(to: source)
        let defaults = ShelfZIPArchive.Limits.classic
        let entryLimit = ShelfZIPArchive.Limits(maximumEntryBytes: 499, maximumArchiveBytes: defaults.maximumArchiveBytes,
                                               maximumEntries: defaults.maximumEntries)
        let archiveLimit = ShelfZIPArchive.Limits(maximumEntryBytes: defaults.maximumEntryBytes, maximumArchiveBytes: 45,
                                                 maximumEntries: defaults.maximumEntries)
        let countLimit = ShelfZIPArchive.Limits(maximumEntryBytes: defaults.maximumEntryBytes,
                                               maximumArchiveBytes: defaults.maximumArchiveBytes, maximumEntries: 0)
        for limits in [entryLimit, archiveLimit] {
            XCTAssertThrowsError(try ShelfZIPArchive.create(source: source, outputDirectory: fixture.root, limits: limits)) {
                XCTAssertEqual($0 as? ShelfZIPArchive.Failure, .archiveTooLarge)
            }
        }
        XCTAssertThrowsError(try ShelfZIPArchive.create(source: source, outputDirectory: fixture.root, limits: countLimit)) {
            XCTAssertEqual($0 as? ShelfZIPArchive.Failure, .tooManyEntries)
        }
        try assertNoArchivesOrTemporaryFiles(fixture.root)
    }

    func testMissingInputAndUnwritableOutputAreDistinguished() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("file.txt")
        XCTAssertThrowsError(try ShelfZIPArchive.create(source: source, outputDirectory: fixture.root)) { error in
            guard case .sourceUnavailable = error as? ShelfZIPArchive.Failure else { return XCTFail("Unexpected \(error)") }
        }
        try Data("source".utf8).write(to: source)
        XCTAssertThrowsError(try ShelfZIPArchive.create(source: source,
                                                        outputDirectory: fixture.root.appendingPathComponent("missing"))) { error in
            guard case .outputUnwritable = error as? ShelfZIPArchive.Failure else { return XCTFail("Unexpected \(error)") }
        }
        try assertNoArchivesOrTemporaryFiles(fixture.root)
    }

    func testOutputInsideSourceIsRejectedAndJunkRootDoesNotProduceEmptyZIP() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ShelfZIPArchive.create(source: folder, outputDirectory: folder)) { error in
            guard case .outputUnwritable = error as? ShelfZIPArchive.Failure else { return XCTFail("Unexpected \(error)") }
        }
        let junk = fixture.root.appendingPathComponent(".DS_Store")
        try Data("junk".utf8).write(to: junk)
        XCTAssertThrowsError(try ShelfZIPArchive.create(source: junk, outputDirectory: fixture.root)) {
            XCTAssertEqual($0 as? ShelfZIPArchive.Failure, .noEligibleEntries)
        }
        try assertNoArchivesOrTemporaryFiles(fixture.root)
    }

    func testIncompressibleDataAcrossChunkBoundariesRoundTrips() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("random.bin")
        var state: UInt64 = 0xABCAFEBE
        let bytes = (0..<(2_097_152 + 17)).map { _ -> UInt8 in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }
        let data = Data(bytes)
        try data.write(to: source)
        let archive = try ShelfZIPArchive.create(source: source, outputDirectory: fixture.root)
        try assertValid(archive)
        let extracted = try extract(archive, in: fixture)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("random.bin")), data)
    }

    func testZIP64SizesOffsetsAndEndRecordsRoundTripThroughIndependentReaders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("ZIP64 中文目录")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let content = Data(repeating: 97, count: 131_072)
        try content.write(to: folder.appendingPathComponent("长文件.txt"))
        try Data().write(to: folder.appendingPathComponent("空文件.txt"))
        let archive = try ShelfZIPArchive.create(
            source: folder, outputDirectory: fixture.root,
            zip64: .init(size: 1, offset: 1, entries: 1)
        )

        try assertValid(archive)
        let extracted = try extract(archive, in: fixture).appendingPathComponent(folder.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("长文件.txt")), content)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("空文件.txt")), Data())
        let data = try Data(contentsOf: archive)
        XCTAssertNotNil(data.range(of: Data([0x50, 0x4b, 0x06, 0x06]))) // ZIP64 EOCD
        XCTAssertNotNil(data.range(of: Data([0x50, 0x4b, 0x06, 0x07]))) // ZIP64 locator
        try assertPythonZIP64ReadsEveryEntry(archive, minimumEntries: 3)
    }

    func testZIP64OffsetsAndEntryCountDoNotRequireLargePayloads() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("offsets")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for index in 0..<3 { try Data("\(index)".utf8).write(to: folder.appendingPathComponent("\(index).txt")) }
        let archive = try ShelfZIPArchive.create(
            source: folder, outputDirectory: fixture.root,
            zip64: .init(size: UInt64(UInt32.max), offset: 1, entries: 2)
        )

        try assertValid(archive)
        let extracted = try extract(archive, in: fixture).appendingPathComponent("offsets")
        for index in 0..<3 {
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("\(index).txt")), Data("\(index)".utf8))
        }
        try assertPythonZIP64ReadsEveryEntry(archive, minimumEntries: 4)
    }

    private struct Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("WE1-ZIP-tests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Result<URL, Error>] = []
        func append(_ result: Result<URL, Error>) { lock.lock(); defer { lock.unlock() }; storage.append(result) }
        var values: [Result<URL, Error>] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func assertValid(_ archive: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try command("/usr/bin/unzip", ["-t", archive.path])
        XCTAssertEqual(result.status, 0, result.output, file: file, line: line)
    }

    private func extract(_ archive: URL, in fixture: Fixture) throws -> URL {
        let directory = fixture.root.appendingPathComponent("extract-" + UUID().uuidString)
        let result = try command("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        XCTAssertEqual(result.status, 0, result.output)
        return directory
    }

    private func assertPythonZIP64ReadsEveryEntry(_ archive: URL, minimumEntries: Int) throws {
        // Test oracle only: the shipping compressor has no Python or subprocess dependency.
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "Python ZIP64 oracle unavailable")
        let script = """
        import sys, zipfile
        with zipfile.ZipFile(sys.argv[1]) as archive:
            assert archive.testzip() is None
            assert len(archive.infolist()) >= int(sys.argv[2])
            for entry in archive.infolist():
                assert len(archive.read(entry)) == entry.file_size
                assert entry.flag_bits & 0x800
        """
        let result = try command("/usr/bin/python3", ["-c", script, archive.path, String(minimumEntries)])
        XCTAssertEqual(result.status, 0, result.output)
    }

    private func command(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    private func assertNoTemporaryFiles(_ directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".we1-zip-") }, file: file, line: line)
    }

    private func assertNoArchivesOrTemporaryFiles(_ directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".zip") || $0.hasPrefix(".we1-zip-") }, file: file, line: line)
    }
}
