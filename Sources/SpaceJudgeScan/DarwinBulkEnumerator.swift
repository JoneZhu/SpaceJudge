import Darwin
import Foundation
import SpaceJudgeDomain

/// Fast-path enumerator using `getattrlistbulk(2)`.
///
/// The attribute request and the parsing rules follow
/// `docs/08-phase-1-design.md`. One `nextPage()` call performs exactly one
/// `getattrlistbulk` into a bounded buffer that the cursor allocates once and
/// reuses for its whole lifetime.
///
/// When the file system does not support the fast path, the cursor falls back
/// to `ReferenceEnumerator` for that directory and marks every returned entry
/// with `usesFallback`. The fallback is only legal before the first bulk page
/// has been published; after that a parser or syscall failure must fail
/// explicitly instead of rewinding and re-emitting facts.
public struct DarwinBulkEnumerator: DirectoryEnumerator {
    public typealias BulkReader = @Sendable (
        Int32,
        UnsafeMutablePointer<attrlist>,
        UnsafeMutableRawPointer,
        Int,
        UInt64
    ) -> Int32
    public typealias PageParser = @Sendable (
        UnsafeRawBufferPointer,
        Int,
        DarwinAttributeBufferParser.Request
    ) throws -> [RawDirectoryEntry]

    public let bufferSize: Int
    public let parser: DarwinAttributeBufferParser
    private let fallback: ReferenceEnumerator
    /// Test seam so fallback-vs-fail decisions can be exercised without
    /// depending on a real kernel buffer. Production uses `getattrlistbulk`.
    let bulkRead: BulkReader
    let parsePage: PageParser

    public init(
        bufferSize: Int = 256 * 1024,
        parser: DarwinAttributeBufferParser = DarwinAttributeBufferParser(),
        fallback: ReferenceEnumerator = ReferenceEnumerator()
    ) {
        self.init(
            bufferSize: bufferSize,
            parser: parser,
            fallback: fallback,
            bulkRead: { fileDescriptor, list, buffer, capacity, options in
                getattrlistbulk(fileDescriptor, list, buffer, capacity, options)
            },
            parsePage: { rawBuffer, entryCount, request in
                try parser.parse(
                    rawBuffer: rawBuffer,
                    entryCount: entryCount,
                    request: request
                )
            }
        )
    }

    init(
        bufferSize: Int,
        parser: DarwinAttributeBufferParser,
        fallback: ReferenceEnumerator,
        bulkRead: @escaping BulkReader,
        parsePage: @escaping PageParser
    ) {
        self.bufferSize = max(bufferSize, 32)
        self.parser = parser
        self.fallback = fallback
        self.bulkRead = bulkRead
        self.parsePage = parsePage
    }

    public func makeCursor(
        in directory: DirectoryHandle,
        request: EnumerationRequest
    ) throws -> any DirectoryCursor {
        BulkCursor(
            directoryFileDescriptor: directory.fileDescriptor,
            bufferSize: bufferSize,
            fallback: fallback,
            request: request,
            bulkRead: bulkRead,
            parsePage: parsePage
        )
    }
}

/// Worker-exclusive page cursor over `getattrlistbulk`.
final class BulkCursor: DirectoryCursor {
    private let directoryFileDescriptor: Int32
    private let buffer: UnsafeMutableRawPointer
    private let capacity: Int
    private let fallback: ReferenceEnumerator
    private let request: EnumerationRequest
    private let bulkRead: DarwinBulkEnumerator.BulkReader
    private let parsePage: DarwinBulkEnumerator.PageParser
    private var attrList: attrlist
    private var publishedBulkPage = false
    private var finished = false
    private var fallbackCursor: (any DirectoryCursor)?

