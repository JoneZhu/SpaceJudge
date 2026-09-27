import Foundation
import SpaceJudgeDomain

/// Result of collapsing sub-threshold items.
///
/// Classification is done on each item's *theoretical* area before layout, so
/// re-laying out the visible items plus the synthetic "other" item cannot push
/// a formerly visible item below the threshold.
///
/// `visibleTiles` and `otherTile` together are the drawable set returned by
/// `drawableTiles`; they come from a single layout pass over
/// `visibleItems + other`, therefore they fully cover the bounds, do not
/// overlap, and their areas are proportional to their weights. `collapsedItems`
/// keeps the original items for detail display, and `precollapsedWeight` keeps
/// the weight that was never representable as an item (for example children
/// omitted by a query limit).
public struct TreemapReduction: Sendable, Equatable {
    public let visibleTiles: [TreemapTile]
    public let otherTile: TreemapTile?
    public let collapsedItems: [TreemapItem]
    public let visibleWeight: UInt64
    /// Weight of the items actually collapsed by this pass plus any
    /// `precollapsedWeight` supplied by the caller.
    public let collapsedWeight: UInt64
    /// Weight that was folded into "other" before this pass ran.
    public let precollapsedWeight: UInt64
    public let totalWeight: UInt64
    public let weightSumOverflowed: Bool

    public init(
        visibleTiles: [TreemapTile],
        otherTile: TreemapTile?,
        collapsedItems: [TreemapItem],
        visibleWeight: UInt64,
        collapsedWeight: UInt64,
        precollapsedWeight: UInt64 = 0,
        totalWeight: UInt64,
        weightSumOverflowed: Bool
    ) {
        self.visibleTiles = visibleTiles
        self.otherTile = otherTile
        self.collapsedItems = collapsedItems
        self.visibleWeight = visibleWeight
        self.collapsedWeight = collapsedWeight
        self.precollapsedWeight = precollapsedWeight
        self.totalWeight = totalWeight
        self.weightSumOverflowed = weightSumOverflowed
    }

    /// Everything that should be drawn, in a single non-overlapping, full
    /// coverage layout.
    public var drawableTiles: [TreemapTile] {
        guard let otherTile else { return visibleTiles }
        return visibleTiles + [otherTile]
    }
}

/// Deterministic visibility model for a treemap.
public enum VisibilityReducer {
    /// Identifier reserved for the synthetic "other" tile.
    public static let otherNodeID = NodeID(UInt64.max)
    /// Stable sort key reserved for the synthetic "other" tile.
    public static let otherStableKey = "\u{1}spacejudge.other"

    /// Classifies items by their theoretical area and returns a layout in
    /// which everything below `minimumArea` is represented by one "other" tile.
    ///
    /// `precollapsedWeight` is weight that is known to exist but has no
    /// representable input item (for example children skipped by a bounded
    /// query). It participates in the total used for area classification,
    /// always lands in the "other" tile, and is never invented as a fake node.
    /// A zero value keeps the behavior of previous callers unchanged.
    ///
    /// The visible items and the "other" tile are re-laid out together, so the
    /// final drawable tiles fully cover `bounds`, never overlap, and keep an
    /// area proportional to their weights. Total weight is preserved through
    /// `visibleWeight` and `collapsedWeight` (saturating on overflow).
    public static func reduce(
        _ input: TreemapInput,
        in bounds: TreemapRect,
        minimumArea: Double,
        precollapsedWeight: UInt64 = 0,
        layout: any TreemapLayingOut = SquarifiedTreemap(),
        otherID: NodeID = otherNodeID
    ) -> TreemapReduction {
        let threshold = max(0, minimumArea)
        let weights = input.items.map(\.weight)
        let (itemWeight, itemOverflowed) = TreemapWeight.sumSaturating(weights)
        let (totalWeight, totalOverflowed) = addSaturating(itemWeight, precollapsedWeight)
        let totalWeightDouble = TreemapWeight.sumAsDouble(weights) + Double(precollapsedWeight)
        let totalArea = max(0, bounds.area)

        var visibleItems: [TreemapItem] = []
        var collapsedItems: [TreemapItem] = []
        visibleItems.reserveCapacity(input.items.count)

        for item in input.items {
            let theoreticalArea: Double = totalWeightDouble > 0
                ? Double(item.weight) / totalWeightDouble * totalArea
                : 0
            if theoreticalArea >= threshold {
                visibleItems.append(item)
            } else {
                collapsedItems.append(item)
            }
        }

        // Keep the detail list reproducible regardless of input order.
        collapsedItems.sort { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            if lhs.stableKey != rhs.stableKey { return lhs.stableKey < rhs.stableKey }
            return lhs.id < rhs.id
        }

        let (visibleWeight, visibleOverflowed) = TreemapWeight.sumSaturating(visibleItems.map(\.weight))
        let (itemCollapsedWeight, itemCollapsedOverflowed) =
            TreemapWeight.sumSaturating(collapsedItems.map(\.weight))
        let (collapsedWeight, collapsedOverflowed) =
            addSaturating(itemCollapsedWeight, precollapsedWeight)
        let overflowed = totalOverflowed || itemOverflowed || visibleOverflowed
            || itemCollapsedOverflowed || collapsedOverflowed

        let hasOther = !collapsedItems.isEmpty || precollapsedWeight > 0
        var layoutItems = visibleItems
        if hasOther {
            layoutItems.append(
                TreemapItem(id: otherID, weight: collapsedWeight, stableKey: otherStableKey)
            )
        }

        let layoutInput = TreemapInput(revision: input.revision, items: layoutItems)
        let output = layout.layout(layoutInput, in: bounds)

        if !hasOther {
            return TreemapReduction(
                visibleTiles: output.tiles,
                otherTile: nil,
                collapsedItems: [],
                visibleWeight: visibleWeight,
                collapsedWeight: 0,
                precollapsedWeight: precollapsedWeight,
                totalWeight: totalWeight,
                weightSumOverflowed: overflowed
            )
        }

        let otherTile = output.tiles.first { $0.id == otherID }
        let visibleTiles = output.tiles.filter { $0.id != otherID }
        return TreemapReduction(
            visibleTiles: visibleTiles,
            otherTile: otherTile,
            collapsedItems: collapsedItems,
            visibleWeight: visibleWeight,
            collapsedWeight: collapsedWeight,
            precollapsedWeight: precollapsedWeight,
            totalWeight: totalWeight,
            weightSumOverflowed: overflowed
        )
    }

    /// Overflow-safe addition used for weight bookkeeping.
    static func addSaturating(_ lhs: UInt64, _ rhs: UInt64) -> (value: UInt64, overflowed: Bool) {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        if overflow {
            return (UInt64.max, true)
        }
        return (sum, false)
    }
}
