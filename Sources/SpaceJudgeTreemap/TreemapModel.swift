import Foundation
import SpaceJudgeDomain

/// One weighted input to the treemap layout.
///
/// `stableKey` is the deterministic tie-breaker: two inputs with the same set
/// of `(id, weight, stableKey)` triples always produce identical output,
/// regardless of the order they were supplied in.
public struct TreemapItem: Sendable, Equatable, Hashable, Codable {
    public let id: NodeID
    public let weight: UInt64
    public let stableKey: String

    public init(id: NodeID, weight: UInt64, stableKey: String) {
        self.id = id
        self.weight = weight
        self.stableKey = stableKey
    }
}

/// Immutable input to a layout pass.
public struct TreemapInput: Sendable, Equatable, Hashable, Codable {
    public let revision: Revision
    public let items: [TreemapItem]

    public init(revision: Revision = Revision(0), items: [TreemapItem]) {
        self.revision = revision
        self.items = items
    }
}

/// One placed rectangle.
public struct TreemapTile: Sendable, Equatable, Hashable, Codable {
    public let id: NodeID
    public let rect: TreemapRect
    public let weight: UInt64

    public init(id: NodeID, rect: TreemapRect, weight: UInt64) {
        self.id = id
        self.rect = rect
        self.weight = weight
    }
}

/// Result of a layout pass. `totalWeight` is a saturating integer sum of the
/// input weights: it equals the exact sum while that fits in `UInt64`, and is
/// clamped to `UInt64.max` otherwise. `weightSumOverflowed` records that
/// clamping; layout itself always uses the floating-point weight sum so an
/// overflowing integer total never collapses the layout to zero area.
public struct TreemapOutput: Sendable, Equatable {
    public let revision: Revision
    public let bounds: TreemapRect
    public let tiles: [TreemapTile]
    public let totalWeight: UInt64
    public let weightSumOverflowed: Bool

    public init(
        revision: Revision,
        bounds: TreemapRect,
        tiles: [TreemapTile],
        totalWeight: UInt64,
        weightSumOverflowed: Bool
    ) {
        self.revision = revision
        self.bounds = bounds
        self.tiles = tiles
        self.totalWeight = totalWeight
        self.weightSumOverflowed = weightSumOverflowed
    }
}

/// Overflow-safe weight bookkeeping shared by the layout and visibility model.
public enum TreemapWeight {
    /// Sums weights with saturation.
    ///
    /// The returned value is the exact sum while it fits in `UInt64`; once any
    /// addition overflows it stays clamped at `UInt64.max` and `overflowed` is
    /// `true`. Callers that need geometry must use a floating-point sum, which
    /// this helper intentionally does not replace.
    public static func sumSaturating(
        _ weights: some Sequence<UInt64>
    ) -> (value: UInt64, overflowed: Bool) {
        var total: UInt64 = 0
        var overflowed = false
        for weight in weights {
            let (sum, overflow) = total.addingReportingOverflow(weight)
            if overflow {
                overflowed = true
                total = UInt64.max
            } else {
                total = sum
            }
        }
        return (total, overflowed)
    }

    /// Floating-point sum used for area scaling.
    public static func sumAsDouble(_ weights: some Sequence<UInt64>) -> Double {
        weights.reduce(0.0) { $0 + Double($1) }
    }
}
