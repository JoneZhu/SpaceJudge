import Darwin
import Foundation
import SpaceJudgeDomain

/// Correctness-first enumerator built on `fdopendir`/`readdir` plus `fstatat`.
///
/// It never follows symbolic links (both `fdopendir` and `fstatat` are used in
/// a no-follow way) and reports sizes in the same terms as the bulk path so the
/// two can be differentially compared.
///
/// One `makeCursor` call duplicates the directory descriptor and owns the
/// resulting `DIR*`; the cursor returns at most `pageEntryLimit` entries per
/// page so a single wide directory is never materialized as one array.
public struct ReferenceEnumerator: DirectoryEnumerator {
    /// Maximum entries returned in one `DirectoryEntryPage`. Defaults to the
    /// 1,024-entry page from `docs/10-phase-2-design.md`; tests use smaller
    /// values to exercise page boundaries.
    public let pageEntryLimit: Int

    public init(pageEntryLimit: Int = 1024) {
        self.pageEntryLimit = max(1, pageEntryLimit)
    }

    public func makeCursor(
        in directory: DirectoryHandle,
        request: EnumerationRequest
    ) throws -> any DirectoryCursor {
        // `fdopendir` consumes its descriptor, so duplicate first. The cursor
        // owns the duplicate; the engine keeps the original.
        _ = lseek(directory.fileDescriptor, 0, SEEK_SET)
        let duplicated = dup(directory.fileDescriptor)
        guard duplicated >= 0 else {
            throw ScanError.enumerationFailed(errno: errno)
        }
        guard let stream = fdopendir(duplicated) else {
            let code = errno
            _ = close(duplicated)
            throw ScanError.enumerationFailed(errno: code)
        }
        return ReferenceCursor(
            stream: stream,
            directoryFileDescriptor: directory.fileDescriptor,
            request: request,
            pageEntryLimit: pageEntryLimit
        )
    }
}

/// Worker-exclusive `readdir` cursor. `closedir` releases the duplicated
/// descriptor exactly once, whether the cursor reached its final page or was
/// dropped early (cancel / error).
final class ReferenceCursor: DirectoryCursor {
    private let stream: UnsafeMutablePointer<DIR>
    private let directoryFileDescriptor: Int32
    private let request: EnumerationRequest
    private let pageEntryLimit: Int
    private var finished = false

    init(
        stream: UnsafeMutablePointer<DIR>,
        directoryFileDescriptor: Int32,
        request: EnumerationRequest,
        pageEntryLimit: Int
    ) {
        self.stream = stream
        self.directoryFileDescriptor = directoryFileDescriptor
        self.request = request
        self.pageEntryLimit = pageEntryLimit
    }

    deinit {
        closedir(stream)
    }

    func nextPage() throws -> DirectoryEntryPage {
        if finished {
            return DirectoryEntryPage(entries: [], isLast: true)
        }
        var result: [RawDirectoryEntry] = []
        result.reserveCapacity(pageEntryLimit)
        while result.count < pageEntryLimit {
            if request.cancellation.isCancelled {
                throw ScanError.cancelled
            }
            errno = 0
            guard let rawEntry = readdir(stream) else {
                if errno != 0 {
                    throw ScanError.enumerationFailed(errno: errno)
                }
                finished = true
                return DirectoryEntryPage(entries: result, isLast: true)
            }
            let nameBytes = Self.nameBytes(of: rawEntry.pointee)
            if nameBytes == Self.dot || nameBytes == Self.dotDot {
                continue
            }

            var status = stat()
            let statResult = withCString(nameBytes) { pointer -> Int32 in
                fstatat(directoryFileDescriptor, pointer, &status, AT_SYMLINK_NOFOLLOW)
            }
            if statResult != 0 {
                let code = errno
                result.append(
                    RawDirectoryEntry(nameBytes: nameBytes, kind: .unknown, entryError: code)
                )
                continue
            }

            let kind = NodeKindMapper.kind(forMode: status.st_mode)
            let isDirectory = kind == .directory
            let logical: UInt64?
            let allocated: UInt64?
            if isDirectory {
                // Directory self-size is intentionally not reported; the bulk
                // path cannot report it either.
                logical = nil
                allocated = nil
            } else {
                logical = nonNegativeUInt64(status.st_size)
                allocated = ReferenceSizing.allocatedBytes(fromBlockCount: status.st_blocks)
            }

            result.append(
                RawDirectoryEntry(
                    nameBytes: nameBytes,
                    kind: kind,
                    logicalBytes: logical,
                    allocatedBytes: allocated,
                    deviceID: deviceIdentifier(status.st_dev),
                    fileID: UInt64(status.st_ino),
                    parentFileID: nil,
                    linkCount: UInt64(status.st_nlink),
                    modifiedAt: Date(
                        timeIntervalSince1970: Double(status.st_mtimespec.tv_sec)
                            + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000
                    ),
                    entryError: nil,
                    isMountPoint: false,
                    usesFallback: false
                )
            )
        }
        return DirectoryEntryPage(entries: result, isLast: false)
    }

    private static let dot: [UInt8] = [UInt8(ascii: ".")]
    private static let dotDot: [UInt8] = [UInt8(ascii: "."), UInt8(ascii: ".")]

    private static func nameBytes(of entry: dirent) -> [UInt8] {
        var name = [UInt8]()
        withUnsafeBytes(of: entry.d_name) { raw in
            for byte in raw {
                if byte == 0 {
                    break
                }
                name.append(byte)
            }
        }
        return name
    }

    private func withCString<T>(_ bytes: [UInt8], _ body: (UnsafePointer<CChar>) throws -> T) rethrows -> T {
        var cString = bytes.map { CChar(bitPattern: $0) }
        cString.append(0)
        return try cString.withUnsafeBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
