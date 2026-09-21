import Darwin
import Foundation
import zlib

/// Creates one interoperable ZIP beside a source or in an explicitly selected folder.
/// Call off the main actor; callers own security-scoped access for both URLs.
enum ShelfZIPArchive {
    enum Failure: Error, LocalizedError, Equatable {
        case cancelled
        case sourceUnavailable(String)
        case outputUnwritable(String)
        case outputFailure(String)
        case symlink(String)
        case unsupportedEntry(String)
        case invalidName
        case noEligibleEntries
        case sourceChanged
        case archiveTooLarge
        case tooManyEntries
        case compressionFailed
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .cancelled: return "已取消压缩"
            case .sourceUnavailable: return "无法读取原文件"
            case .outputUnwritable: return "无法写入目标文件夹，请换个位置"
            case .outputFailure: return "ZIP 保存失败，请检查磁盘空间"
            case .symlink: return "包含符号链接，暂不支持压缩"
            case .unsupportedEntry: return "包含不支持的文件类型"
            case .invalidName: return "文件名无法用于 ZIP"
            case .noEligibleEntries: return "没有可压缩的文件"
            case .sourceChanged: return "原文件已变化，请重试"
            case .archiveTooLarge: return "文件过大，无法压缩"
            case .tooManyEntries: return "文件数量超过系统限制"
            case .compressionFailed: return "压缩失败，请重试"
            case .verificationFailed: return "ZIP 校验失败，请重试"
            }
        }
    }

    /// Injectable safety limits exercise failures without huge fixtures. Production uses ZIP64.
    struct Limits {
        let maximumEntryBytes: UInt64
        let maximumArchiveBytes: UInt64
        let maximumEntries: Int

        static let classic = Limits(
            maximumEntryBytes: UInt64(UInt32.max) - 1,
            maximumArchiveBytes: UInt64(UInt32.max) - 1,
            maximumEntries: Int(UInt16.max) - 1
        )

        static let system = Limits(
            maximumEntryBytes: UInt64(Int64.max) - 1,
            maximumArchiveBytes: UInt64(Int64.max) - 1,
            maximumEntries: Int.max
        )
    }

    /// Lower thresholds let tests exercise real ZIP64 records with small fixtures.
    struct ZIP64Thresholds {
        let size: UInt64
        let offset: UInt64
        let entries: Int
        static let standard = ZIP64Thresholds(size: UInt64(UInt32.max), offset: UInt64(UInt32.max),
                                              entries: Int(UInt16.max))
    }

    /// `preferredName` is the source basename, including its existing extension.
    /// `report.pdf` becomes `report.pdf.zip`, then `report.pdf (1).zip` on collision.
    static func create(
        source: URL,
        outputDirectory: URL,
        preferredName: String? = nil,
        isCancelled: () -> Bool = { false },
        limits: Limits = .system,
        zip64: ZIP64Thresholds = .standard
    ) throws -> URL {
        try checkCancellation(isCancelled)
        guard source.isFileURL, outputDirectory.isFileURL else {
            throw Failure.sourceUnavailable("not-file-url")
        }
        let source = source.standardizedFileURL
        let basename = preferredName ?? source.lastPathComponent
        try validateComponent(basename)
        let effectiveLimits = Limits(
            maximumEntryBytes: min(limits.maximumEntryBytes, Limits.system.maximumEntryBytes),
            maximumArchiveBytes: min(limits.maximumArchiveBytes, Limits.system.maximumArchiveBytes),
            maximumEntries: min(limits.maximumEntries, Limits.system.maximumEntries)
        )
        let zip64 = ZIP64Thresholds(size: max(1, min(zip64.size, ZIP64Thresholds.standard.size)),
                                   offset: max(1, min(zip64.offset, ZIP64Thresholds.standard.offset)),
                                   entries: max(1, min(zip64.entries, ZIP64Thresholds.standard.entries)))
        var entries: [SourceEntry] = []
        try collect(source, relativeName: basename, entries: &entries,
                    limits: effectiveLimits, isCancelled: isCancelled)
        guard !entries.isEmpty else { throw Failure.noEligibleEntries }

        // Never create the temporary archive inside a directory being archived.
        let output = outputDirectory.standardizedFileURL.resolvingSymlinksInPath()
        if entries[0].isDirectory {
            let sourcePath = source.resolvingSymlinksInPath().path
            guard output.path != sourcePath, !output.path.hasPrefix(sourcePath + "/") else {
                throw Failure.outputUnwritable("output-inside-source")
            }
        }
        let directoryDescriptor = output.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else { throw outputError(errno) }
        defer { Darwin.close(directoryDescriptor) }
        var directoryStat = stat()
        guard fstat(directoryDescriptor, &directoryStat) == 0 else { throw outputError(errno) }

        let temporaryName = ".we1-zip-" + UUID().uuidString
        let descriptor = temporaryName.withCString {
            openat(directoryDescriptor, $0, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw outputError(errno) }
        defer {
            // Anchor cleanup to the opened directory even if the user moves that folder.
            // A different file substituted under our temporary name never belongs to us.
            var owned = stat()
            var named = stat()
            if fstat(descriptor, &owned) == 0,
               temporaryName.withCString({ fstatat(directoryDescriptor, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
               owned.st_dev == named.st_dev, owned.st_ino == named.st_ino {
                temporaryName.withCString { _ = unlinkat(directoryDescriptor, $0, 0) }
            }
            Darwin.close(descriptor)
        }
        let writer = Writer(descriptor: descriptor, limit: effectiveLimits.maximumArchiveBytes)
        var archived: [ArchivedEntry] = []
        for entry in entries {
            try checkCancellation(isCancelled)
            archived.append(try write(entry, writer: writer, limits: effectiveLimits, zip64: zip64,
                                      isCancelled: isCancelled))
        }
        let centralOffset = writer.position
        for entry in archived {
            try checkCancellation(isCancelled)
            try writer.append(entry.centralRecord)
        }
        let centralSize = writer.position - centralOffset
        var end = Data()
        let count64 = archived.count >= zip64.entries
        let centralSize64 = centralSize >= zip64.size
        let centralOffset64 = centralOffset >= zip64.offset
        // APPNOTE 4.3.14-16: ZIP64 EOCD plus locator precede the classic EOCD.
        if count64 || centralSize64 || centralOffset64 || archived.contains(where: \.usesZIP64) {
            end.little(UInt32(0x06064b50)); end.little(UInt64(44))
            end.little(UInt16(0x032d)); end.little(UInt16(45))
            end.little(UInt32(0)); end.little(UInt32(0))
            end.little(UInt64(archived.count)); end.little(UInt64(archived.count))
            end.little(centralSize); end.little(centralOffset)
            end.little(UInt32(0x07064b50)); end.little(UInt32(0))
            end.little(writer.position); end.little(UInt32(1))
        }
        end.little(UInt32(0x06054b50))
        end.little(UInt16(0)); end.little(UInt16(0))
        end.little(count64 ? UInt16.max : UInt16(archived.count))
        end.little(count64 ? UInt16.max : UInt16(archived.count))
        end.little(centralSize64 ? UInt32.max : UInt32(centralSize))
        end.little(centralOffset64 ? UInt32.max : UInt32(centralOffset))
        end.little(UInt16(0))
        try writer.append(end)
        guard fsync(descriptor) == 0 else { throw outputError(errno) }
        var completedStat = stat()
        guard fstat(descriptor, &completedStat) == 0 else { throw Failure.verificationFailed }

        try verify(descriptor: descriptor, entries: archived, centralOffset: centralOffset,
                   centralSize: centralSize, end: end, archiveLength: writer.position,
                   isCancelled: isCancelled)
        for entry in entries {
            try checkCancellation(isCancelled)
            let current = try Snapshot.read(entry.url)
            guard current == entry.snapshot else { throw Failure.sourceChanged }
        }
        var suffix = 0
        while true {
            try checkCancellation(isCancelled)
            var currentDirectory = stat()
            guard output.path.withCString({ lstat($0, &currentDirectory) }) == 0,
                  currentDirectory.st_dev == directoryStat.st_dev,
                  currentDirectory.st_ino == directoryStat.st_ino else {
                throw Failure.outputUnwritable("output-directory-changed")
            }
            var namedTemporary = stat()
            guard temporaryName.withCString({ fstatat(directoryDescriptor, $0, &namedTemporary, AT_SYMLINK_NOFOLLOW) }) == 0,
                  Snapshot(namedTemporary) == Snapshot(completedStat) else { throw Failure.verificationFailed }
            let filename = suffix == 0 ? basename + ".zip" : "\(basename) (\(suffix)).zip"
            let destination = output.appendingPathComponent(filename)
            let result = temporaryName.withCString { old in
                filename.withCString { new in
                    renameatx_np(directoryDescriptor, old, directoryDescriptor, new, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 { return destination }
            let code = errno
            guard code == EEXIST else { throw outputError(code) }
            suffix += 1
        }
    }

    private struct Snapshot: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }

        static func read(_ url: URL) throws -> Snapshot {
            var value = stat()
            guard url.path.withCString({ lstat($0, &value) }) == 0 else {
                throw Failure.sourceUnavailable(String(errno))
            }
            return Snapshot(value)
        }
    }

    private struct SourceEntry {
        let url: URL
        let name: String
        let snapshot: Snapshot
        var isDirectory: Bool { snapshot.mode & S_IFMT == S_IFDIR }
    }

    private static func collect(
        _ url: URL, relativeName: String, entries: inout [SourceEntry],
        limits: Limits, isCancelled: () -> Bool
    ) throws {
        try checkCancellation(isCancelled)
        let basename = url.lastPathComponent
        if basename == ".DS_Store" || basename == "__MACOSX" || basename.hasPrefix("._") { return }
        try validateComponent(basename)
        let snapshot = try Snapshot.read(url)
        let kind = snapshot.mode & S_IFMT
        guard kind != S_IFLNK else { throw Failure.symlink(basename) }
        guard kind == S_IFREG || kind == S_IFDIR else { throw Failure.unsupportedEntry(basename) }
        guard entries.count < limits.maximumEntries else { throw Failure.tooManyEntries }
        if kind == S_IFREG {
            guard snapshot.size >= 0, UInt64(snapshot.size) <= limits.maximumEntryBytes else {
                throw Failure.archiveTooLarge
            }
        }
        let name = kind == S_IFDIR ? relativeName + "/" : relativeName
        guard name.utf8.count <= Int(UInt16.max) else { throw Failure.invalidName }
        entries.append(SourceEntry(url: url, name: name, snapshot: snapshot))
        if kind == S_IFDIR {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: []
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch { throw Failure.sourceUnavailable("directory-read") }
            for child in children {
                try collect(child, relativeName: relativeName + "/" + child.lastPathComponent,
                            entries: &entries, limits: limits, isCancelled: isCancelled)
            }
            guard try Snapshot.read(url) == snapshot else { throw Failure.sourceChanged }
        }
    }

    private static func validateComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw Failure.invalidName
        }
    }

    private final class Writer {
        let descriptor: Int32
        let limit: UInt64
        private(set) var position: UInt64 = 0

        init(descriptor: Int32, limit: UInt64) {
            self.descriptor = descriptor; self.limit = limit
        }

        func append(_ data: Data) throws {
            guard UInt64(data.count) <= limit, position <= limit - UInt64(data.count) else {
                throw Failure.archiveTooLarge
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw outputError(errno) }
                    offset += count
                }
            }
            position += UInt64(data.count)
        }
    }

    private struct ArchivedEntry {
        let offset: UInt64
        let localHeader: Data
        let compressedSize: UInt64
        let size: UInt64
        let crc: UInt32
        let isDirectory: Bool
        let usesZIP64: Bool
        let descriptor: Data
        let centralRecord: Data
        var payloadOffset: UInt64 { offset + UInt64(localHeader.count) }
    }

    private static func write(
        _ entry: SourceEntry, writer: Writer, limits: Limits, zip64: ZIP64Thresholds, isCancelled: () -> Bool
    ) throws -> ArchivedEntry {
        guard try Snapshot.read(entry.url) == entry.snapshot else { throw Failure.sourceChanged }
        let name = Data(entry.name.utf8)
        let flags: UInt16 = entry.isDirectory ? 0x0800 : 0x0808
        let method: UInt16 = entry.isDirectory ? 0 : 8
        let (time, date) = dosDate(entry.snapshot.modifiedSeconds)
        let offset = writer.position
        // Bound the compressed size before writing the local header. ZIP64 cannot be
        // added later without shifting the already streamed payload.
        let size64 = !entry.isDirectory && UInt64(compressBound(uLong(entry.snapshot.size))) >= zip64.size
        let offset64 = offset >= zip64.offset
        let version: UInt16 = size64 || offset64 ? 45 : 20
        var localExtra = Data()
        if size64 {
            localExtra.little(UInt16(0x0001)); localExtra.little(UInt16(16))
            // Bit 3 announces the descriptor following the payload; initial sizes are unknown.
            localExtra.little(UInt64(0)); localExtra.little(UInt64(0))
        }
        var local = Data()
        local.little(UInt32(0x04034b50)); local.little(version)
        local.little(flags); local.little(method); local.little(time); local.little(date)
        local.little(UInt32(0))
        local.little(size64 ? UInt32.max : UInt32(0)); local.little(size64 ? UInt32.max : UInt32(0))
        local.little(UInt16(name.count)); local.little(UInt16(localExtra.count)); local.append(name); local.append(localExtra)
        try writer.append(local)
        let payloadOffset = writer.position
        var crc: UInt32 = 0
        var size: UInt64 = 0
        if !entry.isDirectory {
            let input = entry.url.path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
            guard input >= 0 else { throw Failure.sourceUnavailable(String(errno)) }
            defer { Darwin.close(input) }
            var current = stat()
            guard fstat(input, &current) == 0, Snapshot(current) == entry.snapshot else {
                throw Failure.sourceChanged
            }
            var stream = z_stream()
            guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS,
                               MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                               Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw Failure.compressionFailed
            }
            defer { deflateEnd(&stream) }
            var inputBuffer = [UInt8](repeating: 0, count: 65_536)
            var outputBuffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try checkCancellation(isCancelled)
                let count = inputBuffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw Failure.sourceUnavailable(String(errno)) }
                size += UInt64(count)
                guard size <= limits.maximumEntryBytes, size <= UInt64(entry.snapshot.size) else {
                    throw Failure.sourceChanged
                }
                let finished = try inputBuffer.withUnsafeMutableBufferPointer { bytes -> Bool in
                    stream.next_in = bytes.baseAddress
                    stream.avail_in = uInt(count)
                    crc = UInt32(crc32(uLong(crc), bytes.baseAddress, uInt(count)))
                    var status: Int32 = Z_OK
                    repeat {
                        try checkCancellation(isCancelled)
                        let produced: Data = outputBuffer.withUnsafeMutableBufferPointer { output in
                            stream.next_out = output.baseAddress
                            stream.avail_out = uInt(output.count)
                            status = deflate(&stream, count == 0 ? Z_FINISH : Z_NO_FLUSH)
                            return Data(bytes: output.baseAddress!, count: output.count - Int(stream.avail_out))
                        }
                        guard status == Z_OK || status == Z_STREAM_END else { throw Failure.compressionFailed }
                        try writer.append(produced)
                    } while status != Z_STREAM_END && (stream.avail_in > 0 || count == 0 || stream.avail_out == 0)
                    return status == Z_STREAM_END
                }
                if finished { break }
            }
            guard size == UInt64(entry.snapshot.size), fstat(input, &current) == 0,
                  Snapshot(current) == entry.snapshot else { throw Failure.sourceChanged }
        }
        let compressedSize = writer.position - payloadOffset
        guard size64 || (compressedSize < UInt64(UInt32.max) && size < UInt64(UInt32.max)) else {
            throw Failure.archiveTooLarge
        }
        var descriptor = Data()
        if !entry.isDirectory {
            descriptor.little(UInt32(0x08074b50)); descriptor.little(crc)
            if size64 {
                descriptor.little(compressedSize); descriptor.little(size)
            } else {
                descriptor.little(UInt32(compressedSize)); descriptor.little(UInt32(size))
            }
            try writer.append(descriptor)
        }
        // APPNOTE 4.5.3: only sentinel-valued central fields appear in this exact order.
        var centralExtra = Data()
        if size64 { centralExtra.little(size); centralExtra.little(compressedSize) }
        if offset64 { centralExtra.little(offset) }
        if !centralExtra.isEmpty {
            var header = Data()
            header.little(UInt16(0x0001)); header.little(UInt16(centralExtra.count))
            centralExtra.insert(contentsOf: header, at: 0)
        }
        var central = Data()
        central.little(UInt32(0x02014b50)); central.little(UInt16(0x0300) | version); central.little(version)
        central.little(flags); central.little(method); central.little(time); central.little(date)
        central.little(crc)
        central.little(size64 ? UInt32.max : UInt32(compressedSize)); central.little(size64 ? UInt32.max : UInt32(size))
        central.little(UInt16(name.count)); central.little(UInt16(centralExtra.count)); central.little(UInt16(0))
        central.little(UInt16(0)); central.little(UInt16(0))
        let attributes = UInt32(entry.snapshot.mode) << 16 | (entry.isDirectory ? 0x10 : 0)
        central.little(attributes); central.little(offset64 ? UInt32.max : UInt32(offset))
        central.append(name); central.append(centralExtra)
        return ArchivedEntry(offset: offset, localHeader: local, compressedSize: compressedSize,
                             size: size, crc: crc, isDirectory: entry.isDirectory, usesZIP64: size64 || offset64,
                             descriptor: descriptor, centralRecord: central)
    }

    private static func verify(
        descriptor: Int32, entries: [ArchivedEntry], centralOffset: UInt64,
        centralSize: UInt64, end: Data, archiveLength: UInt64, isCancelled: () -> Bool
    ) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_size == Int64(archiveLength),
              try readArchive(descriptor, at: centralOffset + centralSize, count: end.count) == end else {
            throw Failure.verificationFailed
        }
        var centralPosition = centralOffset
        for entry in entries {
            try checkCancellation(isCancelled)
            guard try readArchive(descriptor, at: centralPosition, count: entry.centralRecord.count) == entry.centralRecord,
                  try readArchive(descriptor, at: entry.offset, count: entry.localHeader.count) == entry.localHeader,
                  try readArchive(descriptor, at: entry.payloadOffset + UInt64(entry.compressedSize),
                                  count: entry.descriptor.count) == entry.descriptor else {
                throw Failure.verificationFailed
            }
            centralPosition += UInt64(entry.centralRecord.count)
            if entry.isDirectory { continue }
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION,
                               Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.verificationFailed }
            defer { inflateEnd(&stream) }
            var consumed: UInt64 = 0
            var expanded: UInt64 = 0
            var crc: UInt32 = 0
            var ended = false
            var outputBuffer = [UInt8](repeating: 0, count: 65_536)
            while consumed < UInt64(entry.compressedSize) {
                try checkCancellation(isCancelled)
                var input = try readArchive(descriptor, at: entry.payloadOffset + consumed,
                                            count: Int(min(65_536, UInt64(entry.compressedSize) - consumed)))
                consumed += UInt64(input.count)
                try input.withUnsafeMutableBytes { raw in
                    stream.next_in = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    stream.avail_in = uInt(raw.count)
                    repeat {
                        try checkCancellation(isCancelled)
                        let previousInput = stream.avail_in
                        var status: Int32 = Z_OK
                        let produced = outputBuffer.withUnsafeMutableBufferPointer { output -> Int in
                            stream.next_out = output.baseAddress
                            stream.avail_out = uInt(output.count)
                            status = inflate(&stream, Z_NO_FLUSH)
                            let count = output.count - Int(stream.avail_out)
                            crc = UInt32(crc32(uLong(crc), output.baseAddress, uInt(count)))
                            return count
                        }
                        expanded += UInt64(produced)
                        guard expanded <= UInt64(entry.size) else { throw Failure.verificationFailed }
                        if status == Z_STREAM_END {
                            guard stream.avail_in == 0, consumed == UInt64(entry.compressedSize) else {
                                throw Failure.verificationFailed
                            }
                            ended = true
                            break
                        }
                        guard status == Z_OK,
                              produced > 0 || stream.avail_in < previousInput else { throw Failure.verificationFailed }
                    } while stream.avail_in > 0 || stream.avail_out == 0
                }
            }
            guard ended, expanded == UInt64(entry.size), crc == entry.crc else { throw Failure.verificationFailed }
        }
    }

    private static func readArchive(_ descriptor: Int32, at offset: UInt64, count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var readCount = 0
            while readCount < count {
                let value = pread(descriptor, bytes.baseAddress!.advanced(by: readCount), count - readCount,
                                  off_t(offset + UInt64(readCount)))
                if value < 0 && errno == EINTR { continue }
                guard value > 0 else { throw Failure.verificationFailed }
                readCount += value
            }
        }
        return result
    }

    private static func dosDate(_ seconds: Int) -> (UInt16, UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                  from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        let year = min(2107, max(1980, components.year ?? 1980))
        let date = UInt16((year - 1980) << 9 | (components.month ?? 1) << 5 | (components.day ?? 1))
        let time = UInt16((components.hour ?? 0) << 11 | (components.minute ?? 0) << 5 | (components.second ?? 0) / 2)
        return (time, date)
    }

    private static func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw Failure.cancelled }
    }

    private static func outputError(_ code: Int32) -> Failure {
        switch code {
        case EACCES, EPERM, EROFS, ENOENT, ENOTDIR: return .outputUnwritable(String(code))
        case ENAMETOOLONG: return .invalidName
        default: return .outputFailure(String(code))
        }
    }
}

private extension Data {
    mutating func little<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
