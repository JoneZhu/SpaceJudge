import Foundation
import SpaceJudgeDomain

/// Bounded, read-only snapshot queries used by the UI.
///
/// The loader never opens the database itself and never runs an unbounded
/// `children(of:)` query. It is built on top of a read-only repository that is
/// separate from the single writable connection.
public struct SnapshotLoader: Sendable {
    private let repository: any SnapshotRepository

    public init(repository: any SnapshotRepository) {
        self.repository = repository
    }

    /// Loads at most `limit` direct children of `nodeID` plus the direct-child
    /// total. Throws `SnapshotQueryError.invalidChildPageLimit` for limits
    /// outside `1...500`.
    public func loadChildren(
        scanID: ScanID,
        nodeID: NodeID,
        limit: Int
    ) async throws -> SnapshotChildPage {
        try await repository.childPage(of: nodeID, in: scanID, limit: limit)
    }

    /// Whether the persisted issue summary contains permission evidence.
    /// This is derived from real `EACCES`/`EPERM` facts, never from a probe.
    public func isPermissionLimited(scanID: ScanID) async throws -> Bool {
        let issues = try await repository.issueSummary(scanID)
        return issues.contains { $0.category == .permissionDenied }
    }

    /// Persisted lifecycle state for one scan.
    public func state(scanID: ScanID) async throws -> ScanSnapshotState? {
        try await repository.scanState(scanID)
    }

    /// Root-to-`nodeID` ancestor chain (root first, target last).
    public func ancestors(scanID: ScanID, nodeID: NodeID) async throws -> [NodeRecord] {
        try await repository.ancestors(of: nodeID, in: scanID)
    }

    /// Raw scan-local name bytes.
    public func name(id: NameID, scanID: ScanID) async throws -> NameRecord? {
        try await repository.name(id: id, in: scanID)
    }

    /// Best-known aggregate for one directory.
    public func aggregate(
        scanID: ScanID,
        nodeID: NodeID
    ) async throws -> DirectoryAggregateRecord? {
        try await repository.aggregate(of: nodeID, in: scanID)
    }
}
