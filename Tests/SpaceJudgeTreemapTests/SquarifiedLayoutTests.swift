import Testing
import SpaceJudgeDomain
import SpaceJudgeTreemap

@Suite("Squarified layout")
struct SquarifiedLayoutTests {
    private let bounds = TreemapRect(x: 0, y: 0, width: 1000, height: 600)
    private let layout = SquarifiedTreemap()

    @Test("Single node fills the whole bounds")
    func singleNode() {
        let output = layout.layout(
            TreemapInput(items: [LayoutChecks.item(1, 42)]),
            in: bounds
        )
        #expect(output.tiles.count == 1)
        #expect(output.tiles[0].rect == bounds)
        #expect(output.totalWeight == 42)
        LayoutChecks.expectValid(output, bounds: bounds)
        LayoutChecks.expectProportional(output, bounds: bounds)
    }

    @Test("Equal weights produce equal areas")
    func equalWeights() {
        let items = (1...4).map { LayoutChecks.item(UInt64($0), 100) }
        let output = layout.layout(TreemapInput(items: items), in: bounds)
        #expect(output.tiles.count == 4)
        LayoutChecks.expectValid(output, bounds: bounds)
        LayoutChecks.expectProportional(output, bounds: bounds)
    }

    @Test("Zero-weight nodes are kept with zero area")
    func zeroWeight() {
        let items = [
            LayoutChecks.item(1, 100),
            LayoutChecks.item(2, 0),
            LayoutChecks.item(3, 50)
        ]
        let output = layout.layout(TreemapInput(items: items), in: bounds)
        #expect(output.tiles.count == 3)
        #expect(output.totalWeight == 150)
        for tile in output.tiles where tile.weight == 0 {
            #expect(tile.rect.area == 0)
        }
        LayoutChecks.expectValid(output, bounds: bounds)
        LayoutChecks.expectProportional(output, bounds: bounds)
    }

    @Test("All-zero weights yield zero-area tiles without negative sizes")
    func allZeroWeight() {
        let items = (1...3).map { LayoutChecks.item(UInt64($0), 0) }
        let output = layout.layout(TreemapInput(items: items), in: bounds)
        #expect(output.tiles.count == 3)
        #expect(output.totalWeight == 0)
        for tile in output.tiles {
            #expect(tile.rect.width == 0)
            #expect(tile.rect.height == 0)
        }
        LayoutChecks.expectValid(output, bounds: bounds)
    }

    @Test("Empty input yields no tiles")
    func emptyInput() {
        let output = layout.layout(TreemapInput(items: []), in: bounds)
        #expect(output.tiles.isEmpty)
        #expect(output.totalWeight == 0)
    }

    @Test("Empty bounds yield zero-area tiles")
    func emptyBounds() {
        let zero = TreemapRect(x: 5, y: 5, width: 0, height: 0)
        let items = (1...3).map { LayoutChecks.item(UInt64($0), UInt64($0) * 10) }
        let output = layout.layout(TreemapInput(items: items), in: zero)
        #expect(output.tiles.count == 3)
        for tile in output.tiles {
            #expect(tile.rect.width == 0)
            #expect(tile.rect.height == 0)
            #expect(tile.rect.x == 5)
            #expect(tile.rect.y == 5)
        }
        LayoutChecks.expectValid(output, bounds: zero)
    }

    @Test("Negative bounds are normalised to zero")
    func negativeBounds() {
        let negative = TreemapRect(x: 0, y: 0, width: -100, height: 50)
        let items = (1...2).map { LayoutChecks.item(UInt64($0), UInt64($0)) }
        let output = layout.layout(TreemapInput(items: items), in: negative)
        for tile in output.tiles {
            #expect(tile.rect.width >= 0)
            #expect(tile.rect.height >= 0)
        }
    }

