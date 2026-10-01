import Foundation
import SpaceJudgeDomain
import SpaceJudgeTreemap

/// One breadcrumb entry: scan-local name plus enough kind information to
/// render the path without ever storing an absolute path.
public struct SnapshotPathItem: Sendable, Equatable, Hashable, Codable {
    public let nodeID: NodeID
    public let name: String
    public let kind: NodeKind

    public init(nodeID: NodeID, name: String, kind: NodeKind) {
        self.nodeID = nodeID
        self.name = name
        self.kind = kind
    }
}

/// Selection of a synthetic "other" tile.
///
/// Deliberately carries no `NodeID`: the tile represents a group, so it can
/// never be used for Finder, entering or a fake node lookup.
public struct TreemapOtherSelection: Sendable, Equatable, Hashable {
    public let parentID: NodeID
    public let collapsedCount: UInt64
    public let effectiveBytes: UInt64

    public init(parentID: NodeID, collapsedCount: UInt64, effectiveBytes: UInt64) {
        self.parentID = parentID
        self.collapsedCount = collapsedCount
        self.effectiveBytes = effectiveBytes
    }
}

/// One real node inside an immutable treemap scene.
public struct TreemapSceneItem: Sendable, Equatable, Hashable, Codable {
    public let nodeID: NodeID
    public let name: String
    public let kind: NodeKind
    public let flags: NodeFlags
    public let effectiveBytes: UInt64
    public let modifiedAt: Date?
    public let logicalBytes: UInt64?
    public let allocatedBytes: UInt64?

    public init(
        nodeID: NodeID,
        name: String,
        kind: NodeKind,
        flags: NodeFlags,
        effectiveBytes: UInt64,
        modifiedAt: Date?,
        logicalBytes: UInt64?,
        allocatedBytes: UInt64?
    ) {
        self.nodeID = nodeID
        self.name = name
        self.kind = kind
        self.flags = flags
        self.effectiveBytes = effectiveBytes
        self.modifiedAt = modifiedAt
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
    }

    public var isDirectoryLike: Bool { kind.isDirectoryLike }
}

/// One bounded sibling page in a scene, with derived "other" metadata.
public struct TreemapScenePage: Sendable, Equatable, Hashable, Codable {
    public let parentID: NodeID
    public let items: [TreemapSceneItem]
    public let totalCount: UInt64
    public let snapshotRevision: Revision
    public let omittedCount: UInt64
    /// Weight of the omitted children when the parent aggregate makes it
    /// knowable, `nil` when it is genuinely unknown.
    public let omittedWeight: UInt64?
    public let aggregate: DirectoryAggregateRecord?
    /// `true` when the parent aggregate was smaller than the shown sum, which
    /// is recorded instead of underflowing.
    public let aggregateInconsistent: Bool

    public init(
        parentID: NodeID,
        items: [TreemapSceneItem],
        totalCount: UInt64,
        snapshotRevision: Revision,
        omittedCount: UInt64,
        omittedWeight: UInt64?,
        aggregate: DirectoryAggregateRecord?,
        aggregateInconsistent: Bool = false
    ) {
        self.parentID = parentID
        self.items = items
        self.totalCount = totalCount
        self.snapshotRevision = snapshotRevision
        self.omittedCount = omittedCount
        self.omittedWeight = omittedWeight
        self.aggregate = aggregate
        self.aggregateInconsistent = aggregateInconsistent
    }

    public var aggregateIsComplete: Bool? { aggregate?.isComplete }

