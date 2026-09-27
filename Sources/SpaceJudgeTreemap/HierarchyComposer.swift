import Foundation
import SpaceJudgeDomain

/// Deterministic, pure composer that turns an immutable `TreemapHierarchy`
/// into a flat list of drawable tiles.
///
/// The composer is the only place that knows about padding, headers, palette
/// assignment, per-parent "other" identity and the global drawable budget. It
/// never touches AppKit, SQLite or the file system, so it can run on a
/// detached task and be unit tested with plain values.
public enum TreemapHierarchyComposer {
    /// Hard upper bound on the number of drawable tiles in one scene.
    public static let maximumDrawableTiles = 2_000
    /// Number of top-level palette groups.
    public static let paletteCount = 6
    /// Gap between top-level siblings, in points.
    public static let topLevelGap = 4.0
    /// Gap between nested siblings, in points.
    public static let nestedGap = 2.0
    /// Maximum header height reserved above an expanded directory's content.
    public static let maximumHeaderHeight = 16.0

    /// Builds a render snapshot for `hierarchy` at `bounds`.
    ///
    /// If the first pass exceeds `maximumDrawableTiles`, the collapse threshold
    /// is raised and the whole hierarchy is recomputed from scratch, so the
    /// smallest theoretical areas collapse first and no weight is ever dropped.
    public static func snapshot(
        _ hierarchy: TreemapHierarchy,
        key: TreemapLayoutKey,
        bounds: TreemapRect
    ) -> TreemapRenderSnapshot {
        let normalized = TreemapRect(
            x: bounds.x,
            y: bounds.y,
            width: max(0, bounds.width),
            height: max(0, bounds.height)
        )

        var threshold = key.detailMode.minimumTileArea
        var budgetReduced = false
        var result = compose(
            hierarchy,
            key: key,
            bounds: normalized,
            threshold: threshold
        )

        var attempts = 0
        while result.tiles.count > maximumDrawableTiles, attempts < 40 {
            threshold = nextThreshold(threshold)
            budgetReduced = true
            result = compose(
                hierarchy,
                key: key,
                bounds: normalized,
                threshold: threshold
            )
            attempts += 1
        }

        return TreemapRenderSnapshot(
            key: key,
            bounds: normalized,
            tiles: result.tiles,
            totalWeight: result.totalWeight,
            weightSumOverflowed: result.overflowed,
            hiddenOmittedCount: result.hiddenOmittedCount,
            budgetReduced: budgetReduced
        )
    }

    // MARK: - Composition

    private struct PageResult {
        let tiles: [TreemapRenderTile]
        let totalWeight: UInt64
        let overflowed: Bool
        let hiddenOmittedCount: UInt64
    }

    private static func compose(
        _ hierarchy: TreemapHierarchy,
        key: TreemapLayoutKey,
        bounds: TreemapRect,
        threshold: Double
    ) -> PageResult {
        let focus = hierarchy.focus
        guard let page = focus.children,
              !page.children.isEmpty || page.omittedCount > 0 else {
            return PageResult(tiles: [], totalWeight: 0, overflowed: false, hiddenOmittedCount: 0)
        }

        var tiles: [TreemapRenderTile] = []
        var overflowed = false
        var hiddenOmitted: UInt64 = 0

        let entries = drawableEntries(
            page: page,
            in: bounds,
            threshold: threshold,
            overflowed: &overflowed,
            hiddenOmitted: &hiddenOmitted
        )
        for (rank, entry) in entries.enumerated() {
            append(
                entry: entry,
                paletteIndex: rank % paletteCount,
                depth: 1,
                parentID: focus.nodeID,
                maximumDepth: key.detailMode.maximumDepth,
                threshold: threshold,
                tiles: &tiles,
                overflowed: &overflowed,
                hiddenOmitted: &hiddenOmitted
            )
        }

        let (totalWeight, totalOverflowed) = TreemapWeight.sumSaturating(entries.map(\.weight))
        return PageResult(
            tiles: tiles,
            totalWeight: totalWeight,
            overflowed: overflowed || totalOverflowed,
            hiddenOmittedCount: hiddenOmitted
        )
    }

    /// One sibling group's drawable entries, ordered deterministically by
    /// weight, then stable key, then identity.
    private struct DrawableEntry {
        let identity: TreemapRenderTile.Identity
        let tile: TreemapTile
        let node: TreemapHierarchyNode?
        let weight: UInt64
        let stableKey: String
        let collapsedCount: UInt64
        let isExpanded: Bool
        let children: TreemapHierarchyPage?
    }

