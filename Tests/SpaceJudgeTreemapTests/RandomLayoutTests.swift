import Testing
import SpaceJudgeDomain
import SpaceJudgeTreemap

@Suite("Randomised layout invariants")
struct RandomLayoutTests {
    private let layout = SquarifiedTreemap()

    @Test("Fixed seed produces repeatable, valid layouts")
    func seededInvariants() {
        var rng = SplitMix64(seed: 0x5EED_1234)

        for round in 0..<200 {
            let count = Int.random(in: 1...25, using: &rng)
            let boundsWidth = Double(Int.random(in: 1...1400, using: &rng))
            let boundsHeight = Double(Int.random(in: 1...900, using: &rng))
            let bounds = TreemapRect(x: 0, y: 0, width: boundsWidth, height: boundsHeight)

            var items: [TreemapItem] = []
            for id in 1...count {
                // ~10% zero-weight entries to exercise degenerate input.
                let weight = UInt64.random(in: 0...5, using: &rng) == 0
                    ? 0
                    : UInt64.random(in: 1...1_000_000, using: &rng)
                items.append(LayoutChecks.item(UInt64(id), weight))
            }

            let reference = layout.layout(TreemapInput(items: items), in: bounds)
            LayoutChecks.expectValid(reference, bounds: bounds)
            LayoutChecks.expectProportional(reference, bounds: bounds, tolerance: 1e-5)

            let shuffled = items.shuffled(using: &rng)
            let shuffledOutput = layout.layout(TreemapInput(items: shuffled), in: bounds)
            #expect(
                reference.tiles == shuffledOutput.tiles,
                "round \(round) diverged after shuffling"
            )
        }
    }
}
