import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeTreemap

@Suite("Treemap hit index")
struct TreemapHitIndexTests {
    private func tile(
        _ id: UInt64,
        _ rect: TreemapRect,
        depth: Int = 1,
        parent: UInt64 = 1
    ) -> TreemapRenderTile {
        TreemapRenderTile(
            identity: .node(NodeID(id)),
            parentID: NodeID(parent),
            rect: rect,
            depth: depth,
            paletteIndex: 0,
            displayName: "n\(id)",
            effectiveBytes: UInt64(rect.area),
            kind: .regularFile
        )
    }

    @Test("Random points agree with the linear reference")
    func differential() {
        var rng = SplitMix64(seed: 0x1234_5678)
        let bounds = TreemapRect(x: 0, y: 0, width: 512, height: 384)
        // 100 deterministic scenes with 100 random queries each: 10,000
        // differential comparisons in total.
        for scene in 0..<100 {
            var tiles: [TreemapRenderTile] = []
            let count = 20 + scene * 3
            for index in 0..<count {
                let x = Double(rng.next() % 512)
                let y = Double(rng.next() % 384)
                let width = Double(rng.next() % 80) + 1
                let height = Double(rng.next() % 70) + 1
                tiles.append(
                    tile(UInt64(index + 2), TreemapRect(x: x, y: y, width: width, height: height))
                )
            }
            let index = TreemapHitIndex(tiles: tiles, bounds: bounds)
            for _ in 0..<100 {
                let point = TreemapPoint(
                    x: Double(rng.next() % 512) + Double(rng.next() % 100) / 100,
                    y: Double(rng.next() % 384) + Double(rng.next() % 100) / 100
                )
                let indexed = index.tile(at: point)
                let reference = TreemapHitIndex.referenceTile(at: point, in: tiles)
                #expect(indexed == reference, "mismatch at \(point) in scene \(scene)")
            }
        }
    }

    @Test("A shared edge belongs to exactly one sibling")
    func sharedEdge() {
        let left = tile(2, TreemapRect(x: 0, y: 0, width: 100, height: 100))
        let right = tile(3, TreemapRect(x: 100, y: 0, width: 100, height: 100))
        let index = TreemapHitIndex(
            tiles: [left, right],
            bounds: TreemapRect(x: 0, y: 0, width: 200, height: 100)
        )
        let onEdge = index.tile(at: TreemapPoint(x: 100, y: 50))
        #expect(onEdge == right)
        #expect(index.tile(at: TreemapPoint(x: 99.999, y: 50)) == left)
    }

    @Test("The deepest tile wins over its parent")
    func deepestTile() {
        let parent = tile(2, TreemapRect(x: 0, y: 0, width: 200, height: 200), depth: 1)
        let child = tile(
            3, TreemapRect(x: 20, y: 20, width: 80, height: 80), depth: 2, parent: 2
        )
        let index = TreemapHitIndex(
            tiles: [parent, child],
            bounds: TreemapRect(x: 0, y: 0, width: 200, height: 200)
        )
        #expect(index.tile(at: TreemapPoint(x: 40, y: 40)) == child)
        #expect(index.tile(at: TreemapPoint(x: 150, y: 150)) == parent)
    }

    @Test("Empty scene, degenerate rects and outside points return nil")
    func emptyAndDegenerate() {
        let bounds = TreemapRect(x: 0, y: 0, width: 100, height: 100)
        let empty = TreemapHitIndex(tiles: [], bounds: bounds)
        #expect(empty.tile(at: TreemapPoint(x: 50, y: 50)) == nil)

        let degenerate = TreemapHitIndex(
            tiles: [tile(2, TreemapRect(x: 10, y: 10, width: 0, height: 10))],
            bounds: bounds
        )
        #expect(degenerate.tile(at: TreemapPoint(x: 10, y: 10)) == nil)
        #expect(empty.tile(at: TreemapPoint(x: -1, y: -1)) == nil)
        #expect(empty.tile(at: TreemapPoint(x: 500, y: 500)) == nil)
    }

    @Test("Rebuilding for a new size preserves deterministic hits")
    func resize() {
        let tiles = [
            tile(2, TreemapRect(x: 0, y: 0, width: 100, height: 100)),
            tile(3, TreemapRect(x: 100, y: 0, width: 100, height: 100))
        ]
        let small = TreemapHitIndex(tiles: tiles, bounds: TreemapRect(x: 0, y: 0, width: 200, height: 100))
        let large = TreemapHitIndex(tiles: tiles, bounds: TreemapRect(x: 0, y: 0, width: 2_000, height: 1_000))
        for point in [TreemapPoint(x: 50, y: 50), TreemapPoint(x: 150, y: 50)] {
            #expect(small.tile(at: point) == large.tile(at: point))
        }
    }

    @Test("Zero-size bounds never crash or match")
    func zeroBounds() {
        let index = TreemapHitIndex(tiles: [], bounds: .zero)
        #expect(index.tile(at: .zero) == nil)
    }
}
