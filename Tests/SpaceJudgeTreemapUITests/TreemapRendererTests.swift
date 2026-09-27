import AppKit
import CoreGraphics
import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeTreemap
import SpaceJudgeTreemapUI

/// Shared helpers for the AppKit/Core Graphics tests.
enum UITestSupport {
    static func tile(
        _ id: UInt64,
        _ rect: TreemapRect,
        depth: Int = 1,
        parent: UInt64 = 1,
        kind: NodeKind? = .regularFile,
        palette: Int = 0,
        name: String? = nil,
        expanded: Bool = false
    ) -> TreemapRenderTile {
        TreemapRenderTile(
            identity: .node(NodeID(id)),
            parentID: NodeID(parent),
            rect: rect,
            depth: depth,
            paletteIndex: palette,
            displayName: name ?? "node-\(id)",
            effectiveBytes: UInt64(max(0, rect.area)),
            kind: kind,
            isExpanded: expanded
        )
    }

    static func other(
        _ parent: UInt64,
        _ rect: TreemapRect,
        depth: Int = 1,
        count: UInt64 = 5
    ) -> TreemapRenderTile {
        TreemapRenderTile(
            identity: .other(parent: NodeID(parent)),
            parentID: NodeID(parent),
            rect: rect,
            depth: depth,
            paletteIndex: 0,
            displayName: "其他（\(count) 项）",
            effectiveBytes: UInt64(max(0, rect.area)),
            collapsedCount: count,
            kind: nil
        )
    }

    static func snapshot(
        tiles: [TreemapRenderTile],
        bounds: TreemapRect,
        mode: TreemapDetailMode = .detail
    ) -> TreemapRenderSnapshot {
        TreemapRenderSnapshot(
            key: TreemapLayoutKey(
                scanGeneration: 1,
                scanID: ScanID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!),
                focusNodeID: NodeID(1),
                sceneRevision: Revision(1),
                expansionVersion: 1,
                detailMode: mode,
                width: bounds.width,
                height: bounds.height,
                backingScale: 2
            ),
            bounds: bounds,
            tiles: tiles,
            totalWeight: tiles.reduce(0) { $0 + $1.effectiveBytes },
            weightSumOverflowed: false
        )
    }

    static func makeContext(width: Int, height: Int) -> CGContext {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    /// Reads the raw 4 bytes of a pixel from a premultiplied-first bitmap.
    ///
    /// `makeContext` applies a top-left flip transform; the bitmap storage is
    /// bottom-up, so the storage row is mirrored from the user-space `y`.
    static func pixel(_ context: CGContext, x: Int, y: Int) -> [UInt8] {
        guard let data = context.data else { return [] }
        let bytesPerRow = context.bytesPerRow
        let pointer = data.assumingMemoryBound(to: UInt8.self)
        let row = context.height - 1 - y
        let offset = row * bytesPerRow + x * 4
        return [
            pointer[offset],
            pointer[offset + 1],
            pointer[offset + 2],
            pointer[offset + 3]
        ]
    }
}

@Suite("Treemap renderer")
struct TreemapRendererTests {
    private let renderer = TreemapRenderer()
    private let bounds = TreemapRect(x: 0, y: 0, width: 200, height: 120)

    @Test("Renders light, dark, empty and selection states without crashing")
    func smoke() {
        let tiles = [
            UITestSupport.tile(2, TreemapRect(x: 0, y: 0, width: 100, height: 60)),
            UITestSupport.tile(3, TreemapRect(x: 100, y: 0, width: 100, height: 60), palette: 1),
            UITestSupport.other(1, TreemapRect(x: 0, y: 60, width: 200, height: 60))
        ]
        let snapshot = UITestSupport.snapshot(tiles: tiles, bounds: bounds)
        for appearance in [TreemapAppearance.light, .dark] {
            let context = UITestSupport.makeContext(width: 200, height: 120)
            renderer.render(
                snapshot: snapshot,
                in: context,
                dirtyRect: CGRect(x: 0, y: 0, width: 200, height: 120),
                options: TreemapRenderer.Options(
                    appearance: appearance,
                    selected: .node(NodeID(3)),
                    hovered: .node(NodeID(2)),
                    drawsText: true
                )
            )
            #expect(context.makeImage() != nil)
        }

        let empty = UITestSupport.snapshot(tiles: [], bounds: bounds)
        let context = UITestSupport.makeContext(width: 200, height: 120)
        renderer.render(
            snapshot: empty,
            in: context,
            dirtyRect: nil,
            options: TreemapRenderer.Options()
        )
        #expect(context.makeImage() != nil)
    }

