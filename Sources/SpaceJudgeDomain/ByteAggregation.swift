import Foundation

/// Errors raised while combining byte values. All aggregation paths surface
/// overflow explicitly instead of silently wrapping or clamping.
public enum ByteAggregationError: Error, Equatable, Sendable {
    /// Adding two `UInt64` values would exceed `UInt64.max`.
    case overflow(nodeID: NodeID?, context: String)
    /// A file record with no parent cannot be attributed into a directory.
    case missingParent(nodeID: NodeID)
    /// A directory was already completed and must not be completed twice.
    case duplicateCompletion(nodeID: NodeID)
    /// A node received new contributions after it (or its parent) completed.
    case directoryAlreadyCompleted(nodeID: NodeID)
}

/// Detects and reports overflow-prone byte sums.
public enum SafeByteAggregation {
    /// Adds two values, throwing `ByteAggregationError.overflow` if the result
    /// would exceed `UInt64.max`.
    public static func add(
        _ lhs: UInt64,
        _ rhs: UInt64,
        nodeID: NodeID? = nil,
        context: String = "add"
    ) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw ByteAggregationError.overflow(nodeID: nodeID, context: context)
        }
        return sum
    }

    /// Sums a sequence with overflow detection.
    public static func sum(
        _ values: some Sequence<UInt64>,
        nodeID: NodeID? = nil,
        context: String = "sum"
    ) throws -> UInt64 {
        var total: UInt64 = 0
        for value in values {
            total = try add(total, value, nodeID: nodeID, context: context)
        }
        return total
    }
}

/// Result of asking the hard-link attributor about one file occurrence.
public enum HardLinkClaim: Sendable, Equatable, Hashable {
    /// First occurrence of this `FileIdentity`; its bytes are attributed.
    case first
    /// Later occurrence of the same inode; attributed bytes must be zero.
    case duplicate
}

/// Remembers which file identities have already been counted.
///
/// The attributor is a pure value state machine. It is deliberately not an
/// actor: the aggregator is serial by design, and adding concurrency here
/// would complicate the algorithm before it is needed.
public struct HardLinkAttributor: Sendable, Equatable {
    private var seen: Set<FileIdentity>

    public init() {
        self.seen = []
    }

    /// Claims an identity. The first claim returns `.first`; every later claim
    /// returns `.duplicate`.
    public mutating func claim(_ identity: FileIdentity) -> HardLinkClaim {
        let inserted = seen.insert(identity).inserted
        return inserted ? .first : .duplicate
    }

    public func hasSeen(_ identity: FileIdentity) -> Bool {
        seen.contains(identity)
    }

    /// Number of distinct identities claimed so far.
    public var claimedCount: Int { seen.count }

    /// Applies the attribution policy to a raw file size.
    ///
    /// The first occurrence of an identity contributes `allocatedBytes`; later
    /// occurrences contribute zero. Records without a file identity (for
    /// example entries synthesized by tests) are always attributed once.
    public mutating func attribute(
        identity: FileIdentity?,
        allocatedBytes: UInt64
    ) -> UInt64 {
        guard let identity else { return allocatedBytes }
        switch claim(identity) {
        case .first:
            return allocatedBytes
        case .duplicate:
            return 0
        }
    }
}

/// Pure directory aggregation state.
///
/// Direct file contributions and completed child directories may arrive in any
/// completion order. The final value for a completed directory always equals
/// the sum of its direct file attribution and the totals of its completed
/// children, which is the docs/04 numeric invariant.
///
/// The state machine is intentionally single-threaded. A future scan
/// coordinator can own it behind an actor without changing these semantics.
public struct DirectoryAggregator: Sendable, Equatable {
    /// Bytes attributed directly to a node (typically its regular files).
    private var directAttributed: [NodeID: UInt64]
    /// Sum of completed child directories, folded in when each child completes.
    private var childAttributed: [NodeID: UInt64]
    /// Number of direct file contributions per node.
    private var directCounts: [NodeID: UInt64]
    /// Number of completed child directories per node.
    private var childCounts: [NodeID: UInt64]
    /// Directories that have already been completed.
    private var completed: Set<NodeID>

