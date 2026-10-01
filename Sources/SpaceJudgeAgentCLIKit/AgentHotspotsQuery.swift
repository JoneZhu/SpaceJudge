import Foundation
import SpaceJudgeDomain
import SpaceJudgeStore

/// Bounds for the read-only `hotspots` command and the `get_hotspots` MCP tool.
public enum AgentHotspotsLimits {
    /// Lowest accepted `hotspots --limit` value.
    public static let minimumLimit = 1
    /// Highest accepted `hotspots --limit` value.
    public static let maximumLimit = 50
    /// Default page/result size when `--limit` is omitted.
    public static let defaultLimit = 30
    /// Default `--min-bytes` when omitted. Zero-byte nodes are excluded, but an
    /// explicit `0` includes them.
    public static let defaultMinimumBytes: UInt64 = 1
}

/// One hotspot row: the child fact plus its depth relative to the scope.
public struct AgentHotspotItem: Sendable, Equatable {
    public let node: NodeRecord
    public let name: NameRecord
    /// Best-known subtree weight; this is the ordering truth.
    public let effectiveAttributedBytes: UInt64
    /// Direct children of the scope are depth 1.
    public let depth: Int

    public init(
        node: NodeRecord,
        name: NameRecord,
        effectiveAttributedBytes: UInt64,
        depth: Int
    ) {
        self.node = node
        self.name = name
        self.effectiveAttributedBytes = effectiveAttributedBytes
        self.depth = depth
    }
}

/// Complete outcome of one bounded best-first hotspots traversal.
public struct AgentHotspotsResult: Sendable, Equatable {
    public let scanID: ScanID
    public let scopeNodeID: NodeID
    public let status: ScanStatus
    /// `true` only for a `completed` scan; terminal partial states are `false`.
    public let snapshotComplete: Bool
    public let snapshotRevision: Revision
    public let limit: Int
    public let minimumBytes: UInt64
    /// `true` when more nodes at or above `minimumBytes` may exist beyond the
    /// returned set; `false` only when the remainder was proven below the floor.
    public let truncated: Bool
    public let items: [AgentHotspotItem]

    public init(
        scanID: ScanID,
        scopeNodeID: NodeID,
        status: ScanStatus,
        snapshotComplete: Bool,
        snapshotRevision: Revision,
        limit: Int,
        minimumBytes: UInt64,
        truncated: Bool,
        items: [AgentHotspotItem]
    ) {
        self.scanID = scanID
        self.scopeNodeID = scopeNodeID
        self.status = status
        self.snapshotComplete = snapshotComplete
        self.snapshotRevision = snapshotRevision
        self.limit = limit
        self.minimumBytes = minimumBytes
        self.truncated = truncated
        self.items = items
    }
}

