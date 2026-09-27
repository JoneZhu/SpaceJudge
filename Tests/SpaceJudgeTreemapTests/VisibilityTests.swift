import Testing
import SpaceJudgeDomain
import SpaceJudgeTreemap

@Suite("Visibility reduction")
struct VisibilityTests {
    private let bounds = TreemapRect(x: 0, y: 0, width: 100, height: 100)

    private func makeInput() -> TreemapInput {
        TreemapInput(items: [
            LayoutChecks.item(1, 10_000, "a"),
            LayoutChecks.item(2, 5_000, "b"),
            LayoutChecks.item(3, 1_000, "c"),
            LayoutChecks.item(4, 100, "d"),
            LayoutChecks.item(5, 1, "e")
        ])
    }

    /// Verifies drawable coverage, non-overlap and weight-proportional areas.
    private func expectDrawableProportional(_ reduction: TreemapReduction) {
        LayoutChecks.expectTilesValid(reduction.drawableTiles, bounds: bounds)
        let weightSum = reduction.drawableTiles.reduce(0.0) { $0 + Double($1.weight) }
        guard weightSum > 0 else { return }
        let scale = bounds.area / weightSum
        for tile in reduction.drawableTiles {
            let expected = Double(tile.weight) * scale
            #expect(
                abs(tile.rect.area - expected) <= max(1e-6, expected * 1e-6),
                "tile \(tile.id) area \(tile.rect.area) differs from expected \(expected)"
            )
        }
    }

    @Test("Threshold of zero keeps every tile visible")
    func noCollapse() {
        let input = makeInput()
        let reduction = VisibilityReducer.reduce(input, in: bounds, minimumArea: 0)
        #expect(reduction.otherTile == nil)
        #expect(reduction.collapsedItems.isEmpty)
        #expect(reduction.visibleTiles.count == input.items.count)
        #expect(reduction.visibleWeight == reduction.totalWeight)
        expectDrawableProportional(reduction)
    }

    @Test("Small items collapse into one other item without losing weight")
    func collapsePreservesWeight() throws {
        let input = makeInput()
        let reduction = VisibilityReducer.reduce(input, in: bounds, minimumArea: 1_000)

        // theoretical area of weight 100 and 1 is below 1000; 1000 is borderline
        // and collapses at 621.0 pt² too.
        let other = try #require(reduction.otherTile)
        #expect(reduction.collapsedItems.map(\.id) == [NodeID(3), NodeID(4), NodeID(5)])
        #expect(other.id == VisibilityReducer.otherNodeID)
        #expect(other.weight == reduction.collapsedWeight)
        #expect(reduction.visibleWeight + reduction.collapsedWeight == reduction.totalWeight)
        #expect(!reduction.weightSumOverflowed)
        expectDrawableProportional(reduction)
    }

    @Test("Final layout never drops a visible tile below the threshold")
    func visibleStaysAboveThreshold() {
        let input = makeInput()
        let threshold = 1_000.0
        let reduction = VisibilityReducer.reduce(input, in: bounds, minimumArea: threshold)
        for tile in reduction.visibleTiles {
            #expect(tile.rect.area >= threshold - 1e-6)
        }
    }

    @Test("Classification follows theoretical area")
    func thresholdClassification() {
        let input = makeInput()
        for threshold in [0.0, 1.0, 50.0, 500.0, 1_000.0, 3_000.0, 10_000.0] {
            let reduction = VisibilityReducer.reduce(input, in: bounds, minimumArea: threshold)
            let weightSum = input.items.reduce(0.0) { $0 + Double($1.weight) }
            for item in input.items {
                let theoretical = Double(item.weight) / weightSum * bounds.area
                let isVisible = reduction.visibleTiles.contains { $0.id == item.id }
                #expect(isVisible == (theoretical >= threshold), "item \(item.id) at threshold \(threshold)")
            }
            expectDrawableProportional(reduction)
        }
    }

    @Test("Everything below the threshold collapses to a single other tile")
    func allCollapsed() throws {
        let input = makeInput()
        let reduction = VisibilityReducer.reduce(input, in: bounds, minimumArea: 1_000_000)
        #expect(reduction.visibleTiles.isEmpty)
        #expect(reduction.collapsedItems.count == input.items.count)
        let other = try #require(reduction.otherTile)
        #expect(other.weight == reduction.collapsedWeight)
        #expect(reduction.drawableTiles.count == 1)
        expectDrawableProportional(reduction)
    }

    @Test("Shuffled input produces the same drawable layout")
    func shuffledDeterminism() {
        let input = makeInput()
        let reference = VisibilityReducer.reduce(input, in: bounds, minimumArea: 1_000)
        var rng = SplitMix64(seed: 0xABCDEF)
        for _ in 0..<25 {
            let shuffled = TreemapInput(
                revision: input.revision,
                items: input.items.shuffled(using: &rng)
            )
            let reduction = VisibilityReducer.reduce(shuffled, in: bounds, minimumArea: 1_000)
            #expect(reduction.drawableTiles == reference.drawableTiles)
            #expect(reduction.collapsedItems == reference.collapsedItems)
        }
    }

    @Test("Empty input reduces to nothing")
    func emptyInput() {
        let reduction = VisibilityReducer.reduce(TreemapInput(items: []), in: bounds, minimumArea: 1)
        #expect(reduction.visibleTiles.isEmpty)
        #expect(reduction.collapsedItems.isEmpty)
        #expect(reduction.otherTile == nil)
        #expect(reduction.visibleWeight == 0)
        #expect(reduction.collapsedWeight == 0)
        #expect(reduction.drawableTiles.isEmpty)
    }

    @Test("Zero-weight items collapse without breaking coverage")
    func zeroWeightItems() {
        let input = TreemapInput(items: [
            LayoutChecks.item(1, 1_000, "a"),
            LayoutChecks.item(2, 0, "b"),
            LayoutChecks.item(3, 0, "c")
        ])
        let reduction = VisibilityReducer.reduce(input, in: bounds, minimumArea: 1)
        #expect(reduction.collapsedItems.count == 2)
        #expect(reduction.collapsedWeight == 0)
        expectDrawableProportional(reduction)
    }
}
