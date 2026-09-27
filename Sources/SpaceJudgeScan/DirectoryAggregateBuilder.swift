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
