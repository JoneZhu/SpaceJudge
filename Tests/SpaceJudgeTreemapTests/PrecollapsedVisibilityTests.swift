import Testing
import SpaceJudgeDomain
import SpaceJudgeTreemap

@Suite("Precollapsed visibility")
struct PrecollapsedVisibilityTests {
    private let bounds = TreemapRect(x: 0, y: 0, width: 100, height: 100)

    @Test("Precollapsed weight folds into other without losing total")
    func precollapsedMerge() throws {
        let input = TreemapInput(items: [
            LayoutChecks.item(1, 1_000, "a"),
            LayoutChecks.item(2, 500, "b")
        ])
        let reduction = VisibilityReducer.reduce(
            input,
            in: bounds,
            minimumArea: 0,
            precollapsedWeight: 250
        )
        let other = try #require(reduction.otherTile)
        #expect(other.weight == 250)
        #expect(reduction.precollapsedWeight == 250)
        #expect(reduction.visibleWeight + reduction.collapsedWeight == reduction.totalWeight)
        #expect(reduction.totalWeight == 1_750)
        #expect(reduction.visibleTiles.count == 2)
        LayoutChecks.expectTilesValid(reduction.drawableTiles, bounds: bounds)
    }

    @Test("Precollapsed weight with no items still yields one other tile")
    func precollapsedOnly() throws {
        let reduction = VisibilityReducer.reduce(
            TreemapInput(items: []),
            in: bounds,
            minimumArea: 64,
            precollapsedWeight: 900
        )
        let other = try #require(reduction.otherTile)
        #expect(other.weight == 900)
        #expect(reduction.visibleTiles.isEmpty)
        #expect(reduction.totalWeight == 900)
        #expect(reduction.drawableTiles.count == 1)
    }

    @Test("Threshold-collapsed items merge with the precollapsed weight")
    func mergedOther() throws {
        let input = TreemapInput(items: [
            LayoutChecks.item(1, 10_000, "a"),
            LayoutChecks.item(2, 1, "b"),
            LayoutChecks.item(3, 1, "c")
        ])
        let reduction = VisibilityReducer.reduce(
            input,
            in: bounds,
            minimumArea: 1_000,
            precollapsedWeight: 50
        )
        let other = try #require(reduction.otherTile)
        #expect(reduction.collapsedItems.map(\.id) == [NodeID(2), NodeID(3)])
        #expect(other.weight == 52)
        #expect(reduction.totalWeight == 10_052)
        #expect(reduction.visibleWeight + reduction.collapsedWeight == reduction.totalWeight)
    }

    @Test("Precollapsed overflow saturates instead of wrapping")
    func overflow() throws {
        let reduction = VisibilityReducer.reduce(
            TreemapInput(items: [LayoutChecks.item(1, UInt64.max, "a")]),
            in: bounds,
            minimumArea: 0,
            precollapsedWeight: 10
        )
        #expect(reduction.weightSumOverflowed)
        #expect(reduction.totalWeight == UInt64.max)
        // The other tile only carries the precollapsed weight; the total is
        // what saturates.
        let other = try #require(reduction.otherTile)
        #expect(other.weight == 10)
    }

    @Test("Zero precollapsed weight keeps prior behavior")
    func zeroKeepsBehavior() {
        let input = TreemapInput(items: [
            LayoutChecks.item(1, 100, "a"),
            LayoutChecks.item(2, 1, "b")
        ])
        let reduction = VisibilityReducer.reduce(input, in: bounds, minimumArea: 0)
        #expect(reduction.otherTile == nil)
        #expect(reduction.precollapsedWeight == 0)
    }
}
