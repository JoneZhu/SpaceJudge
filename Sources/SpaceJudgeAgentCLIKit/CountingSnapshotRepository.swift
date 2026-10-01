import Foundation
import SpaceJudgeDomain

/// Read-only progress counter wrapping a real snapshot repository.
///
/// The CLI needs an accurate `persistedNodes` count for its `progress` events,
/// but `PersistingScanRunner` emits committed updates without the batch itself.
/// This transparent decorator counts nodes only after the wrapped `write`
/// succeeds, so a failed transaction never advances the number.
public actor CountingSnapshotRepository: SnapshotRepository {
    private let inner: any SnapshotRepository
    private var storedNodeCount: UInt64 = 0

    public init(wrapping inner: any SnapshotRepository) {
        self.inner = inner
    }

    /// Nodes successfully persisted so far.
    public var persistedNodeCount: UInt64 {
        storedNodeCount
    }

    // MARK: Writes

    public func begin(_ metadata: ScanMetadata) async throws {
        try await inner.begin(metadata)
    }

    public func write(_ batch: NodeBatch) async throws {
        try await inner.write(batch)
        let (value, overflow) = storedNodeCount.addingReportingOverflow(
            UInt64(batch.nodes.count)
        )
        storedNodeCount = overflow ? UInt64.max : value
    }

    public func record(_ issue: ScanIssue) async throws {
        try await inner.record(issue)
    }

    public func finish(_ summary: ScanSummary) async throws {
        try await inner.finish(summary)
    }

    public func fail(scanID: ScanID) async throws {
        try await inner.fail(scanID: scanID)
    }

    // MARK: Reads

    public func child(named bytes: Data, of parent: NodeID, in scanID: ScanID) async throws -> NodeRecord? {
        try await inner.child(named: bytes, of: parent, in: scanID)
    }

    public func retainForRefresh(_ scanID: ScanID?) async {
        await inner.retainForRefresh(scanID)
    }

    public func children(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] {
        try await inner.children(of: nodeID, in: scanID)
    }

    public func childPage(
        of nodeID: NodeID,
        in scanID: ScanID,
        limit: Int
    ) async throws -> SnapshotChildPage {
        try await inner.childPage(of: nodeID, in: scanID, limit: limit)
    }

    public func name(id: NameID, in scanID: ScanID) async throws -> NameRecord? {
        try await inner.name(id: id, in: scanID)
    }

    public func aggregate(
        of nodeID: NodeID,
        in scanID: ScanID
    ) async throws -> DirectoryAggregateRecord? {
        try await inner.aggregate(of: nodeID, in: scanID)
    }

    public func ancestors(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] {
        try await inner.ancestors(of: nodeID, in: scanID)
    }

    public func scanState(_ scanID: ScanID) async throws -> ScanSnapshotState? {
        try await inner.scanState(scanID)
    }

    public func scanSummary(_ scanID: ScanID) async throws -> ScanSnapshotSummary? {
        try await inner.scanSummary(scanID)
    }

    public func issueSummary(_ scanID: ScanID) async throws -> [IssueAggregateSummary] {
        try await inner.issueSummary(scanID)
    }

    public func statistics(_ scanID: ScanID) async throws -> SnapshotStatistics {
        try await inner.statistics(scanID)
    }
}
