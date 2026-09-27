import Foundation
import SpaceJudgeDomain
import SpaceJudgeTreemap

// Phase 0 smoke executable.
//
// It builds a fixed, in-memory example tree, lays it out with the pure
// squarified treemap, and prints deterministic JSON to stdout. It never
// touches the user's disk and never reads the HTML prototypes.

private let gib: UInt64 = 1024 * 1024 * 1024

private struct ExampleEntry {
    let id: NodeID
    let name: String
    let weight: UInt64
}

private let exampleTree: [ExampleEntry] = [
    ExampleEntry(id: NodeID(1), name: "Applications", weight: 40 * gib),
    ExampleEntry(id: NodeID(2), name: "Library", weight: 30 * gib),
    ExampleEntry(id: NodeID(3), name: "Documents", weight: 15 * gib),
    ExampleEntry(id: NodeID(4), name: "Downloads", weight: 8 * gib),
    ExampleEntry(id: NodeID(5), name: "Pictures", weight: 6 * gib),
    ExampleEntry(id: NodeID(6), name: "Movies", weight: 5 * gib),
    ExampleEntry(id: NodeID(7), name: "Music", weight: 2 * gib),
    ExampleEntry(id: NodeID(8), name: "Desktop", weight: 1 * gib)
]

private func format(_ value: Double) -> String {
    String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
}

private func jsonObject(_ pairs: [(String, String)]) -> String {
    "{" + pairs.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
}

private func render(_ output: TreemapOutput) -> String {
    let bounds = jsonObject([
        ("x", format(output.bounds.x)),
        ("y", format(output.bounds.y)),
        ("width", format(output.bounds.width)),
        ("height", format(output.bounds.height))
    ])

    let tiles = output.tiles.map { tile -> String in
        jsonObject([
            ("id", String(tile.id.rawValue)),
            ("x", format(tile.rect.x)),
            ("y", format(tile.rect.y)),
            ("width", format(tile.rect.width)),
            ("height", format(tile.rect.height)),
            ("weight", String(tile.weight))
        ])
    }

    let root = jsonObject([
        ("bounds", bounds),
        ("tiles", "[" + tiles.joined(separator: ",") + "]"),
        ("totalWeight", String(output.totalWeight))
    ])
    return root
}

let items = exampleTree.map { entry in
    TreemapItem(id: entry.id, weight: entry.weight, stableKey: entry.name)
}

let input = TreemapInput(revision: Revision(1), items: items)
let bounds = TreemapRect(x: 0, y: 0, width: 1000, height: 600)
let output = SquarifiedTreemap().layout(input, in: bounds)

print(render(output))
