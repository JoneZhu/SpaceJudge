import Darwin
import Foundation
import SpaceJudgeDomain

/// Open directory passed to a `DirectoryEnumerator`. The enumerator never
/// closes the underlying descriptor; the engine owns it.
public struct DirectoryHandle: Sendable {
    public let fileDescriptor: Int32

    public init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }
}

/// Cooperative, thread-safe cancellation flag shared between the coordinator
/// and the blocking enumeration workers.
public final class ScanCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Per-directory enumeration request. Carries only what a single directory
/// enumeration needs; policy decisions live in the coordinator.
public struct EnumerationRequest: Sendable {
    public let cancellation: ScanCancellationToken

    public init(cancellation: ScanCancellationToken = ScanCancellationToken()) {
        self.cancellation = cancellation
    }
}

/// One immediate child of a directory as reported by an enumerator.
///
/// Byte-level names are preserved. `kind`, sizes and identity are the
/// enumerator's best facts; `nil` means "the file system did not report it",
/// never a fabricated zero.
public struct RawDirectoryEntry: Sendable, Equatable, Hashable {
    public let nameBytes: [UInt8]
    public let kind: NodeKind
    public let logicalBytes: UInt64?
    public let allocatedBytes: UInt64?
    public let deviceID: UInt64?
    public let fileID: UInt64?
    public let parentFileID: UInt64?
    public let linkCount: UInt64?
    public let modifiedAt: Date?
    /// `ATTR_CMN_ERROR` for this entry, when non-zero.
    public let entryError: Int32?
    /// Directory is a file-system mount point (`DIR_MNTSTATUS_MNTPOINT`).
    public let isMountPoint: Bool
    /// Directory is a system-published firmlink (`SF_FIRMLINK`).
    public let isFirmlink: Bool
    /// The enumerator had to fall back for this directory.
    public let usesFallback: Bool

    public init(
        nameBytes: [UInt8],
        kind: NodeKind,
        logicalBytes: UInt64? = nil,
        allocatedBytes: UInt64? = nil,
        deviceID: UInt64? = nil,
        fileID: UInt64? = nil,
        parentFileID: UInt64? = nil,
        linkCount: UInt64? = nil,
        modifiedAt: Date? = nil,
        entryError: Int32? = nil,
        isMountPoint: Bool = false,
        isFirmlink: Bool = false,
        usesFallback: Bool = false
    ) {
        self.nameBytes = nameBytes
        self.kind = kind
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.deviceID = deviceID
        self.fileID = fileID
        self.parentFileID = parentFileID
        self.linkCount = linkCount
        self.modifiedAt = modifiedAt
        self.entryError = entryError
        self.isMountPoint = isMountPoint
        self.isFirmlink = isFirmlink
        self.usesFallback = usesFallback
    }
}

/// One bounded page of immediate children produced by a `DirectoryCursor`.
///
/// An empty final page is legal. A non-final page must not be empty except
/// when the underlying system call legitimately produced no new facts.
public struct DirectoryEntryPage: Sendable, Equatable {
    public let entries: [RawDirectoryEntry]
    public let isLast: Bool

    public init(entries: [RawDirectoryEntry], isLast: Bool) {
        self.entries = entries
        self.isLast = isLast
    }

    /// Convenience for the common single-page case.
    public static func final(_ entries: [RawDirectoryEntry]) -> DirectoryEntryPage {
        DirectoryEntryPage(entries: entries, isLast: true)
    }
}

/// A worker-exclusive cursor over one directory.
///
/// A cursor owns whatever `readdir` state, buffer or duplicated descriptor it
/// created. It must never be shared across workers or actors. Reaching the
/// final page or being deinitialized must release those resources exactly
/// once; `nextPage()` after the final page returns an empty final page.
public protocol DirectoryCursor {
    mutating func nextPage() throws -> DirectoryEntryPage
}

/// Enumerates the immediate children of a single directory.
///
/// Implementations must not follow symbolic links and must not close the
/// `DirectoryHandle` descriptor passed by the engine. `makeCursor` transfers
/// ownership of a duplicated descriptor (or of a reused buffer) to the
/// returned cursor.
public protocol DirectoryEnumerator: Sendable {
    func makeCursor(
        in directory: DirectoryHandle,
        request: EnumerationRequest
    ) throws -> any DirectoryCursor
}