    @Test("Extreme wide aspect ratio stays valid")
    func wideBounds() {
        let wide = TreemapRect(x: 0, y: 0, width: 2000, height: 1)
        let items = (1...6).map { LayoutChecks.item(UInt64($0), UInt64($0) * 1000) }
        let output = layout.layout(TreemapInput(items: items), in: wide)
        LayoutChecks.expectValid(output, bounds: wide)
        LayoutChecks.expectProportional(output, bounds: wide)
    }

    @Test("Extreme tall aspect ratio stays valid")
    func tallBounds() {
        let tall = TreemapRect(x: 0, y: 0, width: 1, height: 2000)
        let items = (1...6).map { LayoutChecks.item(UInt64($0), UInt64($0) * 1000) }
        let output = layout.layout(TreemapInput(items: items), in: tall)
        LayoutChecks.expectValid(output, bounds: tall)
        LayoutChecks.expectProportional(output, bounds: tall)
    }

    @Test("Million-scale weights keep area proportions")
    func largeWeights() {
        let items = [
            LayoutChecks.item(1, 1_000_000_000_000),
            LayoutChecks.item(2, 999_999_999_999),
            LayoutChecks.item(3, 1)
        ]
        let output = layout.layout(TreemapInput(items: items), in: bounds)
        LayoutChecks.expectValid(output, bounds: bounds)
        LayoutChecks.expectProportional(output, bounds: bounds)
    }

    @Test("Very skewed weights keep area proportions")
    func skewedWeights() {
        let items = [
            LayoutChecks.item(1, 1_000_000),
            LayoutChecks.item(2, 1),
            LayoutChecks.item(3, 1),
            LayoutChecks.item(4, 1)
        ]
        let output = layout.layout(TreemapInput(items: items), in: bounds)
        LayoutChecks.expectValid(output, bounds: bounds)
        LayoutChecks.expectProportional(output, bounds: bounds)
    }

    @Test("UInt64 total weight overflow still produces a valid non-degenerate layout")
    func totalWeightOverflow() {
        let items = [LayoutChecks.item(1, UInt64.max), LayoutChecks.item(2, 1)]
        let output = layout.layout(TreemapInput(items: items), in: bounds)
        #expect(output.weightSumOverflowed)
        #expect(output.totalWeight == UInt64.max)
        #expect(output.tiles.count == 2)
        #expect(output.tiles.contains { $0.rect.area > 0 })
        LayoutChecks.expectValid(output, bounds: bounds)
        LayoutChecks.expectProportional(output, bounds: bounds)
    }

    @Test("Overflow with a representable second weight gives both tiles area")
    func totalWeightOverflowWithRepresentableWeight() {
        let items = [LayoutChecks.item(1, UInt64.max), LayoutChecks.item(2, 1_000_000_000_000)]
        let output = layout.layout(TreemapInput(items: items), in: bounds)
        #expect(output.weightSumOverflowed)
        #expect(output.totalWeight == UInt64.max)
        for tile in output.tiles {
            #expect(tile.rect.area > 0, "tile \(tile.id) has no area")
        }
        LayoutChecks.expectValid(output, bounds: bounds)
        LayoutChecks.expectProportional(output, bounds: bounds)
    }

    @Test("Repeated overflow saturates but still lays out every tile")
    func repeatedOverflow() {
        let items = (1...3).map { LayoutChecks.item(UInt64($0), UInt64.max) }
        let output = layout.layout(TreemapInput(items: items), in: bounds)
        #expect(output.weightSumOverflowed)
        #expect(output.totalWeight == UInt64.max)
        #expect(output.tiles.count == 3)
        for tile in output.tiles {
            #expect(tile.rect.area > 0)
        }
        LayoutChecks.expectValid(output, bounds: bounds)
        LayoutChecks.expectProportional(output, bounds: bounds)
    }

    @Test("Every input id appears exactly once")
    func allIdsPresent() {
        let items = (1...20).map { LayoutChecks.item(UInt64($0), UInt64($0) * 7) }
        let output = layout.layout(TreemapInput(items: items), in: bounds)
        let ids = Set(output.tiles.map(\.id))
        #expect(ids == Set(items.map(\.id)))
        #expect(output.tiles.count == items.count)
    }
}
