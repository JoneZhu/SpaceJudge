import Foundation

/// Which byte value drives the default spatial weight.
public enum SizeMetric: Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// On-disk allocated bytes (`ATTR_FILE_ALLOCSIZE`). Default for the map.
    case allocated
    /// Logical bytes (`ATTR_FILE_TOTALSIZE`).
    case logical
}

/// How the traversal treats mount points.
public enum BoundaryPolicy: Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Only descend inside the selected tree.
    case selectedTree
    /// Stay on the root file system; a mount point becomes a boundary leaf.
    case stayOnRootFileSystem
    /// Traverse the unified visible startup volume group: follow firmlink
    /// projections into the paired data volume, but always stop at real mount
    /// points and unauthorized device transitions.
    ///
    /// This case was appended after Phase 5A so the frozen SQLite encoding of
    /// `selectedTree` (0) and `stayOnRootFileSystem` (1) does not change.
    case visibleStartupVolumeGroup
}

/// How the traversal treats Finder packages.
public enum PackagePolicy: Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Descend into the package as an ordinary directory.
    case descend
    /// Treat the package as a leaf node.
    case treatAsLeaf
}

/// How symlinks are handled. MVP never follows symlinks.
public enum SymlinkPolicy: Sendable, Equatable, Hashable, Codable, CaseIterable {
    case doNotFollow
}

/// The user-authorized scan root.
///
/// The runtime POSIX path used to open the root and the user-facing display
/// name are modeled separately: `fileSystemPath` carries access semantics for
/// the current `ScanRequest` only, while `displayName` is what the UI shows.
/// Diagnostics must still not persist full personal paths by default.
public struct ScanRoot: Sendable, Equatable, Hashable, Codable {
    /// Runtime POSIX path handed to the future enumerator (`open()`/`fstatat`).
    /// Session-only: it is not written to diagnostics or snapshots by default.
    public let fileSystemPath: String
    /// User-facing label; may differ from `fileSystemPath`.
    public let displayName: String
    /// Identifier of the file system the root lives on, when known.
    public let fileSystemID: UInt64?

    public init(fileSystemPath: String, displayName: String, fileSystemID: UInt64? = nil) {
        self.fileSystemPath = fileSystemPath
        self.displayName = displayName
        self.fileSystemID = fileSystemID
    }
}

/// Immutable description of what to scan.
public struct ScanRequest: Sendable, Equatable, Hashable, Codable {
    /// Upper bound for the session-only exclusion set. Production passes at most
    /// one workspace root; tests may pass a handful. Anything larger is rejected
    /// before the scan starts so a request can never carry an unbounded array.
    public static let maximumWorkspaceExclusions = 8

    public let root: ScanRoot
    public let sizeMetric: SizeMetric
    public let boundaryPolicy: BoundaryPolicy
    public let packagePolicy: PackagePolicy
    public let symlinkPolicy: SymlinkPolicy
    /// Session-only directories that must be shown as storage boundaries. Never
    /// persisted to SQLite, logs or diagnostics.
    public let workspaceExclusions: [SnapshotWorkspaceExclusion]

    public init(
        root: ScanRoot,
        sizeMetric: SizeMetric = .allocated,
        boundaryPolicy: BoundaryPolicy = .stayOnRootFileSystem,
        packagePolicy: PackagePolicy = .descend,
        symlinkPolicy: SymlinkPolicy = .doNotFollow,
        workspaceExclusions: [SnapshotWorkspaceExclusion] = []
    ) {
        self.root = root
        self.sizeMetric = sizeMetric
        self.boundaryPolicy = boundaryPolicy
        self.packagePolicy = packagePolicy
        self.symlinkPolicy = symlinkPolicy
        self.workspaceExclusions = workspaceExclusions
    }
}

/// Volume accounting captured alongside a scan. Values may be unknown while a
/// scan is prepared.
public struct VolumeFacts: Sendable, Equatable, Hashable, Codable {
    public let totalCapacityBytes: UInt64?
    public let availableCapacityBytes: UInt64?
    public let capacitySource: CapacitySource

    public init(
        totalCapacityBytes: UInt64?,
        availableCapacityBytes: UInt64?,
        capacitySource: CapacitySource
    ) {
        self.totalCapacityBytes = totalCapacityBytes
        self.availableCapacityBytes = availableCapacityBytes
        self.capacitySource = capacitySource
    }

    /// `volumeUsed = total - available` when both are known and `total >= available`.
    public var usedBytes: UInt64? {
        guard let totalCapacityBytes, let availableCapacityBytes,
              totalCapacityBytes >= availableCapacityBytes else {
            return nil
        }
        return totalCapacityBytes - availableCapacityBytes
    }
}

/// Provenance of capacity numbers so the UI and tests can label them.
public enum CapacitySource: Sendable, Equatable, Hashable, Codable, CaseIterable {
    case importantUsage
    case standardAvailable
    case unavailable
}

