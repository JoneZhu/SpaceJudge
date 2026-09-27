import Testing
import SpaceJudgeDomain
import SpaceJudgeTreemap

@Suite("Determinism")
struct DeterminismTests {
    private let layout = SquarifiedTreemap()

    @Test("Input order does not change output")
    func shuffledInput() {
        let bounds = TreemapRect(x: 0, y: 0, width: 800, height: 500)
        let items = [
            LayoutChecks.item(1, 500, "alpha"),
            LayoutChecks.item(2, 300, "beta"),
            LayoutChecks.item(3, 300, "gamma"),
            LayoutChecks.item(4, 120, "delta"),
            LayoutChecks.item(5, 120, "epsilon"),
            LayoutChecks.item(6, 40, "zeta"),
            LayoutChecks.item(7, 10, "eta")
        ]
        let reference = layout.layout(TreemapInput(revision: Revision(2), items: items), in: bounds)

        var rng = SplitMix64(seed: 0xC0FFEE)
        for _ in 0..<50 {
            let shuffled = items.shuffled(using: &rng)
            let output = layout.layout(TreemapInput(revision: Revision(2), items: shuffled), in: bounds)
            #expect(output.tiles == reference.tiles)
            #expect(output.totalWeight == reference.totalWeight)
        }
    }

    @Test("Equal weights fall back to stable key order")
    func stableKeyTieBreak() {
        let bounds = TreemapRect(x: 0, y: 0, width: 400, height: 200)
        let ordered = [
            LayoutChecks.item(3, 100, "aaa"),
            LayoutChecks.item(1, 100, "bbb"),
            LayoutChecks.item(2, 100, "ccc")
        ]
        let shuffled = [ordered[2], ordered[0], ordered[1]]
        let first = layout.layout(TreemapInput(items: ordered), in: bounds)
        let second = layout.layout(TreemapInput(items: shuffled), in: bounds)
        #expect(first.tiles == second.tiles)
        #expect(first.tiles.map(\.id) == [NodeID(3), NodeID(1), NodeID(2)])
    }

    @Test("Repeated layout of the same input is identical")
    func idempotent() {
        let bounds = TreemapRect(x: 1, y: 2, width: 640, height: 480)
        let items = (1...13).map { LayoutChecks.item(UInt64($0), UInt64($0) * 13) }
        let input = TreemapInput(revision: Revision(9), items: items)
        let first = layout.layout(input, in: bounds)
        let second = layout.layout(input, in: bounds)
        #expect(first.tiles == second.tiles)
        #expect(first.bounds == second.bounds)
        #expect(first.revision == Revision(9))
    }
}
