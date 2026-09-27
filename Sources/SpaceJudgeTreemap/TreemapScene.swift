import Foundation
import SpaceJudgeDomain

/// Overview or detail rendering. Overview keeps larger thresholds and a
/// shallower expansion depth; detail trades comfort for more information.
public enum TreemapDetailMode: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case overview
    case detail

    /// Minimum theoretical tile area in points.
    public var minimumTileArea: Double {
        switch self {
        case .overview: return 64
        case .detail: return 24
        }
    }

    /// Maximum tile depth: the focus's direct children are depth 1.
    public var maximumDepth: Int {
        switch self {
        case .overview: return 2
        case .detail: return 3
        }
    }
}

/// All inputs a layout result must be validated against before it can be
/// applied. A late result whose key differs from the current one is discarded.
public struct TreemapLayoutKey: Sendable, Equatable, Hashable, Codable {
    /// Monotonic root/scan generation owned by the app model.
    public let scanGeneration: Int
    public let scanID: ScanID
    public let focusNodeID: NodeID
    /// Best-known scene revision this layout was computed from.
    public let sceneRevision: Revision
    /// Monotonic expansion-set version.
    public let expansionVersion: Int
    public let detailMode: TreemapDetailMode
    public let width: Double
    public let height: Double
    public let backingScale: Double

    public init(
        scanGeneration: Int,
        scanID: ScanID,
        focusNodeID: NodeID,
        sceneRevision: Revision,
        expansionVersion: Int,
        detailMode: TreemapDetailMode,
        width: Double,
        height: Double,
        backingScale: Double
    ) {
        self.scanGeneration = scanGeneration
        self.scanID = scanID
        self.focusNodeID = focusNodeID
        self.sceneRevision = sceneRevision
        self.expansionVersion = expansionVersion
        self.detailMode = detailMode
        self.width = width
        self.height = height
        self.backingScale = backingScale
    }

    /// Same layout identity for a new pixel size; used during live resize to
    /// discard only genuinely unrelated work.
    public func replacingSize(width: Double, height: Double, backingScale: Double) -> TreemapLayoutKey {
        TreemapLayoutKey(
            scanGeneration: scanGeneration,
            scanID: scanID,
            focusNodeID: focusNodeID,
            sceneRevision: sceneRevision,
            expansionVersion: expansionVersion,
            detailMode: detailMode,
            width: width,
            height: height,
            backingScale: backingScale
        )
    }
}

/// One directory as it appears in the immutable scene hierarchy.
public struct TreemapHierarchyNode: Sendable, Equatable, Hashable, Codable {
    public let nodeID: NodeID
    public let name: String
    public let kind: NodeKind
    public let effectiveBytes: UInt64
    public let isExpanded: Bool
    /// Present only when the node is a directory, is expanded, and its page has
    /// already been loaded.
    public let children: TreemapHierarchyPage?

    public init(
        nodeID: NodeID,
        name: String,
        kind: NodeKind,
        effectiveBytes: UInt64,
        isExpanded: Bool = false,
        children: TreemapHierarchyPage? = nil
    ) {
        self.nodeID = nodeID
        self.name = name
        self.kind = kind
        self.effectiveBytes = effectiveBytes
        self.isExpanded = isExpanded
        self.children = children
    }
}

/// A sibling group. `omittedCount` is the number of direct children that did
/// not fit the bounded query; `omittedWeight` is their derived weight when the
/// parent aggregate makes it knowable, and `nil` when it is genuinely unknown.
public struct TreemapHierarchyPage: Sendable, Equatable, Hashable, Codable {
    public let parentID: NodeID
    public let children: [TreemapHierarchyNode]
    public let omittedCount: UInt64
    public let omittedWeight: UInt64?
    public let totalDirectChildCount: UInt64

    public init(
        parentID: NodeID,
        children: [TreemapHierarchyNode],
        omittedCount: UInt64 = 0,
        omittedWeight: UInt64? = nil,
        totalDirectChildCount: UInt64? = nil
    ) {
        self.parentID = parentID
        self.children = children
        self.omittedCount = omittedCount
        self.omittedWeight = omittedWeight
        self.totalDirectChildCount = totalDirectChildCount ?? UInt64(children.count)
    }
}