/// Bounded best-first traversal that answers `hotspots` without a global sort.
///
/// It only calls the existing `childPage(of:in:limit:)` reader. The scope is
/// never returned; each expanded directory contributes at most `limit`
/// children. The omitted children of a directory cannot enter the global
/// Top-`limit` because at least `limit` larger-or-equal siblings precede them.
///
/// The traversal is intentionally generic over `SnapshotRepository` so a
/// controlled repository can exercise revision changes and terminal states.
public enum AgentHotspotsQuery {
    /// Runs one traversal. Throws path-free `AgentCLIError`s only.
    public static func run(
        repository: any SnapshotRepository,
        scanID: ScanID,
        scopeNodeID: NodeID,
        limit: Int,
        minimumBytes: UInt64
    ) async throws -> AgentHotspotsResult {
        guard let state = try await repository.scanState(scanID) else {
            throw AgentCLIError(code: .notFound)
        }
        // A live snapshot could change revision between pages; refuse instead
        // of returning a mixed-revision ranking.
        switch state.status {
        case .running, .cancelling:
            throw AgentCLIError(code: .conflict)
        case .completed, .cancelled, .failed, .interrupted:
            break
        }
        let snapshotComplete = state.status == .completed
        let initialRevision = state.lastRevision

        // `ancestors` fails when the scope node is missing or cyclic; that is
        // the only look-up we need because the node's own size is not returned.
        do {
            _ = try await repository.ancestors(of: scopeNodeID, in: scanID)
        } catch SnapshotStoreError.missingParent {
            throw AgentCLIError(code: .notFound)
        } catch SnapshotStoreError.ancestorCycle {
            throw AgentCLIError(code: .notFound)
        }

        var queue = AgentHotspotQueue()
        var items: [AgentHotspotItem] = []
        var pageTailMayBeEligible = false

        /// Reads one bounded page, enforces the revision invariant and enqueues
        /// every child at or above the byte floor.
        func loadChildren(of parent: NodeID, depth: Int) async throws {
            let page = try await repository.childPage(
                of: parent,
                in: scanID,
                limit: limit
            )
            guard page.snapshotRevision == initialRevision else {
                throw AgentCLIError(code: .conflict)
            }
            // The page is ordered by effective bytes descending. If it was
            // capped and its last row still clears the floor, unread siblings
            // could clear it too; otherwise they are provably below the floor.
            if UInt64(page.items.count) < page.totalCount,
               let last = page.items.last,
               last.effectiveAttributedBytes >= minimumBytes {
                pageTailMayBeEligible = true
            }
            for item in page.items where item.effectiveAttributedBytes >= minimumBytes {
                queue.push(
                    AgentHotspotItem(
                        node: item.node,
                        name: item.name,
                        effectiveAttributedBytes: item.effectiveAttributedBytes,
                        depth: depth
                    )
                )
            }
        }

        try await loadChildren(of: scopeNodeID, depth: 1)

        while items.count < limit, let candidate = queue.pop() {
            items.append(candidate)
            guard items.count < limit else { break }
            if candidate.node.kind.isDirectoryLike {
                try await loadChildren(of: candidate.node.id, depth: candidate.depth + 1)
            }
        }

        let truncated: Bool
        if items.count == limit {
            let queueStillEligible = queue.peak.map {
                $0.effectiveAttributedBytes >= minimumBytes
            } ?? false
            // The limit-th item was not expanded, so a directory there may still
            // own eligible descendants.
            let lastIsUnexpandedDirectory = items.last?.node.kind.isDirectoryLike ?? false
            truncated = queueStillEligible || pageTailMayBeEligible || lastIsUnexpandedDirectory
        } else {
            // Ended because the queue drained or the frontier fell below the
            // floor; every remaining node is provably below `minimumBytes`.
            truncated = false
        }

        return AgentHotspotsResult(
            scanID: scanID,
            scopeNodeID: scopeNodeID,
            status: state.status,
            snapshotComplete: snapshotComplete,
            snapshotRevision: initialRevision,
            limit: limit,
            minimumBytes: minimumBytes,
            truncated: truncated,
            items: items
        )
    }
}

/// Max-heap of hotspot candidates ordered by effective bytes descending,
/// relative depth ascending, then node ID ascending.
struct AgentHotspotQueue {
    private var storage: [AgentHotspotItem] = []

    var isEmpty: Bool { storage.isEmpty }

    /// Highest-priority item without removing it.
    var peak: AgentHotspotItem? { storage.first }

    mutating func push(_ item: AgentHotspotItem) {
        storage.append(item)
        var index = storage.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard Self.hasHigherPriority(storage[index], storage[parent]) else { break }
            storage.swapAt(index, parent)
            index = parent
        }
    }

    mutating func pop() -> AgentHotspotItem? {
        guard let first = storage.first else { return nil }
        let last = storage.removeLast()
        guard !storage.isEmpty else { return first }
        storage[0] = last
        var index = 0
        while true {
            let left = 2 * index + 1
            let right = left + 1
            var best = index
            if left < storage.count, Self.hasHigherPriority(storage[left], storage[best]) {
                best = left
            }
            if right < storage.count, Self.hasHigherPriority(storage[right], storage[best]) {
                best = right
            }
            guard best != index else { break }
            storage.swapAt(index, best)
            index = best
        }
        return first
    }

    private static func hasHigherPriority(
        _ lhs: AgentHotspotItem,
        _ rhs: AgentHotspotItem
    ) -> Bool {
        if lhs.effectiveAttributedBytes != rhs.effectiveAttributedBytes {
            return lhs.effectiveAttributedBytes > rhs.effectiveAttributedBytes
        }
        if lhs.depth != rhs.depth {
            return lhs.depth < rhs.depth
        }
        return lhs.node.id.rawValue < rhs.node.id.rawValue
    }
}
