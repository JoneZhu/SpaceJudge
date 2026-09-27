import Foundation

/// Bounded uniform-grid spatial index over render tiles.
///
/// The index is built once per render snapshot and answers point queries
/// without scanning the whole scene. Each tile is registered in every grid
/// cell its rectangle touches, in draw order; a query inspects only the cell
/// containing the point and returns the deepest tile, breaking depth ties by
/// draw order (later tiles win). Boundaries use half-open containment so a
/// point on a shared sibling edge belongs to exactly one tile.
public struct TreemapHitIndex: Sendable {
    /// Default cell size in points.
    public static let defaultCellSize = 56.0
    /// Safety cap on `columns * rows`; the cell size is grown if exceeded.
    private static let maximumCellCount = 4_000_000

    public let bounds: TreemapRect
    public let cellSize: Double
    public let columns: Int
    public let rows: Int
    private let buckets: [[Int]]
    private let tiles: [TreemapRenderTile]

    public init(
        tiles: [TreemapRenderTile],
        bounds: TreemapRect,
        cellSize: Double = TreemapHitIndex.defaultCellSize
    ) {
        self.tiles = tiles
        let normalizedBounds = TreemapRect(
            x: bounds.x,
            y: bounds.y,
            width: max(0, bounds.width),
            height: max(0, bounds.height)
        )
        self.bounds = normalizedBounds

        var resolvedCell = max(1, cellSize)
        let width = normalizedBounds.width
        let height = normalizedBounds.height
        var columns = max(1, Int(ceil(width / resolvedCell)))
        var rows = max(1, Int(ceil(height / resolvedCell)))
        while columns * rows > Self.maximumCellCount {
            resolvedCell *= 2
            columns = max(1, Int(ceil(width / resolvedCell)))
            rows = max(1, Int(ceil(height / resolvedCell)))
        }
        self.cellSize = resolvedCell
        self.columns = columns
        self.rows = rows

        var storage = [[Int]](repeating: [], count: columns * rows)
        for (index, tile) in tiles.enumerated() {
            let rect = tile.rect
            guard rect.width > 0, rect.height > 0 else { continue }
            // Clamp to the indexed bounds; tiles outside are still reachable
            // through the nearest edge cell.
            let minColumn = Self.clampColumn(rect.minX, bounds: normalizedBounds, cell: resolvedCell, count: columns)
            let maxColumn = Self.clampColumn(rect.maxX - Double.ulpOfOne, bounds: normalizedBounds, cell: resolvedCell, count: columns)
            let minRow = Self.clampRow(rect.minY, bounds: normalizedBounds, cell: resolvedCell, count: rows)
            let maxRow = Self.clampRow(rect.maxY - Double.ulpOfOne, bounds: normalizedBounds, cell: resolvedCell, count: rows)
            guard minColumn <= maxColumn, minRow <= maxRow else { continue }
            for row in minRow...maxRow {
                let rowBase = row * columns
                for column in minColumn...maxColumn {
                    storage[rowBase + column].append(index)
                }
            }
        }
        self.buckets = storage
    }

    /// The deepest tile containing `point`, or `nil` when the point is outside
    /// the indexed bounds or only touches gaps between tiles.
    public func tile(at point: TreemapPoint) -> TreemapRenderTile? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard point.x >= bounds.minX, point.x < bounds.maxX,
              point.y >= bounds.minY, point.y < bounds.maxY else {
            return nil
        }
        let column = Self.clampColumn(point.x, bounds: bounds, cell: cellSize, count: columns)
        let row = Self.clampRow(point.y, bounds: bounds, cell: cellSize, count: rows)
        let bucket = buckets[row * columns + column]

        var best: TreemapRenderTile?
        var bestDepth = Int.min
        for index in bucket {
            let tile = tiles[index]
            guard tile.contains(point) else { continue }
            if tile.depth >= bestDepth {
                bestDepth = tile.depth
                best = tile
            }
        }
        return best
    }

    /// Every tile registered in the cell containing `point`, in draw order.
    /// Exposed for differential tests against a linear reference.
    public func candidates(at point: TreemapPoint) -> [TreemapRenderTile] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        guard point.x >= bounds.minX, point.x < bounds.maxX,
              point.y >= bounds.minY, point.y < bounds.maxY else {
            return []
        }
        let column = Self.clampColumn(point.x, bounds: bounds, cell: cellSize, count: columns)
        let row = Self.clampRow(point.y, bounds: bounds, cell: cellSize, count: rows)
        return buckets[row * columns + column].map { tiles[$0] }
    }

    /// Linear reference implementation used by differential tests, kept in
    /// production code so it can never drift from the indexed version.
    public static func referenceTile(
        at point: TreemapPoint,
        in tiles: [TreemapRenderTile]
    ) -> TreemapRenderTile? {
        var best: TreemapRenderTile?
        var bestDepth = Int.min
        for tile in tiles {
            guard tile.contains(point) else { continue }
            if tile.depth >= bestDepth {
                bestDepth = tile.depth
                best = tile
            }
        }
        return best
    }

    // MARK: - Helpers

    private static func clampColumn(
        _ x: Double,
        bounds: TreemapRect,
        cell: Double,
        count: Int
    ) -> Int {
        let relative = (x - bounds.minX) / cell
        let raw = relative.isFinite ? Int(floor(relative)) : 0
        return min(max(raw, 0), count - 1)
    }

    private static func clampRow(
        _ y: Double,
        bounds: TreemapRect,
        cell: Double,
        count: Int
    ) -> Int {
        let relative = (y - bounds.minY) / cell
        let raw = relative.isFinite ? Int(floor(relative)) : 0
        return min(max(raw, 0), count - 1)
    }
}