    public init() {
        self.directAttributed = [:]
        self.childAttributed = [:]
        self.directCounts = [:]
        self.childCounts = [:]
        self.completed = []
    }

    /// Adds a non-directory node's attributed bytes to its parent's direct
    /// bucket. Returns the parent's running direct total.
    @discardableResult
    public mutating func addDirectFile(_ record: NodeRecord) throws -> UInt64 {
        guard let parentID = record.parentID else {
            throw ByteAggregationError.missingParent(nodeID: record.id)
        }
        return try addDirectBytes(record.attributedBytes, to: parentID, count: 1)
    }

    /// Adds a direct byte contribution (and optional item count) directly to a
    /// node. Useful when facts are processed in normalized form.
    @discardableResult
    public mutating func addDirectBytes(
        _ bytes: UInt64,
        to nodeID: NodeID,
        count: UInt64 = 1
    ) throws -> UInt64 {
        guard !completed.contains(nodeID) else {
            throw ByteAggregationError.directoryAlreadyCompleted(nodeID: nodeID)
        }
        let current = directAttributed[nodeID, default: 0]
        let updated = try SafeByteAggregation.add(
            current,
            bytes,
            nodeID: nodeID,
            context: "directAttributed"
        )
        directAttributed[nodeID] = updated
        if count != 0 {
            directCounts[nodeID] = try SafeByteAggregation.add(
                directCounts[nodeID, default: 0],
                count,
                nodeID: nodeID,
                context: "directCount"
            )
        }
        return updated
    }

    /// Marks a directory as complete and returns its final attributed total.
    ///
    /// When `parentID` is provided the total is folded into the parent's
    /// completed-child bucket. A child may complete before or after any of its
    /// siblings or before the parent's own direct files were added.
    @discardableResult
    public mutating func completeDirectory(
        _ nodeID: NodeID,
        parentID: NodeID?
    ) throws -> UInt64 {
        guard !completed.contains(nodeID) else {
            throw ByteAggregationError.duplicateCompletion(nodeID: nodeID)
        }
        if let parentID, completed.contains(parentID) {
            throw ByteAggregationError.directoryAlreadyCompleted(nodeID: parentID)
        }
        let total = try SafeByteAggregation.add(
            directAttributed[nodeID, default: 0],
            childAttributed[nodeID, default: 0],
            nodeID: nodeID,
            context: "completedDirectory"
        )
        if let parentID {
            let updated = try SafeByteAggregation.add(
                childAttributed[parentID, default: 0],
                total,
                nodeID: parentID,
                context: "childAttributed"
            )
            childAttributed[parentID] = updated
            childCounts[parentID] = try SafeByteAggregation.add(
                childCounts[parentID, default: 0],
                1,
                nodeID: parentID,
                context: "childCount"
            )
        }
        completed.insert(nodeID)
        return total
    }

    /// Whether a directory has already been completed.
    public func isCompleted(_ nodeID: NodeID) -> Bool {
        completed.contains(nodeID)
    }

    /// Current best-known total for a node: direct files plus completed
    /// children. Incomplete children are simply not present yet.
    ///
    /// Throws `ByteAggregationError.overflow` instead of silently clamping when
    /// the two buckets cannot be represented together.
    public func attributedBytes(of nodeID: NodeID) throws -> UInt64 {
        try SafeByteAggregation.add(
            directAttributed[nodeID, default: 0],
            childAttributed[nodeID, default: 0],
            nodeID: nodeID,
            context: "attributedBytes"
        )
    }

    public func directBytes(of nodeID: NodeID) -> UInt64 {
        directAttributed[nodeID, default: 0]
    }

    public func completedChildBytes(of nodeID: NodeID) -> UInt64 {
        childAttributed[nodeID, default: 0]
    }

    /// Direct file contributions recorded for a node.
    public func directFileCount(of nodeID: NodeID) -> UInt64 {
        directCounts[nodeID, default: 0]
    }

    /// Completed child directories recorded for a node.
    public func completedChildCount(of nodeID: NodeID) -> UInt64 {
        childCounts[nodeID, default: 0]
    }

    /// All nodes that currently have any recorded contribution.
    public var trackedNodeIDs: Set<NodeID> {
        Set(directAttributed.keys).union(childAttributed.keys)
    }
}