    /// Builds a scene page from a bounded store page, deriving the omitted
    /// weight from the same-snapshot parent aggregate.
    public static func make(
        from page: SnapshotChildPage,
        parentID: NodeID
    ) -> TreemapScenePage {
        var items: [TreemapSceneItem] = []
        items.reserveCapacity(page.items.count)
        var sum: UInt64 = 0
        var overflow = false
        for item in page.items {
            let (next, didOverflow) = sum.addingReportingOverflow(item.effectiveAttributedBytes)
            overflow = overflow || didOverflow
            sum = didOverflow ? UInt64.max : next
            items.append(
                TreemapSceneItem(
                    nodeID: item.node.id,
                    name: displayName(item.name),
                    kind: item.node.kind,
                    flags: item.node.flags,
                    effectiveBytes: item.effectiveAttributedBytes,
                    modifiedAt: item.node.modifiedAt,
                    logicalBytes: item.node.logicalBytes,
                    allocatedBytes: item.node.allocatedBytes
                )
            )
        }

        let shownCount = UInt64(items.count)
        let omittedCount = page.totalCount > shownCount ? page.totalCount - shownCount : 0
        var omittedWeight: UInt64?
        var inconsistent = overflow
        if omittedCount > 0, let aggregate = page.parentAggregate {
            if !overflow, aggregate.attributedBytes >= sum {
                omittedWeight = aggregate.attributedBytes - sum
            } else {
                inconsistent = true
            }
        }

        return TreemapScenePage(
            parentID: parentID,
            items: items,
            totalCount: page.totalCount,
            snapshotRevision: page.snapshotRevision,
            omittedCount: omittedCount,
            omittedWeight: omittedWeight,
            aggregate: page.parentAggregate,
            aggregateInconsistent: inconsistent
        )
    }

    private static func displayName(_ record: NameRecord) -> String {
        if let decoded = record.decodedString { return decoded }
        return String(decoding: record.utf8, as: UTF8.self)
    }
}

/// Immutable, `Sendable` scene assembled from bounded snapshot pages.
///
/// This is the only treemap input the UI layer sees. It carries no absolute
/// paths, security-scoped URLs, SQLite handles or callbacks.
public struct TreemapSceneData: Sendable, Equatable {
    public let scanID: ScanID
    public let scanGeneration: Int
    public let revision: Revision
    public let focusNodeID: NodeID
    public let focusName: String
    public let focusKind: NodeKind
    public let focusAggregate: DirectoryAggregateRecord?
    public let focusPage: TreemapScenePage
    public let expandedPages: [NodeID: TreemapScenePage]
    public let expansionOrder: [NodeID]
    public let expansionVersion: Int
    public let detailMode: TreemapDetailMode
    public let isTerminal: Bool
    public let rootDisplayName: String

    public init(
        scanID: ScanID,
        scanGeneration: Int,
        revision: Revision,
        focusNodeID: NodeID,
        focusName: String,
        focusKind: NodeKind,
        focusAggregate: DirectoryAggregateRecord?,
        focusPage: TreemapScenePage,
        expandedPages: [NodeID: TreemapScenePage],
        expansionOrder: [NodeID],
        expansionVersion: Int,
        detailMode: TreemapDetailMode,
        isTerminal: Bool,
        rootDisplayName: String
    ) {
        self.scanID = scanID
        self.scanGeneration = scanGeneration
        self.revision = revision
        self.focusNodeID = focusNodeID
        self.focusName = focusName
        self.focusKind = focusKind
        self.focusAggregate = focusAggregate
        self.focusPage = focusPage
        self.expandedPages = expandedPages
        self.expansionOrder = expansionOrder
        self.expansionVersion = expansionVersion
        self.detailMode = detailMode
        self.isTerminal = isTerminal
        self.rootDisplayName = rootDisplayName
    }

    /// All items currently present across the focus and expanded pages.
    public func item(_ nodeID: NodeID) -> TreemapSceneItem? {
        if let match = focusPage.items.first(where: { $0.nodeID == nodeID }) {
            return match
        }
        for page in expandedPages.values {
            if let match = page.items.first(where: { $0.nodeID == nodeID }) {
                return match
            }
        }
        return nil
    }

    /// Page whose parent is `parentID`.
    public func page(for parentID: NodeID) -> TreemapScenePage? {
        if parentID == focusNodeID { return focusPage }
        return expandedPages[parentID]
    }

    /// The selected directory's own aggregate when its page is loaded in this
    /// scene, else `nil`. A loaded page carries the directory's
    /// `DirectoryAggregateRecord` in `aggregate`, so a scene update can refresh
    /// the selection without an extra store read.
    public func knownAggregate(for nodeID: NodeID) -> DirectoryAggregateRecord? {
        page(for: nodeID)?.aggregate
    }