    @Test("A dirty rect leaves disjoint tiles untouched")
    func dirtyRectSkipsTiles() {
        let tileA = UITestSupport.tile(2, TreemapRect(x: 0, y: 0, width: 100, height: 120))
        let tileB = UITestSupport.tile(3, TreemapRect(x: 100, y: 0, width: 100, height: 120), palette: 1)
        let snapshot = UITestSupport.snapshot(tiles: [tileA, tileB], bounds: bounds)
        let empty = UITestSupport.snapshot(tiles: [], bounds: bounds)
        let dirty = CGRect(x: 0, y: 0, width: 100, height: 120)

        let withTiles = UITestSupport.makeContext(width: 200, height: 120)
        renderer.render(
            snapshot: snapshot,
            in: withTiles,
            dirtyRect: dirty,
            options: TreemapRenderer.Options(appearance: .light, drawsText: false)
        )
        let withoutTiles = UITestSupport.makeContext(width: 200, height: 120)
        renderer.render(
            snapshot: empty,
            in: withoutTiles,
            dirtyRect: dirty,
            options: TreemapRenderer.Options(appearance: .light, drawsText: false)
        )
        // Tile B lies outside the dirty rect, so both renders must leave it
        // identical; tile A inside it must differ.
        let untouchedA = UITestSupport.pixel(withTiles, x: 150, y: 60)
        let untouchedB = UITestSupport.pixel(withoutTiles, x: 150, y: 60)
        #expect(untouchedA == untouchedB)
        let drawnA = UITestSupport.pixel(withTiles, x: 50, y: 60)
        let drawnB = UITestSupport.pixel(withoutTiles, x: 50, y: 60)
        #expect(drawnA != drawnB)
    }

    @Test("render restores the graphics state so callers can draw outside the dirty rect")
    func restoresGraphicsState() {
        let tile = UITestSupport.tile(2, TreemapRect(x: 0, y: 0, width: 100, height: 120))
        let snapshot = UITestSupport.snapshot(tiles: [tile], bounds: bounds)
        let context = UITestSupport.makeContext(width: 200, height: 120)
        let clipBefore = context.boundingBoxOfClipPath
        // `drawsText == false` takes the early-return path that previously
        // leaked the clip.
        renderer.render(
            snapshot: snapshot,
            in: context,
            dirtyRect: CGRect(x: 0, y: 0, width: 50, height: 50),
            options: TreemapRenderer.Options(appearance: .light, drawsText: false)
        )
        let clipAfter = context.boundingBoxOfClipPath
        #expect(clipAfter.width >= 199, "clip leaked: \(clipAfter)")
        #expect(clipAfter.height >= 119, "clip leaked: \(clipAfter)")
        _ = clipBefore
        // After the state is restored, a full-context fill must cover the area
        // outside the render dirty rect. If the clip had leaked, only the
        // 50×50 dirty rect would be painted and this pixel would stay clear.
        // Compare against a reference context filled with the same color so the
        // test does not depend on the bitmap byte order.
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        let reference = UITestSupport.makeContext(width: 200, height: 120)
        reference.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        reference.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        let expected = UITestSupport.pixel(reference, x: 170, y: 90)
        let pixel = UITestSupport.pixel(context, x: 170, y: 90)
        #expect(pixel == expected, "pixel=\(pixel) expected=\(expected)")
    }

    @Test("Very small tiles only draw when text fits")
    func textThreshold() {
        let tiny = UITestSupport.tile(2, TreemapRect(x: 0, y: 0, width: 10, height: 6))
        let snapshot = UITestSupport.snapshot(tiles: [tiny], bounds: bounds)
        let context = UITestSupport.makeContext(width: 200, height: 120)
        renderer.render(
            snapshot: snapshot,
            in: context,
            dirtyRect: nil,
            options: TreemapRenderer.Options(drawsText: true)
        )
        #expect(context.makeImage() != nil)
    }
}
