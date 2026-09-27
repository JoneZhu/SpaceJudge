import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeTreemap

/// Deterministic, seedable generator so random invariant tests are repeatable.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum LayoutChecks {
    /// Verifies the structural invariants every layout must satisfy.
    static func expectValid(
        _ output: TreemapOutput,
        bounds: TreemapRect,
        areaTolerance: Double = 1e-6
    ) {
        expectTilesValid(output.tiles, bounds: bounds, areaTolerance: areaTolerance)
    }

    /// Verifies containment, non-negativity, non-overlap and full coverage for
    /// an arbitrary tile set (for example a visibility-reduced drawable set).
    static func expectTilesValid(
        _ tiles: [TreemapTile],
        bounds: TreemapRect,
        areaTolerance: Double = 1e-6
    ) {
        for tile in tiles {
            #expect(tile.rect.width >= 0, "negative width for \(tile.id)")
            #expect(tile.rect.height >= 0, "negative height for \(tile.id)")
            #expect(
                tile.rect.isContained(in: bounds),
                "tile \(tile.id) \(tile.rect) escapes bounds \(bounds)"
            )
        }

        for i in 0..<tiles.count {
            for j in (i + 1)..<tiles.count {
                let overlap = tiles[i].rect.intersectionArea(with: tiles[j].rect)
                #expect(
                    overlap <= 1e-6,
                    "tiles \(tiles[i].id) and \(tiles[j].id) overlap by \(overlap)"
                )
            }
        }

        let tileArea = tiles.reduce(0.0) { $0 + $1.rect.area }
        let totalArea = bounds.area
        let hasPositiveWeight = tiles.contains { $0.weight > 0 }
        if hasPositiveWeight {
            #expect(
                abs(tileArea - totalArea) <= max(1e-6, totalArea * areaTolerance),
                "tile area \(tileArea) does not cover bounds area \(totalArea)"
            )
        } else {
            #expect(tileArea == 0, "zero-weight input must not cover area")
        }
    }

    /// Verifies each tile's area is proportional to its weight.
    static func expectProportional(
        _ output: TreemapOutput,
        bounds: TreemapRect,
        tolerance: Double = 1e-6
    ) {
        guard output.totalWeight > 0 else { return }
        let weightSum = output.tiles.reduce(0.0) { $0 + Double($1.weight) }
        guard weightSum > 0 else { return }
        let scale = bounds.area / weightSum
        for tile in output.tiles {
            let expected = Double(tile.weight) * scale
            let allowed = max(1e-6, expected * tolerance)
            #expect(
                abs(tile.rect.area - expected) <= allowed,
                "tile \(tile.id) area \(tile.rect.area) differs from expected \(expected)"
            )
        }
    }

    static func item(_ id: UInt64, _ weight: UInt64, _ key: String? = nil) -> TreemapItem {
        TreemapItem(id: NodeID(id), weight: weight, stableKey: key ?? "node-\(id)")
    }
}