    /// The page that directly contains `nodeID` as a child, or `nil` when it is
    /// not in this scene. Its `aggregate` is the containing parent's aggregate,
    /// so a complete parent proves every descendant's size is final.
    public func containingPage(for nodeID: NodeID) -> TreemapScenePage? {
        if focusPage.items.contains(where: { $0.nodeID == nodeID }) {
            return focusPage
        }
        for page in expandedPages.values where page.items.contains(where: { $0.nodeID == nodeID }) {
            return page
        }
        return nil
    }

    /// Scene-wide count of omitted children whose weight cannot be derived.
    /// These are never turned into area; the UI surfaces them as a compact
    /// "still counting" message. Uses saturating addition.
    public var hiddenOmittedCount: UInt64 {
        var total: UInt64 = 0
        for page in [focusPage] + Array(expandedPages.values) {
            guard page.omittedWeight == nil, page.omittedCount > 0 else { continue }
            let (sum, overflow) = total.addingReportingOverflow(page.omittedCount)
            total = overflow ? UInt64.max : sum
        }
        return total
    }

    /// Returns a copy stamped with a new detail mode. Detail mode never changes
    /// which pages are queried, so a query result is mode-independent and can
    /// be re-stamped at apply time.
    public func withDetailMode(_ mode: TreemapDetailMode) -> TreemapSceneData {
        guard mode != detailMode else { return self }
        return TreemapSceneData(
            scanID: scanID,
            scanGeneration: scanGeneration,
            revision: revision,
            focusNodeID: focusNodeID,
            focusName: focusName,
            focusKind: focusKind,
            focusAggregate: focusAggregate,
            focusPage: focusPage,
            expandedPages: expandedPages,
            expansionOrder: expansionOrder,
            expansionVersion: expansionVersion,
            detailMode: mode,
            isTerminal: isTerminal,
            rootDisplayName: rootDisplayName
        )
    }

    /// Scan-local display names from the focus down to `nodeID`, excluding the
    /// focus's own name. Returns `nil` when the node is not reachable from the
    /// currently loaded pages. Never contains an absolute path.
    public func displayPath(from nodeID: NodeID) -> [String]? {
        if nodeID == focusNodeID { return [] }
        func search(page: TreemapScenePage, trail: [String]) -> [String]? {
            for item in page.items {
                let next = trail + [item.name]
                if item.nodeID == nodeID { return next }
                if let childPage = expandedPages[item.nodeID],
                   let found = search(page: childPage, trail: next) {
                    return found
                }
            }
            return nil
        }
        return search(page: focusPage, trail: [])
    }

    /// Converts the scene into the pure composer's hierarchy.
    public func hierarchy() -> TreemapHierarchy {
        func makeNode(_ item: TreemapSceneItem) -> TreemapHierarchyNode {
            let childPage = expandedPages[item.nodeID]
            return TreemapHierarchyNode(
                nodeID: item.nodeID,
                name: item.name,
                kind: item.kind,
                effectiveBytes: item.effectiveBytes,
                isExpanded: expandedPages[item.nodeID] != nil,
                children: childPage.map(makePage)
            )
        }

        func makePage(_ page: TreemapScenePage) -> TreemapHierarchyPage {
            TreemapHierarchyPage(
                parentID: page.parentID,
                children: page.items.map(makeNode),
                omittedCount: page.omittedCount,
                omittedWeight: page.omittedWeight,
                totalDirectChildCount: page.totalCount
            )
        }

        let focusWeight: UInt64
        if let aggregate = focusAggregate {
            focusWeight = aggregate.attributedBytes
        } else {
            // Saturating sum so an overflowing scene can never wrap to a tiny
            // focus weight, consistent with all other weight semantics.
            var sum: UInt64 = 0
            var overflowed = false
            for item in focusPage.items {
                let (next, overflow) = sum.addingReportingOverflow(item.effectiveBytes)
                overflowed = overflowed || overflow
                sum = overflow ? UInt64.max : next
            }
            focusWeight = sum
        }
        let focusNode = TreemapHierarchyNode(
            nodeID: focusNodeID,
            name: focusName,
            kind: focusKind,
            effectiveBytes: focusWeight,
            isExpanded: true,
            children: makePage(focusPage)
        )
        return TreemapHierarchy(focus: focusNode)
    }
}
