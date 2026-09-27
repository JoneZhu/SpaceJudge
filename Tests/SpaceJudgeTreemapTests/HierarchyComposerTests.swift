import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeTreemap

@Suite("Hierarchy composer")
struct HierarchyComposerTests {
    private let bounds = TreemapRect(x: 0, y: 0, width: 1_280, height: 800)

    private func makeKey(
        mode: TreemapDetailMode = .detail,
        revision: UInt64 = 1
    ) -> TreemapLayoutKey {
        TreemapLayoutKey(
            scanGeneration: 1,
            scanID: ScanID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!),
            focusNodeID: NodeID(1),
            sceneRevision: Revision(revision),
            expansionVersion: 1,
            detailMode: mode,
            width: bounds.width,
            height: bounds.height,
            backingScale: 2
        )
    }

    private func file(_ id: UInt64, _ weight: UInt64) -> TreemapHierarchyNode {
        TreemapHierarchyNode(
            nodeID: NodeID(id),
            name: "file-\(id)",
            kind: .regularFile,
            effectiveBytes: weight
        )
    }

    private func makePage(
        _ parent: UInt64,
        _ children: [TreemapHierarchyNode],
        omittedCount: UInt64,
        omittedWeight: UInt64?
    ) -> TreemapHierarchyPage {
        TreemapHierarchyPage(
            parentID: NodeID(parent),
            children: children,
            omittedCount: omittedCount,
            omittedWeight: omittedWeight,
            totalDirectChildCount: UInt64(children.count) + omittedCount
        )
    }

    private func plainPage(_ parent: UInt64, _ children: [TreemapHierarchyNode]) -> TreemapHierarchyPage {
        makePage(parent, children, omittedCount: 0, omittedWeight: nil)
    }

    private func makeHierarchy(_ page: TreemapHierarchyPage) -> TreemapHierarchy {
        TreemapHierarchy(
            focus: TreemapHierarchyNode(
                nodeID: NodeID(1),
                name: "root",
                kind: .directory,
                effectiveBytes: 0,
                isExpanded: true,
                children: page
            )
        )
    }

    @Test("Visible tiles stay inside their parent content rect and do not overlap")
    func containmentAndNonOverlap() {
        var children: [TreemapHierarchyNode] = []
        for index in 0..<20 {
            children.append(file(UInt64(index + 2), UInt64(1_000 - index * 10)))
        }
        let snapshot = TreemapHierarchyComposer.snapshot(
            makeHierarchy(plainPage(1, children)),
            key: makeKey(),
            bounds: bounds
        )
        for tile in snapshot.tiles {
            #expect(tile.rect.width >= 0)
            #expect(tile.rect.height >= 0)
            #expect(tile.rect.isContained(in: bounds, tolerance: 1e-6))
        }
        for i in 0..<snapshot.tiles.count {
            for j in (i + 1)..<snapshot.tiles.count {
                let a: TreemapRenderTile = snapshot.tiles[i]
                let b: TreemapRenderTile = snapshot.tiles[j]
                guard a.depth == b.depth, a.parentID == b.parentID else { continue }
                let overlap = a.rect.intersectionArea(with: b.rect)
                #expect(overlap <= 1e-6)
            }
        }
    }

    @Test("Expanded children are placed inside the parent content rect")
    func expansionInsideContent() throws {
        var grandChildren: [TreemapHierarchyNode] = []
        for index in 0..<6 {
            grandChildren.append(file(UInt64(100 + index), UInt64(500 - index * 10)))
        }
        let expanded = TreemapHierarchyNode(
            nodeID: NodeID(2),
            name: "dir",
            kind: .directory,
            effectiveBytes: 4_000,
            isExpanded: true,
            children: plainPage(2, grandChildren)
        )
        var children: [TreemapHierarchyNode] = [expanded]
        children.append(file(3, 3_000))
        children.append(file(4, 2_000))
        let snapshot = TreemapHierarchyComposer.snapshot(
            makeHierarchy(plainPage(1, children)),
            key: makeKey(mode: .detail),
            bounds: bounds
        )
        let parentID = NodeID(2)
        let parent = try #require(snapshot.tiles.first { $0.identity == TreemapRenderTile.Identity.node(parentID) })
        let content = try #require(parent.contentRect)
        let nested = snapshot.tiles.filter { $0.depth == 2 && $0.parentID == parentID }
        #expect(!nested.isEmpty)
        for tile in nested {
            #expect(tile.rect.isContained(in: content, tolerance: 1e-6))
        }
    }

    @Test("Overview and detail respect their maximum depth")
    func maximumDepth() {
        let level3: [TreemapHierarchyNode] = (0..<4).map { file(UInt64(300 + $0), 100) }
        let level2 = TreemapHierarchyNode(
            nodeID: NodeID(200), name: "d2", kind: .directory, effectiveBytes: 500,
            isExpanded: true, children: plainPage(200, level3)
        )
        var level1Children: [TreemapHierarchyNode] = [level2]
        for index in 0..<4 { level1Children.append(file(UInt64(120 + index), 200)) }
        let level1 = TreemapHierarchyNode(
            nodeID: NodeID(100), name: "d1", kind: .directory, effectiveBytes: 2_000,
            isExpanded: true, children: plainPage(100, level1Children)
        )
        var focusChildren: [TreemapHierarchyNode] = [level1]
        for index in 0..<6 { focusChildren.append(file(UInt64(10 + index), 1_000)) }

        let overview = TreemapHierarchyComposer.snapshot(
            makeHierarchy(plainPage(1, focusChildren)), key: makeKey(mode: .overview), bounds: bounds
        )
        #expect(overview.tiles.allSatisfy { $0.depth <= 2 })

        let detail = TreemapHierarchyComposer.snapshot(
            makeHierarchy(plainPage(1, focusChildren)), key: makeKey(mode: .detail), bounds: bounds
        )
        #expect(detail.tiles.allSatisfy { $0.depth <= 3 })
    }

    @Test("A scene never exceeds the drawable tile budget")
    func drawableBudget() {
        var children: [TreemapHierarchyNode] = []
        for index in 0..<500 {
            let nodeID = UInt64(1_000 + index)
            var grand: [TreemapHierarchyNode] = []
            for sub in 0..<10 {
                grand.append(file(nodeID * 1_000 + UInt64(sub), UInt64(1_000 - sub)))
            }
            children.append(
                TreemapHierarchyNode(
                    nodeID: NodeID(nodeID),
                    name: "dir-\(index)",
                    kind: .directory,
                    effectiveBytes: UInt64(10_000 - index),
                    isExpanded: true,
                    children: plainPage(nodeID, grand)
                )
            )
        }
        let snapshot = TreemapHierarchyComposer.snapshot(
            makeHierarchy(plainPage(1, children)),
            key: makeKey(mode: .detail),
            bounds: bounds
        )
        #expect(snapshot.tiles.count <= TreemapHierarchyComposer.maximumDrawableTiles)
    }

    @Test("Other identity is unique per parent and never collides with a node")
    func otherIdentity() {
        var focusChildren: [TreemapHierarchyNode] = []
        var nestedChildren: [TreemapHierarchyNode] = []
        for index in 0..<9 {
            nestedChildren.append(file(UInt64(index + 100), 1_000))
        }
        let expanded = TreemapHierarchyNode(
            nodeID: NodeID(2),
            name: "dir",
            kind: .directory,
            effectiveBytes: 20_000,
            isExpanded: true,
            children: makePage(2, nestedChildren, omittedCount: 7, omittedWeight: 5_000)
        )
        focusChildren.append(expanded)
        for index in 0..<9 {
            focusChildren.append(file(UInt64(index + 3), 1_000))
        }
        let page = makePage(1, focusChildren, omittedCount: 4, omittedWeight: 3_000)
        let snapshot = TreemapHierarchyComposer.snapshot(
            makeHierarchy(page), key: makeKey(), bounds: bounds
        )
        let others = snapshot.tiles.filter(\.isOther)
        #expect(!others.isEmpty)
        let parents = others.map(\.parentID)
        #expect(Set(parents).count == others.count)
        for other in others {
            guard case .other(let parent) = other.identity else {
                Issue.record("expected other identity")
                continue
            }
            #expect(parent == other.parentID)
        }
    }

    @Test("The composer is deterministic under reversed input")
    func determinism() {
        var nodes: [TreemapHierarchyNode] = []
        for index in 0..<40 {
            nodes.append(file(UInt64(index + 2), UInt64(500 + (index * 37) % 400)))
        }
        let first = TreemapHierarchyComposer.snapshot(
            makeHierarchy(plainPage(1, nodes)), key: makeKey(), bounds: bounds
        )
        let shuffled = TreemapHierarchyComposer.snapshot(
            makeHierarchy(plainPage(1, nodes.reversed())), key: makeKey(), bounds: bounds
        )
        #expect(first.tiles == shuffled.tiles)
    }

    @Test("Zero weights produce no visible area but do not crash")
    func zeroWeights() {
        let children: [TreemapHierarchyNode] = [file(2, 0), file(3, 0), file(4, 1_000)]
        let snapshot = TreemapHierarchyComposer.snapshot(
            makeHierarchy(plainPage(1, children)), key: makeKey(), bounds: bounds
        )
        for tile in snapshot.tiles where tile.effectiveBytes == 0 {
            #expect(tile.rect.area == 0)
        }
    }

    @Test("Extreme aspect ratios stay finite and contained")
    func extremeAspect() {
        let wide = TreemapRect(x: 0, y: 0, width: 4_000, height: 4)
        var children: [TreemapHierarchyNode] = []
        for index in 0..<30 {
            children.append(file(UInt64(index + 2), UInt64(1 + index)))
        }
        let snapshot = TreemapHierarchyComposer.snapshot(
            makeHierarchy(plainPage(1, children)), key: makeKey(), bounds: wide
        )
        for tile in snapshot.tiles {
            #expect(tile.rect.width.isFinite)
            #expect(tile.rect.height.isFinite)
            #expect(tile.rect.isContained(in: wide, tolerance: 1e-6))
        }
    }

    @Test("Unknown omitted weight is reported but never drawn as fake area")
    func unknownOmitted() {
        let children: [TreemapHierarchyNode] = [file(2, 1_000), file(3, 500)]
        let snapshot = TreemapHierarchyComposer.snapshot(
            makeHierarchy(makePage(1, children, omittedCount: 9, omittedWeight: nil)),
            key: makeKey(),
            bounds: bounds
        )
        #expect(snapshot.hiddenOmittedCount == 9)
        #expect(snapshot.tiles.filter(\.isOther).isEmpty)
    }

    @Test("Unknown omitted count is not mixed into a known-weight other tile")
    func unknownOmittedWithCollapsedItems() throws {
        // Fifty just-below-threshold items aggregate into a visible other tile
        // (about 10% of the area), plus one large visible item.
        let small = TreemapRect(x: 0, y: 0, width: 100, height: 100)
        var children: [TreemapHierarchyNode] = [file(2, 900_000)]
        for index in 0..<50 {
            children.append(file(UInt64(index + 10), 2_000))
        }
        let snapshot = TreemapHierarchyComposer.snapshot(
            makeHierarchy(makePage(1, children, omittedCount: 9, omittedWeight: nil)),
            key: makeKey(),
            bounds: small
        )
        #expect(snapshot.hiddenOmittedCount == 9)
        let other = try #require(snapshot.tiles.first { $0.isOther })
        // The tile's weight only covers the fifty collapsed loaded items, so
        // its count must be 50, not 59.
        #expect(other.collapsedCount == 50)
        #expect(other.effectiveBytes == 100_000)
    }

    @Test("Known omitted weight keeps the full other count")
    func knownOmittedWithCollapsedItems() throws {
        let small = TreemapRect(x: 0, y: 0, width: 100, height: 100)
        var children: [TreemapHierarchyNode] = [file(2, 900_000)]
        for index in 0..<50 {
            children.append(file(UInt64(index + 10), 2_000))
        }
        let snapshot = TreemapHierarchyComposer.snapshot(
            makeHierarchy(makePage(1, children, omittedCount: 9, omittedWeight: 500)),
            key: makeKey(),
            bounds: small
        )
        let other = try #require(snapshot.tiles.first { $0.isOther })
        #expect(other.collapsedCount == 59)
        #expect(other.effectiveBytes == 100_500)
        #expect(snapshot.hiddenOmittedCount == 0)
    }
}