/// Header facts established when a scan starts.
public struct ScanMetadata: Sendable, Equatable, Hashable, Codable {
    public let scanID: ScanID
    public let request: ScanRequest
    public let startedAt: Date
    public let rootNodeID: NodeID
    public let volume: VolumeFacts?

    public init(
        scanID: ScanID,
        request: ScanRequest,
        startedAt: Date,
        rootNodeID: NodeID,
        volume: VolumeFacts? = nil
    ) {
        self.scanID = scanID
        self.request = request
        self.startedAt = startedAt
        self.rootNodeID = rootNodeID
        self.volume = volume
    }
}

/// Coarse lifecycle state reported with progress and summaries.
public enum ScanStatus: Sendable, Equatable, Hashable, Codable, CaseIterable {
    case running
    case cancelling
    case completed
    case cancelled
    case failed
    case interrupted
}

/// Counters-only progress. The scan never reports a fake percentage because
/// the total node count is unknown before iteration finishes.
public struct ScanProgress: Sendable, Equatable, Hashable, Codable {
    public let revision: Revision
    public let status: ScanStatus
    public let fileCount: UInt64
    public let directoryCount: UInt64
    public let attributedBytes: UInt64
    public let pendingDirectories: UInt64
    public let entriesPerSecond: Double
    public let elapsedSeconds: Double

    public init(
        revision: Revision,
        status: ScanStatus,
        fileCount: UInt64,
        directoryCount: UInt64,
        attributedBytes: UInt64,
        pendingDirectories: UInt64,
        entriesPerSecond: Double,
        elapsedSeconds: Double
    ) {
        self.revision = revision
        self.status = status
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.attributedBytes = attributedBytes
        self.pendingDirectories = pendingDirectories
        self.entriesPerSecond = entriesPerSecond
        self.elapsedSeconds = elapsedSeconds
    }
}

/// Recoverable per-directory or per-entry problem. Issues are aggregated; a
/// single issue never fails the whole scan.
public struct ScanIssue: Sendable, Equatable, Hashable, Codable {
    public let scanID: ScanID
    public let category: ScanIssueCategory
    public let nodeID: NodeID?
    public let errnoValue: Int32?
    public let sampleName: NameID?
    public let count: UInt64

    public init(
        scanID: ScanID,
        category: ScanIssueCategory,
        nodeID: NodeID? = nil,
        errnoValue: Int32? = nil,
        sampleName: NameID? = nil,
        count: UInt64 = 1
    ) {
        self.scanID = scanID
        self.category = category
        self.nodeID = nodeID
        self.errnoValue = errnoValue
        self.sampleName = sampleName
        self.count = count
    }
}

public enum ScanIssueCategory: Sendable, Equatable, Hashable, Codable, CaseIterable {
    case permissionDenied
    case notFound
    case io
    case nameEncoding
    case mountBoundary
    case changedDuringScan
    case resourceLimit
    case unsupported
}

/// Final or terminal accounting for one scan.
public struct ScanSummary: Sendable, Equatable, Hashable, Codable {
    public let scanID: ScanID
    public let status: ScanStatus
    public let startedAt: Date
    public let finishedAt: Date?
    public let fileCount: UInt64
    public let directoryCount: UInt64
    public let inaccessibleCount: UInt64
    public let issueCount: UInt64
    public let rootAttributedBytes: UInt64
    public let volume: VolumeFacts?

    public init(
        scanID: ScanID,
        status: ScanStatus,
        startedAt: Date,
        finishedAt: Date? = nil,
        fileCount: UInt64,
        directoryCount: UInt64,
        inaccessibleCount: UInt64,
        issueCount: UInt64,
        rootAttributedBytes: UInt64,
        volume: VolumeFacts? = nil
    ) {
        self.scanID = scanID
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.inaccessibleCount = inaccessibleCount
        self.issueCount = issueCount
        self.rootAttributedBytes = rootAttributedBytes
        self.volume = volume
    }

    /// `unattributed = max(0, volumeUsed - rootAttributed)`.
    public var unattributedBytes: UInt64? {
        guard let used = volume?.usedBytes else { return nil }
        return used > rootAttributedBytes ? used - rootAttributedBytes : 0
    }

    /// Diagnostic value for when attribution exceeds the reported used bytes
    /// (clones, concurrent change, or a different metering basis).
    public var overAttributedBytes: UInt64? {
        guard let used = volume?.usedBytes else { return nil }
        return rootAttributedBytes > used ? rootAttributedBytes - used : 0
    }
}

/// Bounded event stream produced by a `ScanEngine`.
public enum ScanEvent: Sendable, Equatable, Hashable, Codable {
    case started(ScanMetadata)
    case batch(NodeBatch)
    case progress(ScanProgress)
    case issue(ScanIssue)
    case completed(ScanSummary)
    case cancelled(ScanSummary)
}