    private static func drawableEntries(
        page: TreemapHierarchyPage,
        in bounds: TreemapRect,
        threshold: Double,
        overflowed: inout Bool,
        hiddenOmitted: inout UInt64
    ) -> [DrawableEntry] {
        let byID = Dictionary(
            page.children.map { ($0.nodeID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let items = page.children.map { node in
            TreemapItem(
                id: node.nodeID,
                weight: node.effectiveBytes,
                stableKey: stableKey(for: node)
            )
        }

        if page.omittedWeight == nil, page.omittedCount > 0 {
            let (sum, overflow) = hiddenOmitted.addingReportingOverflow(page.omittedCount)
            hiddenOmitted = overflow ? UInt64.max : sum
        }

        let reduction = VisibilityReducer.reduce(
            TreemapInput(revision: Revision(0), items: items),
            in: bounds,
            minimumArea: threshold,
            precollapsedWeight: page.omittedWeight ?? 0
        )
        overflowed = overflowed || reduction.weightSumOverflowed

        var entries: [DrawableEntry] = []
        entries.reserveCapacity(reduction.drawableTiles.count)

        for tile in reduction.visibleTiles {
            guard let node = byID[tile.id] else { continue }
            entries.append(
                DrawableEntry(
                    identity: .node(node.nodeID),
                    tile: tile,
                    node: node,
                    weight: tile.weight,
                    stableKey: stableKey(for: node),
                    collapsedCount: 0,
                    isExpanded: node.isExpanded,
                    children: node.children
                )
            )
        }

        if let otherTile = reduction.otherTile {
            // The other tile's weight only covers the omitted children when
            // their weight is known. When it is unknown, the loaded
            // threshold-collapsed items are all the weight represents, so the
            // tile must not claim the (weightless) omitted count. The unknown
            // count is surfaced separately via `hiddenOmitted`.
            let representedOmitted = page.omittedWeight == nil ? 0 : page.omittedCount
            let (count, countOverflow) = UInt64(reduction.collapsedItems.count)
                .addingReportingOverflow(representedOmitted)
            entries.append(
                DrawableEntry(
                    identity: .other(parent: page.parentID),
                    tile: otherTile,
                    node: nil,
                    weight: otherTile.weight,
                    stableKey: VisibilityReducer.otherStableKey,
                    collapsedCount: countOverflow ? UInt64.max : count,
                    isExpanded: false,
                    children: nil
                )
            )
        }

        entries.sort { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            if lhs.stableKey != rhs.stableKey { return lhs.stableKey < rhs.stableKey }
            return identitySortKey(lhs.identity) < identitySortKey(rhs.identity)
        }
        return entries
    }

    private static func append(
        entry: DrawableEntry,
        paletteIndex: Int,
        depth: Int,
        parentID: NodeID,
        maximumDepth: Int,
        threshold: Double,
        tiles: inout [TreemapRenderTile],
        overflowed: inout Bool,
        hiddenOmitted: inout UInt64
    ) {
        let gap = depth == 1 ? topLevelGap : nestedGap
        let rect = entry.tile.rect.insetBy(dx: gap / 2, dy: gap / 2)
        guard rect.width > 0, rect.height > 0 else { return }

        var contentRect: TreemapRect?
        if let children = entry.children, !children.children.isEmpty,
           depth < maximumDepth,
           let raw = makeContentRect(for: rect, depth: depth) {
            contentRect = raw
        }

        let tile = TreemapRenderTile(
            identity: entry.identity,
            parentID: parentID,
            rect: rect,
            contentRect: contentRect,
            depth: depth,
            paletteIndex: paletteIndex,
            displayName: entry.node?.name ?? otherDisplayName(count: entry.collapsedCount),
            effectiveBytes: entry.weight,
            collapsedCount: entry.collapsedCount,
            kind: entry.node?.kind,
            isExpanded: entry.isExpanded
        )
        tiles.append(tile)

        guard let children = entry.children,
              let content = contentRect,
              content.width >= 4, content.height >= 4 else { return }

        let childEntries = drawableEntries(
            page: children,
            in: content,
            threshold: threshold,
            overflowed: &overflowed,
            hiddenOmitted: &hiddenOmitted
        )
        // Descendants inherit their parent's palette; only depth 1 assigns new
        // palette groups.
        for child in childEntries {
            append(
                entry: child,
                paletteIndex: paletteIndex,
                depth: depth + 1,
                parentID: children.parentID,
                maximumDepth: maximumDepth,
                threshold: threshold,
                tiles: &tiles,
                overflowed: &overflowed,
                hiddenOmitted: &hiddenOmitted
            )
        }
    }

    private static func makeContentRect(for rect: TreemapRect, depth: Int) -> TreemapRect? {
        let padding = depth == 1 ? 4.0 : 2.0
        let header = min(maximumHeaderHeight, rect.height * 0.3)
        var content = rect.insetBy(dx: padding, dy: padding)
        content.y += header
        content.height = max(0, content.height - header)
        guard content.width > 0, content.height > 0 else { return nil }
        return content
    }

    private static func stableKey(for node: TreemapHierarchyNode) -> String {
        "\(node.name)\u{1}\(node.nodeID.rawValue)"
    }

    private static func otherDisplayName(count: UInt64) -> String {
        count == 0 ? "其他" : "其他（\(count) 项）"
    }

    private static func identitySortKey(_ identity: TreemapRenderTile.Identity) -> UInt64 {
        switch identity {
        case .node(let id): return id.rawValue
        case .other: return UInt64.max
        }
    }

    private static func nextThreshold(_ threshold: Double) -> Double {
        if threshold <= 0 { return 1 }
        return threshold * 1.5
    }
}