    init(
        directoryFileDescriptor: Int32,
        bufferSize: Int,
        fallback: ReferenceEnumerator,
        request: EnumerationRequest,
        bulkRead: @escaping DarwinBulkEnumerator.BulkReader,
        parsePage: @escaping DarwinBulkEnumerator.PageParser
    ) {
        self.directoryFileDescriptor = directoryFileDescriptor
        self.capacity = bufferSize
        self.fallback = fallback
        self.request = request
        self.bulkRead = bulkRead
        self.parsePage = parsePage
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        let attributeRequest = DarwinAttributeBufferParser.Request.phase1
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = attributeRequest.commonattr
        list.dirattr = attributeRequest.dirattr
        list.fileattr = attributeRequest.fileattr
        list.volattr = 0
        list.forkattr = 0
        self.attrList = list
    }

    deinit {
        buffer.deallocate()
    }

    func nextPage() throws -> DirectoryEntryPage {
        if fallbackCursor != nil {
            return try nextFallbackPage()
        }
        if finished {
            return DirectoryEntryPage(entries: [], isLast: true)
        }
        if request.cancellation.isCancelled {
            throw ScanError.cancelled
        }

        let count = bulkRead(
            directoryFileDescriptor,
            &attrList,
            buffer,
            capacity,
            UInt64(truncatingIfNeeded: FSOPT_PACK_INVAL_ATTRS)
        )
        if count < 0 {
            let code = errno
            if !publishedBulkPage, Self.requiresFallback(errno: code) {
                return try startFallbackIfAllowed()
            }
            throw ScanError.enumerationFailed(errno: code)
        }
        if count == 0 {
            finished = true
            return DirectoryEntryPage(entries: [], isLast: true)
        }

        let raw = UnsafeRawBufferPointer(start: buffer, count: capacity)
        do {
            let parsed = try parsePage(
                raw,
                Int(count),
                DarwinAttributeBufferParser.Request.phase1
            )
            publishedBulkPage = true
            return DirectoryEntryPage(entries: parsed, isLast: false)
        } catch let error as DarwinAttributeParseError {
            if !publishedBulkPage {
                return try startFallbackIfAllowed()
            }
            throw ScanError.parseFailed(error)
        } catch {
            if !publishedBulkPage {
                return try startFallbackIfAllowed()
            }
            throw ScanError.enumerationFailed(errno: EIO)
        }
    }

    /// Only called before any bulk page has been published, so a rewind cannot
    /// duplicate facts.
    private func startFallbackIfAllowed() throws -> DirectoryEntryPage {
        let cursor = try fallback.makeCursor(
            in: DirectoryHandle(fileDescriptor: directoryFileDescriptor),
            request: request
        )
        fallbackCursor = cursor
        return try nextFallbackPage()
    }

    /// Advances the fallback cursor while writing any value-semantics state
    /// back into the stored existential. Class-based cursors share state, but
    /// this keeps the protocol free of a class constraint.
    private func nextFallbackPage() throws -> DirectoryEntryPage {
        guard var cursor = fallbackCursor else {
            return DirectoryEntryPage(entries: [], isLast: true)
        }
        let page = try cursor.nextPage()
        fallbackCursor = cursor
        return DirectoryEntryPage(
            entries: page.entries.map(Self.markingFallback),
            isLast: page.isLast
        )
    }

    /// Rewrites an entry produced by the reference fallback so it is marked as
    /// fallback-backed. Every other fact, including the firmlink flag, is
    /// preserved. Internal so tests can assert the copy contract directly.
    static func markingFallback(_ entry: RawDirectoryEntry) -> RawDirectoryEntry {
        RawDirectoryEntry(
            nameBytes: entry.nameBytes,
            kind: entry.kind,
            logicalBytes: entry.logicalBytes,
            allocatedBytes: entry.allocatedBytes,
            deviceID: entry.deviceID,
            fileID: entry.fileID,
            parentFileID: entry.parentFileID,
            linkCount: entry.linkCount,
            modifiedAt: entry.modifiedAt,
            entryError: entry.entryError,
            isMountPoint: entry.isMountPoint,
            isFirmlink: entry.isFirmlink,
            usesFallback: true
        )
    }

    private static func requiresFallback(errno code: Int32) -> Bool {
        switch code {
        case ENOTSUP, EINVAL, ERANGE:
            return true
        default:
            return false
        }
    }
}
