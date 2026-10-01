import Foundation
import SpaceJudgeDomain

/// Serial directory aggregation used by the scan coordinator.
///
/// Direct contributions are recorded against the owning directory. When a
/// child directory finishes, its final totals are folded into the parent's
/// "completed child" bucket, which makes the result independent of completion
/// order and keeps the algorithm O(nodes) instead of O(depth x nodes).
struct DirectoryAggregateBuilder {
    struct Totals: Sendable, Equatable {
        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        var attributed: UInt64 = 0
        var fileCount: UInt64 = 0
        var directoryCount: UInt64 = 0
        var inaccessible: UInt64 = 0

        static func + (lhs: Totals, rhs: Totals) throws -> Totals {
            Totals(
                logical: try add(lhs.logical, rhs.logical),
                allocated: try add(lhs.allocated, rhs.allocated),
                attributed: try add(lhs.attributed, rhs.attributed),
                fileCount: try add(lhs.fileCount, rhs.fileCount),
                directoryCount: try add(lhs.directoryCount, rhs.directoryCount),
                inaccessible: try add(lhs.inaccessible, rhs.inaccessible)
            )
        }

        private static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else {
                throw ScanError.aggregationOverflow(nodeID: nil)
            }
            return sum
        }
    }

    private var direct: [NodeID: Totals] = [:]
    private var children: [NodeID: Totals] = [:]
    private var completed: Set<NodeID> = []
    private var parentOf: [NodeID: NodeID] = [:]

    init() {}

    /// Records that `nodeID` is a directory with the given parent.
    mutating func registerDirectory(_ nodeID: NodeID, parent: NodeID?) throws {
        if let parent {
            parentOf[nodeID] = parent
            try addDirectoryChild(to: parent)
        }
    }

    private mutating func addDirectoryChild(to parent: NodeID) throws {
        var totals = direct[parent, default: Totals()]
        let (count, overflow) = totals.directoryCount.addingReportingOverflow(1)
        guard !overflow else { throw ScanError.aggregationOverflow(nodeID: parent) }
        totals.directoryCount = count
        direct[parent] = totals
    }

    /// Adds a non-directory child to its parent's direct bucket.
    mutating func addFile(
        parent: NodeID,
        logical: UInt64?,
        allocated: UInt64?,
        attributed: UInt64
    ) throws {
        var totals = direct[parent, default: Totals()]
        totals.fileCount = try Self.addChecked(totals.fileCount, 1, nodeID: parent)
        totals.logical = try Self.addChecked(totals.logical, logical ?? 0, nodeID: parent)
        totals.allocated = try Self.addChecked(totals.allocated, allocated ?? 0, nodeID: parent)
        totals.attributed = try Self.addChecked(totals.attributed, attributed, nodeID: parent)
        direct[parent] = totals
    }

    /// Finalizes a directory and folds its totals into its parent.
    @discardableResult
    mutating func complete(
        _ nodeID: NodeID,
        isComplete: Bool,
        extraInaccessible: UInt64 = 0
    ) throws -> DirectoryAggregateRecord {
        let totals = try currentTotals(of: nodeID)
        let withExtra = Totals(
            logical: totals.logical,
            allocated: totals.allocated,
            attributed: totals.attributed,
            fileCount: totals.fileCount,
            directoryCount: totals.directoryCount,
            inaccessible: try Self.addChecked(totals.inaccessible, extraInaccessible, nodeID: nodeID)
        )

        if let parent = parentOf[nodeID], !completed.contains(parent) {
            var bucket = children[parent, default: Totals()]
            bucket.logical = try Self.addChecked(bucket.logical, withExtra.logical, nodeID: parent)
            bucket.allocated = try Self.addChecked(bucket.allocated, withExtra.allocated, nodeID: parent)
            bucket.attributed = try Self.addChecked(bucket.attributed, withExtra.attributed, nodeID: parent)
            bucket.fileCount = try Self.addChecked(bucket.fileCount, withExtra.fileCount, nodeID: parent)
            // The parent's direct bucket already counted this child as an
            // immediate subdirectory, so only the child's descendants are
            // added here.
            bucket.directoryCount = try Self.addChecked(
                bucket.directoryCount,
                withExtra.directoryCount,
                nodeID: parent
            )
            bucket.inaccessible = try Self.addChecked(bucket.inaccessible, withExtra.inaccessible, nodeID: parent)
            children[parent] = bucket
        }

        completed.insert(nodeID)

        return DirectoryAggregateRecord(
            nodeID: nodeID,
            logicalBytes: withExtra.logical,
            allocatedBytes: withExtra.allocated,
            attributedBytes: withExtra.attributed,
            descendantFileCount: withExtra.fileCount,
            descendantDirectoryCount: withExtra.directoryCount,
            inaccessibleDescendantCount: withExtra.inaccessible,
            isComplete: isComplete
        )
    }

    /// Best-known totals for a directory, complete or not.
    func currentTotals(of nodeID: NodeID) throws -> Totals {
        let directTotals = direct[nodeID, default: Totals()]
        let childTotals = children[nodeID, default: Totals()]
        return try directTotals + childTotals
    }

    func isCompleted(_ nodeID: NodeID) -> Bool {
        completed.contains(nodeID)
    }

    /// Includes live descendants, without folding them into final buckets.
    /// Iterative postorder avoids recursion/depth-per-file work. Completed
    /// children are already folded, so they must not be visited twice.
    func progressiveTotals(root: NodeID) throws -> [NodeID: Totals] {
        var liveChildren: [NodeID: [NodeID]] = [:]
        for (child, parent) in parentOf where !completed.contains(child) {
            liveChildren[parent, default: []].append(child)
        }
        var totals: [NodeID: Totals] = [:]
        var stack: [(NodeID, Bool)] = [(root, false)]
        while let (node, visited) = stack.popLast() {
            if visited {
                var value = try currentTotals(of: node)
                for child in liveChildren[node, default: []] {
                    value = try value + totals[child, default: Totals()]
                }
                totals[node] = value
            } else {
                stack.append((node, true))
                for child in liveChildren[node, default: []] {
                    stack.append((child, false))
                }
            }
        }
        return totals
    }

    /// Releases the mutable working buckets for a directory whose final
    /// aggregate has already been folded into its parent.
    ///
    /// This drops `direct`, `children` and `parentOf` for the node, so the
    /// per-directory working storage no longer grows with the number of
    /// completed directories. The lightweight `completed` set is intentionally
    /// kept as the duplicate-completion guard.
    ///
    /// The caller must capture the node's parent (for the upward walk) before
    /// calling this, and must never call it for the root: progress and the
    /// terminal summary read the root's live totals.
    mutating func retire(_ nodeID: NodeID) {
        direct.removeValue(forKey: nodeID)
        children.removeValue(forKey: nodeID)
        parentOf.removeValue(forKey: nodeID)
    }

    func parent(of nodeID: NodeID) -> NodeID? {
        parentOf[nodeID]
    }

    private static func addChecked(_ lhs: UInt64, _ rhs: UInt64, nodeID: NodeID) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw ScanError.aggregationOverflow(nodeID: nodeID)
        }
        return sum
    }
}
