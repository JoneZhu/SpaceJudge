import Foundation
import SpaceJudgeDomain

/// Lays out weighted nodes into a rectangle.
public protocol TreemapLayingOut: Sendable {
    func layout(_ input: TreemapInput, in bounds: TreemapRect) -> TreemapOutput
}

/// Deterministic squarified treemap layout (Bruls, Huizing, van Wijk).
///
/// The implementation is pure and single-threaded. It never allocates UI
/// types, never reads clocks or randomness, and produces identical output for
/// identical sorted inputs.
public struct SquarifiedTreemap: TreemapLayingOut {
    public init() {}

    public func layout(_ input: TreemapInput, in bounds: TreemapRect) -> TreemapOutput {
        let sorted = Self.sortedItems(input.items)
        let weights = sorted.map(\.weight)
        let (totalWeight, overflowed) = TreemapWeight.sumSaturating(weights)
        let totalWeightDouble = TreemapWeight.sumAsDouble(weights)

        let normalizedBounds = TreemapRect(
            x: bounds.x,
            y: bounds.y,
            width: max(0, bounds.width),
            height: max(0, bounds.height)
        )

        guard normalizedBounds.width > 0,
              normalizedBounds.height > 0,
              totalWeightDouble > 0
        else {
            let tiles = sorted.map { item in
                TreemapTile(
                    id: item.id,
                    rect: TreemapRect(x: normalizedBounds.x, y: normalizedBounds.y, width: 0, height: 0),
                    weight: item.weight
                )
            }
            return TreemapOutput(
                revision: input.revision,
                bounds: normalizedBounds,
                tiles: tiles,
                totalWeight: totalWeight,
                weightSumOverflowed: overflowed
            )
        }

        let scale = normalizedBounds.area / totalWeightDouble

        var weighted: [WeightedItem] = []
        weighted.reserveCapacity(sorted.count)
        for item in sorted {
            weighted.append(WeightedItem(item: item, area: Double(item.weight) * scale))
        }

        var tiles: [TreemapTile] = []
        tiles.reserveCapacity(weighted.count)

        var remaining = normalizedBounds
        var index = 0

        while index < weighted.count {
            let current = weighted[index]
            if current.area <= 0 {
                break
            }

            let shorterSide = min(remaining.width, remaining.height)
            if shorterSide <= 0 {
                break
            }

            var rowCount = 0
            var rowArea = 0.0
            var rowMaxArea = 0.0
            var rowMinArea = Double.greatestFiniteMagnitude

            while index + rowCount < weighted.count {
                let candidate = weighted[index + rowCount].area
                if candidate <= 0 { break }

                if rowCount == 0 {
                    rowArea = candidate
                    rowMaxArea = candidate
                    rowMinArea = candidate
                    rowCount = 1
                    continue
                }

                let currentWorst = Self.worstAspect(
                    totalArea: rowArea,
                    side: shorterSide,
                    maxArea: rowMaxArea,
                    minArea: rowMinArea
                )
                let candidateArea = rowArea + candidate
                let candidateWorst = Self.worstAspect(
                    totalArea: candidateArea,
                    side: shorterSide,
                    maxArea: max(rowMaxArea, candidate),
                    minArea: min(rowMinArea, candidate)
                )

                if candidateWorst <= currentWorst {
                    rowArea = candidateArea
                    rowMaxArea = max(rowMaxArea, candidate)
                    rowMinArea = min(rowMinArea, candidate)
                    rowCount += 1
                } else {
                    break
                }
            }

            if rowCount == 0 { break }

            let laysColumn = remaining.width >= remaining.height
            if laysColumn {
                let thickness = min(rowArea / shorterSide, remaining.width)
                var offset = 0.0
                for k in 0..<rowCount {
                    let item = weighted[index + k]
                    let isLast = (k == rowCount - 1)
                    let height: Double
                    if isLast {
                        height = max(0, remaining.height - offset)
                    } else {
                        height = rowArea > 0 ? item.area / rowArea * remaining.height : 0
                    }
                    let rect = TreemapRect(
                        x: remaining.x,
                        y: remaining.y + offset,
                        width: thickness,
                        height: height
                    )
                    tiles.append(TreemapTile(id: item.item.id, rect: rect, weight: item.item.weight))
                    offset += height
                }
                remaining.x += thickness
                remaining.width = max(0, remaining.width - thickness)
            } else {
                let thickness = min(rowArea / shorterSide, remaining.height)
                var offset = 0.0
                for k in 0..<rowCount {
                    let item = weighted[index + k]
                    let isLast = (k == rowCount - 1)
                    let width: Double
                    if isLast {
                        width = max(0, remaining.width - offset)
                    } else {
                        width = rowArea > 0 ? item.area / rowArea * remaining.width : 0
                    }
                    let rect = TreemapRect(
                        x: remaining.x + offset,
                        y: remaining.y,
                        width: width,
                        height: thickness
                    )
                    tiles.append(TreemapTile(id: item.item.id, rect: rect, weight: item.item.weight))
                    offset += width
                }
                remaining.y += thickness
                remaining.height = max(0, remaining.height - thickness)
            }

            index += rowCount
        }

        // Remaining items (only possible when the rectangle collapsed to zero
        // area) are emitted as zero-size tiles so no input is silently lost.
        while index < weighted.count {
            let item = weighted[index]
            tiles.append(
                TreemapTile(
                    id: item.item.id,
                    rect: TreemapRect(x: remaining.x, y: remaining.y, width: 0, height: 0),
                    weight: item.item.weight
                )
            )
            index += 1
        }

        return TreemapOutput(
            revision: input.revision,
            bounds: normalizedBounds,
            tiles: tiles,
            totalWeight: totalWeight,
            weightSumOverflowed: overflowed
        )
    }

    // MARK: - Helpers

    private struct WeightedItem {
        let item: TreemapItem
        let area: Double
    }

    /// Deterministic ordering: larger weight first, then stable key, then id.
    static func sortedItems(_ items: [TreemapItem]) -> [TreemapItem] {
        items.sorted { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            if lhs.stableKey != rhs.stableKey { return lhs.stableKey < rhs.stableKey }
            return lhs.id < rhs.id
        }
    }

    static func totalWeight(_ items: [TreemapItem]) -> (value: UInt64, overflowed: Bool) {
        TreemapWeight.sumSaturating(items.map(\.weight))
    }

    /// Worst aspect ratio of a row whose items have the given total area and
    /// extreme item areas, laid along `side`.
    static func worstAspect(
        totalArea: Double,
        side: Double,
        maxArea: Double,
        minArea: Double
    ) -> Double {
        guard totalArea > 0, side > 0, minArea > 0 else { return 0 }
        let totalSquared = totalArea * totalArea
        let sideSquared = side * side
        let longest = (sideSquared * maxArea) / totalSquared
        let narrowest = totalSquared / (sideSquared * minArea)
        return max(longest, narrowest)
    }
}
