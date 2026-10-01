import AppKit
import CoreGraphics
import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeTreemap
import SpaceJudgeTreemapUI

@Suite("Tile header rendering")
struct TileHeaderRenderTests {
    private func expandedTile(
        id: UInt64,
        rect: TreemapRect,
        contentRect: TreemapRect,
        palette: Int
    ) -> TreemapRenderTile {
        TreemapRenderTile(
            identity: .node(NodeID(id)),
            parentID: NodeID(1),
            rect: rect,
            contentRect: contentRect,
            depth: 1,
            paletteIndex: palette,
            displayName: "dir-\(id)",
            effectiveBytes: UInt64(max(0, rect.area)),
            kind: .directory,
            isExpanded: true
        )
    }

    @Test("The header band is drawn and uses the directory group color")
    func headerBandIsCoordinated() {
        let bounds = TreemapRect(x: 0, y: 0, width: 400, height: 200)
        let rectA = TreemapRect(x: 0, y: 0, width: 200, height: 200)
        let contentA = TreemapRect(x: 5, y: 60, width: 190, height: 135)
        let rectB = TreemapRect(x: 200, y: 0, width: 200, height: 200)
        let contentB = TreemapRect(x: 205, y: 60, width: 190, height: 135)
        let tiles = [
            expandedTile(id: 2, rect: rectA, contentRect: contentA, palette: 0),
            expandedTile(id: 3, rect: rectB, contentRect: contentB, palette: 1)
        ]
        let snapshot = UITestSupport.snapshot(tiles: tiles, bounds: bounds)
        let context = UITestSupport.makeContext(width: 400, height: 200)
        TreemapRenderer().render(
            snapshot: snapshot,
            in: context,
            dirtyRect: nil,
            options: TreemapRenderer.Options(appearance: .light, drawsText: false)
        )

        // Header pixels (inside each reserved band) must differ between the two
        // palette groups, so the header is not a single shared color.
        let headerA = UITestSupport.pixel(context, x: 100, y: 20)
        let headerB = UITestSupport.pixel(context, x: 300, y: 20)
        #expect(headerA != headerB)

        // The header band is visibly distinct from the tile's own fill below it.
        let fillA = UITestSupport.pixel(context, x: 100, y: 190)
        #expect(headerA != fillA)
    }

    @Test("A nested child is painted below the parent header band")
    func childBelowHeader() {
        let bounds = TreemapRect(x: 0, y: 0, width: 300, height: 200)
        let parent = expandedTile(
            id: 2,
            rect: TreemapRect(x: 0, y: 0, width: 300, height: 200),
            contentRect: TreemapRect(x: 5, y: 60, width: 290, height: 135),
            palette: 0
        )
        let child = TreemapRenderTile(
            identity: .node(NodeID(10)),
            parentID: NodeID(2),
            rect: TreemapRect(x: 6, y: 61, width: 288, height: 133),
            depth: 2,
            paletteIndex: 3,
            displayName: "child",
            effectiveBytes: 1_000,
            kind: .regularFile
        )
        let snapshot = UITestSupport.snapshot(tiles: [parent, child], bounds: bounds)
        let context = UITestSupport.makeContext(width: 300, height: 200)
        TreemapRenderer().render(
            snapshot: snapshot,
            in: context,
            dirtyRect: nil,
            options: TreemapRenderer.Options(appearance: .light, drawsText: false)
        )
        // Header area keeps the parent's header color; the child's area uses the
        // child's own color.
        let headerPixel = UITestSupport.pixel(context, x: 150, y: 20)
        let childPixel = UITestSupport.pixel(context, x: 150, y: 150)
        #expect(headerPixel != childPixel)
    }
}