/// Errors surfaced by the scan engine and enumerators.
public enum ScanError: Error, Equatable, Sendable {
    /// The scan root could not be opened; the whole scan is fatal.
    case rootOpenFailed(errno: Int32)
    /// A child directory could not be opened; the scan continues.
    case directoryOpenFailed(errno: Int32)
    /// `getattrlistbulk` or `readdir` failed.
    case enumerationFailed(errno: Int32)
    /// A parser rejected the kernel buffer.
    case parseFailed(DarwinAttributeParseError)
    /// A scan with the same `ScanID` is already running.
    case duplicateScan(ScanID)
    /// The scan was cancelled before work could start.
    case cancelled
    /// A byte aggregate would overflow `UInt64`.
    case aggregationOverflow(nodeID: NodeID?)
    /// A scan counter would overflow `UInt64`.
    case counterOverflow(context: String)
    /// A fact violated the `attributed <= allocated` invariant.
    case attributionExceedsAllocation(nodeID: NodeID)
    /// The directory spool could not be created, read, written or decoded.
    case spoolFailed(String)
    /// The scan root is SpaceJudge's own snapshot workspace, or lives inside it.
    /// Scanning it would make the cache enumerate itself, so it is refused
    /// before `.started` is published.
    case scanRootInsideSnapshotWorkspace
    /// The request carried more session-only workspace exclusions than the
    /// bounded contract allows.
    case tooManyWorkspaceExclusions(limit: Int)

    public var errnoValue: Int32? {
        switch self {
        case .rootOpenFailed(let value), .directoryOpenFailed(let value),
             .enumerationFailed(let value):
            return value
        case .parseFailed, .duplicateScan, .cancelled,
             .aggregationOverflow, .counterOverflow, .attributionExceedsAllocation,
             .spoolFailed, .scanRootInsideSnapshotWorkspace,
             .tooManyWorkspaceExclusions:
            return nil
        }
    }
}

/// Maps a POSIX errno to the scan issue taxonomy.
public enum ScanIssueClassifier {
    public static func category(for errno: Int32) -> ScanIssueCategory {
        switch errno {
        case EACCES, EPERM:
            return .permissionDenied
        case ENOENT, ENOTDIR:
            return .notFound
        case ENAMETOOLONG, EMFILE, ENFILE, ENOMEM, EOVERFLOW:
            return .resourceLimit
        case ENOTSUP:
            return .unsupported
        default:
            return .io
        }
    }
}

/// Maps Darwin `fsobj_type_t` (`enum vtype`) to a `NodeKind`.
public enum NodeKindMapper {
    public static func kind(forObjType objType: UInt32) -> NodeKind {
        switch objType {
        case 1: return .regularFile   // VREG
        case 2: return .directory     // VDIR
        case 3: return .blockDevice   // VBLK
        case 4: return .characterDevice // VCHR
        case 5: return .symbolicLink  // VLNK
        case 6: return .socket        // VSOCK
        case 7: return .fifo          // VFIFO
        default: return .unknown
        }
    }

    public static func kind(forMode mode: mode_t) -> NodeKind {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): return .regularFile
        case mode_t(S_IFDIR): return .directory
        case mode_t(S_IFLNK): return .symbolicLink
        case mode_t(S_IFSOCK): return .socket
        case mode_t(S_IFIFO): return .fifo
        case mode_t(S_IFCHR): return .characterDevice
        case mode_t(S_IFBLK): return .blockDevice
        default: return .unknown
        }
    }
}

/// Converts a signed POSIX value to `UInt64`, returning `nil` for negatives.
func nonNegativeUInt64(_ value: some BinaryInteger) -> UInt64? {
    guard value >= 0 else { return nil }
    return UInt64(value)
}

/// Converts a 32-bit device identifier to an unsigned representation without
/// losing the bit pattern of large `dev_t` values.
func deviceIdentifier(_ value: Int32) -> UInt64 {
    UInt64(UInt32(bitPattern: value))
}
