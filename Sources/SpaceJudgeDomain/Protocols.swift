import Foundation

/// Produces a bounded, cancellable stream of scan facts for one request.
///
/// Implementations own their lifecycle and must emit exactly one terminal
/// event (`completed` or `cancelled`). Per-file UI callbacks are intentionally
/// not part of this contract; facts travel in `NodeBatch` values.
public protocol ScanEngine: Sendable {
    func events(for request: ScanRequest) -> AsyncThrowingStream<ScanEvent, any Error>
    func cancel(scanID: ScanID) async
}

/// Persists scan facts and answers the small query set the UI needs.
///
/// The repository never exposes SQLite, file descriptors, or UI types through
/// this protocol. Every write call is awaited by the caller, so a slow store
/// applies backpressure to the scan stream.
public protocol SnapshotRepository: Sendable {
    /// Opens a scan header in the `running` state. Re-begin with the same
    /// `ScanID` must fail.
    func begin(_ metadata: ScanMetadata) async throws
    /// Applies one append-only batch atomically. Revisions must be contiguous.
    func write(_ batch: NodeBatch) async throws
    /// Appends one recoverable issue event.
    func record(_ issue: ScanIssue) async throws
    /// Moves a `running` scan to `completed` or `cancelled`.
    func finish(_ summary: ScanSummary) async throws
    /// Moves a `running` scan to `failed`.
    func fail(scanID: ScanID) async throws
    /// Direct children ordered by attributed bytes descending, then `NodeID`.
    func children(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord]
    /// Bounded direct-children page ordered by
    /// `SnapshotChildItem.effectiveAttributedBytes` descending, then `NodeID`
    /// ascending. `effectiveAttributedBytes` is the child's directory aggregate
    /// when present, otherwise the immutable node's own attributed bytes. The
    /// page joins each child's scan-local name. `limit` must be in `1...500`;
    /// anything else throws `SnapshotQueryError`. Memory is bounded to the
    /// requested page, but effective ordering may inspect every direct child.
    func childPage(
        of nodeID: NodeID,
        in scanID: ScanID,
        limit: Int
    ) async throws -> SnapshotChildPage
    /// Raw name bytes for a scan-local `NameID`.
    func name(id: NameID, in scanID: ScanID) async throws -> NameRecord?
    /// Final or best-known totals for one directory.
    func aggregate(of nodeID: NodeID, in scanID: ScanID) async throws -> DirectoryAggregateRecord?
    /// Root-to-current ancestor chain. Detects missing parents and cycles.
    func ancestors(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord]
    /// Persisted lifecycle state for one scan.
    func scanState(_ scanID: ScanID) async throws -> ScanSnapshotState?
    /// Persisted scan header with policy facts and counters.
    func scanSummary(_ scanID: ScanID) async throws -> ScanSnapshotSummary?
    /// Aggregated issues for one scan.
    func issueSummary(_ scanID: ScanID) async throws -> [IssueAggregateSummary]
    /// Persisted row counts for one scan.
    func statistics(_ scanID: ScanID) async throws -> SnapshotStatistics
}
