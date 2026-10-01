import Foundation

/// Limits and bounds shared by snapshot readers.
public enum SnapshotQueryLimits {
    /// Lowest accepted `childPage(of:in:limit:)` value.
    public static let minimumChildPageLimit = 1
    /// Highest accepted `childPage(of:in:limit:)` value.
    public static let maximumChildPageLimit = 500
}

/// Errors raised by bounded snapshot queries before any storage is touched.
public enum SnapshotQueryError: Error, Equatable, Sendable {
    /// `childPage(of:in:limit:)` received a limit outside `1...500`.
    case invalidChildPageLimit(Int)
    /// A repository does not implement exact-name navigation restoration.
    case nameLookupUnsupported
}

/// Persisted lifecycle state for one scan, independent of UI concerns.
public struct ScanSnapshotState: Sendable, Equatable, Hashable, Codable {
    public let scanID: ScanID
    public let status: ScanStatus
    public let rootNodeID: NodeID
    public let rootDisplayName: String
    public let lastRevision: Revision
    public let startedAt: Date
    public let finishedAt: Date?
    public let fileCount: UInt64
    public let directoryCount: UInt64
    public let inaccessibleCount: UInt64
    public let issueCount: UInt64
    public let rootAttributedBytes: UInt64

    public init(
        scanID: ScanID,
        status: ScanStatus,
        rootNodeID: NodeID,
        rootDisplayName: String,
        lastRevision: Revision,
        startedAt: Date,
        finishedAt: Date?,
        fileCount: UInt64,
        directoryCount: UInt64,
        inaccessibleCount: UInt64,
        issueCount: UInt64,
        rootAttributedBytes: UInt64
    ) {
        self.scanID = scanID
        self.status = status
        self.rootNodeID = rootNodeID
        self.rootDisplayName = rootDisplayName
        self.lastRevision = lastRevision
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.inaccessibleCount = inaccessibleCount
        self.issueCount = issueCount
        self.rootAttributedBytes = rootAttributedBytes
    }
}

/// Full persisted scan header, including the policy facts needed to interpret
/// the rows. The runtime POSIX path is intentionally absent.
public struct ScanSnapshotSummary: Sendable, Equatable, Hashable, Codable {
    public let scanID: ScanID
    public let status: ScanStatus
    public let rootDisplayName: String
    public let rootNodeID: NodeID
    public let sizeMetric: SizeMetric
    public let boundaryPolicy: BoundaryPolicy
    public let packagePolicy: PackagePolicy
    public let symlinkPolicy: SymlinkPolicy
    public let startedAt: Date
    public let finishedAt: Date?
    public let lastRevision: Revision
    public let rootAttributedBytes: UInt64
    public let fileCount: UInt64
    public let directoryCount: UInt64
    public let inaccessibleCount: UInt64
    public let issueCount: UInt64
    public let volume: VolumeFacts?

    public init(
        scanID: ScanID,
        status: ScanStatus,
        rootDisplayName: String,
        rootNodeID: NodeID,
        sizeMetric: SizeMetric,
        boundaryPolicy: BoundaryPolicy,
        packagePolicy: PackagePolicy,
        symlinkPolicy: SymlinkPolicy,
        startedAt: Date,
        finishedAt: Date?,
        lastRevision: Revision,
        rootAttributedBytes: UInt64,
        fileCount: UInt64,
        directoryCount: UInt64,
        inaccessibleCount: UInt64,
        issueCount: UInt64,
        volume: VolumeFacts?
    ) {
        self.scanID = scanID
        self.status = status
        self.rootDisplayName = rootDisplayName
        self.rootNodeID = rootNodeID
        self.sizeMetric = sizeMetric
        self.boundaryPolicy = boundaryPolicy
        self.packagePolicy = packagePolicy
        self.symlinkPolicy = symlinkPolicy
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lastRevision = lastRevision
        self.rootAttributedBytes = rootAttributedBytes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.inaccessibleCount = inaccessibleCount
        self.issueCount = issueCount
        self.volume = volume
    }
}

/// Aggregated issue bucket: category + errno + optional sample name.
public struct IssueAggregateSummary: Sendable, Equatable, Hashable, Codable {
    public let category: ScanIssueCategory
    public let errnoValue: Int32?
    public let sampleNameID: NameID?
    public let count: UInt64

    public init(
        category: ScanIssueCategory,
        errnoValue: Int32?,
        sampleNameID: NameID?,
        count: UInt64
    ) {
        self.category = category
        self.errnoValue = errnoValue
        self.sampleNameID = sampleNameID
        self.count = count
    }
}

/// One bounded child row: the node fact plus its scan-local name.
///
/// `name.utf8` keeps the raw bytes so invalid UTF-8 survives the round-trip;
/// presentation layers render replacement characters without mutating storage.
///
/// A directory's immutable `NodeRecord.attributedBytes` is always `0` (it owns
/// no bytes directly); its real weight lives in `directory_aggregates`. The
/// effective weight the UI must use is exposed separately so no persisted node
/// fact is ever rewritten.
public struct SnapshotChildItem: Sendable, Equatable, Hashable, Codable {
    public let node: NodeRecord
    public let name: NameRecord
    /// Best-known subtree weight for this child: the directory aggregate when
    /// one exists (complete or partial), otherwise the node's own attributed
    /// bytes. A missing aggregate safely falls back to the node value.
    public let effectiveAttributedBytes: UInt64

    public init(node: NodeRecord, name: NameRecord, effectiveAttributedBytes: UInt64? = nil) {
        self.node = node
        self.name = name
        self.effectiveAttributedBytes = effectiveAttributedBytes ?? node.attributedBytes
    }
}

/// A bounded page of direct children plus the total number of direct children.
///
/// `totalCount` lets the UI say "showing first N of M" without running an
/// unbounded `children(of:)` query over an extremely wide root. `items` are
/// ordered by effective attributed bytes descending, then `NodeID` ascending.
/// (revision, aggregate, count, items) came from one read-only transaction.
public struct SnapshotChildPage: Sendable, Equatable, Hashable, Codable {
    public let items: [SnapshotChildItem]
    public let totalCount: UInt64
    public let snapshotRevision: Revision
    public let parentAggregate: DirectoryAggregateRecord?

    public init(
        items: [SnapshotChildItem],
        totalCount: UInt64,
        snapshotRevision: Revision = Revision(0),
        parentAggregate: DirectoryAggregateRecord? = nil
    ) {
        self.items = items
        self.totalCount = totalCount
        self.snapshotRevision = snapshotRevision
        self.parentAggregate = parentAggregate
    }
}

/// Row counts persisted for one scan.
public struct SnapshotStatistics: Sendable, Equatable, Hashable, Codable {
    public let nodeCount: UInt64
    public let nameCount: UInt64
    public let aggregateCount: UInt64
    public let issueCount: UInt64

    public init(
        nodeCount: UInt64,
        nameCount: UInt64,
        aggregateCount: UInt64,
        issueCount: UInt64
    ) {
        self.nodeCount = nodeCount
        self.nameCount = nameCount
        self.aggregateCount = aggregateCount
        self.issueCount = issueCount
    }
}
