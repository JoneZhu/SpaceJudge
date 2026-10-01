import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeTreemap

@Suite("Tile header geometry")
struct TileHeaderGeometryTests {
    // MARK: Pure chrome geometry

    @Test("A normal expanded tile reserves at least one text line")
    func headerReservesOneLine() {
        let header = TreemapTileChrome.headerHeight(tileWidth: 300, tileHeight: 200)
        #expect(header >= TreemapTileChrome.oneLineHeaderHeight)
        #expect(header <= TreemapTileChrome.twoLineHeaderHeight)
    }

    @Test("A narrow but tall tile reserves two lines")
    func narrowTallReservesTwoLines() {
        let header = TreemapTileChrome.headerHeight(tileWidth: 100, tileHeight: 300)
        #expect(header == TreemapTileChrome.twoLineHeaderHeight)
    }

    @Test("A wide tile shows the size inline and reserves one line")
    func wideUsesInlineSize() throws {
        let rect = TreemapRect(x: 0, y: 0, width: 400, height: 300)
        let layout = try #require(TreemapTileChrome.textLayout(tileRect: rect, isExpanded: true))
        #expect(layout.sizeIsInline)
        #expect(TreemapTileChrome.headerHeight(tileWidth: 400, tileHeight: 300)
            == TreemapTileChrome.oneLineHeaderHeight)
    }

    @Test("A header never exceeds its fraction of the tile")
    func headerFractionBounded() {
        for height in [4.0, 10.0, 20.0, 40.0, 100.0, 1_000.0] {
            let header = TreemapTileChrome.headerHeight(tileWidth: 200, tileHeight: height)
            #expect(header <= height * TreemapTileChrome.maximumHeaderFraction + 1e-9)
            #expect(header >= 0)
        }
    }

    @Test("Expanded title labels stay inside the reserved header band")
    func labelsInsideHeader() throws {
        let rect = TreemapRect(x: 10, y: 20, width: 260, height: 220)
        let header = TreemapTileChrome.headerHeight(tileWidth: rect.width, tileHeight: rect.height)
        let layout = try #require(TreemapTileChrome.textLayout(tileRect: rect, isExpanded: true))
        let band = TreemapRect(x: rect.x, y: rect.y, width: rect.width, height: header)
        #expect(layout.clipRegion.height == header)
        #expect(layout.nameRect.isContained(in: band, tolerance: 1e-6))
        if let sizeRect = layout.sizeRect {
            #expect(sizeRect.isContained(in: band, tolerance: 1e-6))
            // The two lines must not overlap.
            #expect(layout.nameRect.intersectionArea(with: sizeRect) <= 1e-6)
        }
    }

    @Test("A height that fits only one line omits the size line")
    func oneLineOnlyOmitsSize() throws {
        let header = TreemapTileChrome.oneLineHeaderHeight
        let rect = TreemapRect(x: 0, y: 0, width: 100, height: header / TreemapTileChrome.maximumHeaderFraction)
        let layout = try #require(TreemapTileChrome.textLayout(tileRect: rect, isExpanded: true))
        #expect(layout.sizeRect == nil)
        #expect(layout.nameRect.isContained(in: rect, tolerance: 1e-6))
    }

    @Test("A tile too short for a legible name draws no text")
    func shortTileHasNoText() {
        let rect = TreemapRect(x: 0, y: 0, width: 300, height: 8)
        #expect(TreemapTileChrome.textLayout(tileRect: rect, isExpanded: true) == nil)
    }

    @Test("A tile too narrow for a name draws no text")
    func narrowTileHasNoText() {
        let rect = TreemapRect(x: 0, y: 0, width: 30, height: 200)
        #expect(TreemapTileChrome.textLayout(tileRect: rect, isExpanded: true) == nil)
    }

    @Test("A leaf tile can use its whole height for labels")
    func leafUsesWholeTile() throws {
        let rect = TreemapRect(x: 0, y: 0, width: 200, height: 60)
        let layout = try #require(TreemapTileChrome.textLayout(tileRect: rect, isExpanded: false))
        #expect(layout.clipRegion.height == rect.height)
        #expect(layout.nameRect.isContained(in: rect, tolerance: 1e-6))
    }

    // MARK: Composer integration

    private func file(_ id: UInt64, _ weight: UInt64) -> TreemapHierarchyNode {
        TreemapHierarchyNode(
            nodeID: NodeID(id), name: "file-\(id)", kind: .regularFile, effectiveBytes: weight
        )
    }

    private func page(_ parent: UInt64, _ children: [TreemapHierarchyNode]) -> TreemapHierarchyPage {
        TreemapHierarchyPage(parentID: NodeID(parent), children: children)
    }

    @Test("Expanded children never intrude into the parent title header")
    func childrenStartBelowHeader() throws {
        var grandChildren: [TreemapHierarchyNode] = []
        for index in 0..<8 {
            grandChildren.append(file(UInt64(100 + index), UInt64(400 - index * 10)))
        }
        let expanded = TreemapHierarchyNode(
            nodeID: NodeID(2), name: "expanded-directory", kind: .directory,
            effectiveBytes: 4_000, isExpanded: true, children: page(2, grandChildren)
        )
        var children: [TreemapHierarchyNode] = [expanded]
        for index in 0..<6 { children.append(file(UInt64(10 + index), UInt64(900 - index * 30))) }
        let hierarchy = TreemapHierarchy(
            focus: TreemapHierarchyNode(
                nodeID: NodeID(1), name: "root", kind: .directory,
                effectiveBytes: 10_000, isExpanded: true, children: page(1, children)
            )
        )
        let key = TreemapLayoutKey(
            scanGeneration: 1,
            scanID: ScanID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!),
            focusNodeID: NodeID(1),
            sceneRevision: Revision(1),
            expansionVersion: 1,
            detailMode: .detail,
            width: 1_000,
            height: 700,
            backingScale: 2
        )
        let snapshot = TreemapHierarchyComposer.snapshot(
            hierarchy, key: key, bounds: TreemapRect(x: 0, y: 0, width: 1_000, height: 700)
        )
        let parent = try #require(
            snapshot.tiles.first { $0.identity == TreemapRenderTile.Identity.node(NodeID(2)) }
        )
        let content = try #require(parent.contentRect)
        let reserved = content.minY - parent.rect.minY
        // The composer reserves padding plus the shared header band; it must be
        // at least the shared header height.
        let expected = TreemapTileChrome.headerHeight(
            tileWidth: parent.rect.width, tileHeight: parent.rect.height
        )
        #expect(reserved >= expected - 1e-6)
        // Every nested tile starts below the title band.
        let headerBand = TreemapRect(
            x: parent.rect.x, y: parent.rect.y, width: parent.rect.width, height: expected
        )
        let nested = snapshot.tiles.filter { $0.depth == 2 && $0.parentID == NodeID(2) }
        #expect(!nested.isEmpty)
        for tile in nested {
            #expect(tile.rect.minY >= headerBand.maxY - 1e-6)
            #expect(headerBand.intersectionArea(with: tile.rect) <= 1e-6)
        }
        // The title layout also stays inside that band.
        let layout = try #require(
            TreemapTileChrome.textLayout(tileRect: parent.rect, isExpanded: true)
        )
        #expect(layout.nameRect.maxY <= headerBand.maxY + 1e-6)
    }
}