/// Focus node plus its (possibly expanded) hierarchy.
public struct TreemapHierarchy: Sendable, Equatable, Hashable, Codable {
    public let focus: TreemapHierarchyNode

    public init(focus: TreemapHierarchyNode) {
        self.focus = focus
    }
}

/// One drawable tile in a render snapshot.
public struct TreemapRenderTile: Sendable, Equatable, Hashable, Codable {
    public enum Identity: Sendable, Equatable, Hashable, Codable {
        case node(NodeID)
        case other(parent: NodeID)

        /// The real node identifier, or `nil` for a synthetic "other" tile.
        public var nodeID: NodeID? {
            if case .node(let id) = self { return id }
            return nil
        }

        public var parentID: NodeID {
            switch self {
            case .node(let id):
                // A real tile's group parent is known by the caller; this is
                // only a fallback for standalone use.
                return id
            case .other(let parent):
                return parent
            }
        }
    }

    public let identity: Identity
    public let parentID: NodeID
    public let rect: TreemapRect
    /// Area available to expanded children, or `nil` for files and collapsed
    /// directories.
    public let contentRect: TreemapRect?
    public let depth: Int
    public let paletteIndex: Int
    public let displayName: String
    public let effectiveBytes: UInt64
    public let collapsedCount: UInt64
    public let kind: NodeKind?
    public let isExpanded: Bool

    public init(
        identity: Identity,
        parentID: NodeID,
        rect: TreemapRect,
        contentRect: TreemapRect? = nil,
        depth: Int,
        paletteIndex: Int,
        displayName: String,
        effectiveBytes: UInt64,
        collapsedCount: UInt64 = 0,
        kind: NodeKind?,
        isExpanded: Bool = false
    ) {
        self.identity = identity
        self.parentID = parentID
        self.rect = rect
        self.contentRect = contentRect
        self.depth = depth
        self.paletteIndex = paletteIndex
        self.displayName = displayName
        self.effectiveBytes = effectiveBytes
        self.collapsedCount = collapsedCount
        self.kind = kind
        self.isExpanded = isExpanded
    }

    public var isOther: Bool {
        if case .other = identity { return true }
        return false
    }

    /// Half-open containment, so shared edges belong to exactly one sibling.
    public func contains(_ point: TreemapPoint) -> Bool {
        point.x >= rect.minX && point.x < rect.maxX
            && point.y >= rect.minY && point.y < rect.maxY
    }
}

/// Immutable output of the hierarchy composer, ready for the renderer and the
/// hit index. It carries no AppKit, SQLite or path data.
public struct TreemapRenderSnapshot: Sendable, Equatable {
    public let key: TreemapLayoutKey
    public let bounds: TreemapRect
    public let tiles: [TreemapRenderTile]
    public let totalWeight: UInt64
    public let weightSumOverflowed: Bool
    /// Scene-wide count of children omitted by the query limit whose weight
    /// could not be derived. Includes the focus page and every expanded page,
    /// so the UI can say some items are still being counted without drawing
    /// invented area.
    public let hiddenOmittedCount: UInt64
    /// `true` when the global drawable budget forced a higher collapse
    /// threshold than the mode default.
    public let budgetReduced: Bool

    public init(
        key: TreemapLayoutKey,
        bounds: TreemapRect,
        tiles: [TreemapRenderTile],
        totalWeight: UInt64,
        weightSumOverflowed: Bool,
        hiddenOmittedCount: UInt64 = 0,
        budgetReduced: Bool = false
    ) {
        self.key = key
        self.bounds = bounds
        self.tiles = tiles
        self.totalWeight = totalWeight
        self.weightSumOverflowed = weightSumOverflowed
        self.hiddenOmittedCount = hiddenOmittedCount
        self.budgetReduced = budgetReduced
    }
}
