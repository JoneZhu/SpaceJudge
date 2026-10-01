import AppKit
import CoreGraphics
import CoreText
import Foundation
import SpaceJudgeTreemap

/// Light or dark rendering target. The canvas resolves `NSAppearance` to this
/// value so the pure renderer never depends on the current application
/// appearance.
public enum TreemapAppearance: String, Sendable, Equatable, Hashable, Codable {
    case light
    case dark

    public var isDark: Bool { self == .dark }
}

/// RGBA color independent of AppKit.
public struct TreemapColor: Sendable, Equatable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Linear blend toward `other`.
    public func blended(with other: TreemapColor, fraction: Double) -> TreemapColor {
        let t = min(max(fraction, 0), 1)
        return TreemapColor(
            red + (other.red - red) * t,
            green + (other.green - green) * t,
            blue + (other.blue - blue) * t,
            alpha + (other.alpha - alpha) * t
        )
    }
}

/// Deterministic palette used by both the app canvas and the benchmark.
public enum TreemapPalette {
    /// Six soft, low-saturation directory colors in a fixed order:
    /// pale green, pale blue, pale sand, pale violet, pale peach, pale gray-green.
    public static let base: [TreemapColor] = [
        TreemapColor(0.855, 0.910, 0.875),
        TreemapColor(0.865, 0.907, 0.944),
        TreemapColor(0.934, 0.900, 0.848),
        TreemapColor(0.899, 0.888, 0.941),
        TreemapColor(0.938, 0.889, 0.851),
        TreemapColor(0.892, 0.925, 0.858)
    ]

    /// Independently tuned dark colors (deeper and desaturated, not inverted).
    public static let baseDark: [TreemapColor] = [
        TreemapColor(0.153, 0.278, 0.208),
        TreemapColor(0.157, 0.243, 0.333),
        TreemapColor(0.318, 0.275, 0.192),
        TreemapColor(0.263, 0.231, 0.365),
        TreemapColor(0.345, 0.255, 0.184),
        TreemapColor(0.196, 0.286, 0.224)
    ]

    public static let otherLight = TreemapColor(0.78, 0.79, 0.79)
    public static let otherDark = TreemapColor(0.24, 0.25, 0.26)

    public static func background(_ appearance: TreemapAppearance) -> TreemapColor {
        appearance == .light ? TreemapColor(0.965, 0.968, 0.962) : TreemapColor(0.10, 0.105, 0.102)
    }

    /// Strong, clearly readable gray-green name color.
    public static func text(_ appearance: TreemapAppearance) -> TreemapColor {
        appearance == .light
            ? TreemapColor(0.145, 0.255, 0.196)
            : TreemapColor(0.878, 0.933, 0.886)
    }

    /// One step weaker gray-green for the size line.
    public static func secondaryText(_ appearance: TreemapAppearance) -> TreemapColor {
        appearance == .light
            ? TreemapColor(0.145, 0.255, 0.196).blended(
                with: TreemapColor(0.46, 0.52, 0.48), fraction: 0.5
            )
            : TreemapColor(0.878, 0.933, 0.886).blended(
                with: TreemapColor(0.52, 0.58, 0.54), fraction: 0.45
            )
    }

    public static let accent = TreemapColor(0.20, 0.66, 0.42)

    /// Fill color for one tile.
    public static func fill(
        paletteIndex: Int,
        depth: Int,
        isOther: Bool,
        appearance: TreemapAppearance
    ) -> TreemapColor {
        if isOther {
            return appearance == .light ? otherLight : otherDark
        }
        let colors = appearance == .light ? base : baseDark
        let index = ((paletteIndex % colors.count) + colors.count) % colors.count
        let baseColor = colors[index]
        guard depth > 1 else { return baseColor }
        // Descendants keep their top-level hue and step slightly lighter/deeper.
        let target = appearance == .light
            ? TreemapColor(1, 1, 1)
            : TreemapColor(0, 0, 0)
        let amount = min(0.12 * Double(depth - 1), 0.36)
        return baseColor.blended(with: target, fraction: amount)
    }

    /// Thin, light border color for the fill.
    public static func stroke(
        paletteIndex: Int,
        depth: Int,
        isOther: Bool,
        appearance: TreemapAppearance
    ) -> TreemapColor {
        let fill = fill(
            paletteIndex: paletteIndex,
            depth: depth,
            isOther: isOther,
            appearance: appearance
        )
        let target = appearance == .light
            ? TreemapColor(0.30, 0.36, 0.33)
            : TreemapColor(0.90, 0.94, 0.91)
        return fill.blended(with: target, fraction: appearance == .light ? 0.16 : 0.14)
    }

    /// Header band color: coordinated with the directory group, not a single
    /// shared green.
    public static func header(
        paletteIndex: Int,
        depth: Int,
        isOther: Bool,
        appearance: TreemapAppearance
    ) -> TreemapColor {
        let fill = fill(
            paletteIndex: paletteIndex,
            depth: depth,
            isOther: isOther,
            appearance: appearance
        )
        let stroke = stroke(
            paletteIndex: paletteIndex,
            depth: depth,
            isOther: isOther,
            appearance: appearance
        )
        return fill.blended(with: stroke, fraction: 0.5)
    }
}

/// Stateless Core Graphics renderer shared by the AppKit canvas and the
/// Release benchmark.
///
/// The renderer assumes a context whose coordinate origin is the top-left
/// corner with `y` growing downwards (the same convention as a flipped
/// `NSView`). Callers drawing into a raw bitmap context must apply that flip
/// transform first.
///
/// Fills and strokes are batched by `(depth, palette)` so a 2,000-tile scene
/// costs a few dozen `CGContext` state changes instead of two per tile. Colors
/// and fonts are resolved once per call. Batching is emitted in ascending depth
/// order so nested children always paint over their parents.
///
/// Text is the exception: every label is clipped to the tile (or its reserved
/// header band for expanded directories), so a parent title can never bleed
/// into a child tile even though labels are drawn after all fills.
public struct TreemapRenderer: Sendable {
    public struct Options: Sendable, Equatable {
        public var appearance: TreemapAppearance
        public var selected: TreemapRenderTile.Identity?
        public var hovered: TreemapRenderTile.Identity?
        public var drawsText: Bool

        public init(
            appearance: TreemapAppearance = .light,
            selected: TreemapRenderTile.Identity? = nil,
            hovered: TreemapRenderTile.Identity? = nil,
            drawsText: Bool = true
        ) {
            self.appearance = appearance
            self.selected = selected
            self.hovered = hovered
            self.drawsText = drawsText
        }
    }

    /// Maximum depth whose blended colors are cached.
    static let cachedDepthCount = 6
    /// Palette slots per depth (six colors plus the "other" slot).
    static let slotsPerDepth = TreemapPalette.base.count + 1

    public init() {}

    /// Draws every tile intersecting `dirtyRect` (or the whole snapshot when
    /// `dirtyRect` is `nil`).
    public func render(
        snapshot: TreemapRenderSnapshot,
        in context: CGContext,
        dirtyRect: CGRect?,
        options: Options
    ) {
        let full = CGRect(
            x: snapshot.bounds.x,
            y: snapshot.bounds.y,
            width: snapshot.bounds.width,
            height: snapshot.bounds.height
        )
        let clip = dirtyRect ?? full
        let palette = ResolvedPalette(appearance: options.appearance)

        context.saveGState()
        // Guaranteed restore on every path (including the early return below),
        // so the dirty-rect clip never leaks into the caller's context.
        defer { context.restoreGState() }
        context.clip(to: clip)
        context.setFillColor(palette.background)
        context.fill(clip)

        var maximumDepth = 1
        for tile in snapshot.tiles {
            maximumDepth = max(maximumDepth, min(tile.depth, Self.cachedDepthCount))
        }
        let bucketCount = maximumDepth * Self.slotsPerDepth
        var fillPaths = [CGMutablePath?](repeating: nil, count: bucketCount)
        var headerPaths = [CGMutablePath?](repeating: nil, count: bucketCount)
        var strokeWidths = [CGFloat](repeating: 0, count: bucketCount)
        let hoverPath = CGMutablePath()
        var hoverHasContent = false
        let selectedPath = CGMutablePath()
        var selectedHasContent = false
        var labels: [(tile: TreemapRenderTile, layout: TreemapTileChrome.TextLayout)] = []

        for tile in snapshot.tiles {
            let rect = tile.rect
            guard rect.width > 0, rect.height > 0 else { continue }
            let cgRect = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            guard cgRect.intersects(clip) else { continue }

            let depthIndex = min(max(tile.depth, 1), Self.cachedDepthCount) - 1
            let slot = tile.isOther ? TreemapPalette.base.count : (tile.paletteIndex % TreemapPalette.base.count)
            let bucket = depthIndex * Self.slotsPerDepth + slot
            let path = fillPaths[bucket] ?? CGMutablePath()
            Self.addShape(to: path, rect: cgRect)
            fillPaths[bucket] = path
            strokeWidths[bucket] = 1

            // An expanded directory reserves a header; the band is filled with
            // the group's own coordinated color, never a shared green.
            if tile.isExpanded, let content = tile.contentRect {
                let headerHeight = max(0, CGFloat(content.y) - cgRect.minY)
                if headerHeight > 1 {
                    let headerPath = headerPaths[bucket] ?? CGMutablePath()
                    Self.addHeaderShape(
                        to: headerPath,
                        rect: CGRect(
                            x: cgRect.minX, y: cgRect.minY,
                            width: cgRect.width, height: headerHeight
                        )
                    )
                    headerPaths[bucket] = headerPath
                }
            }
            if options.hovered == tile.identity {
                Self.addShape(to: hoverPath, rect: cgRect)
                hoverHasContent = true
            }
            if options.selected == tile.identity {
                Self.addShape(to: selectedPath, rect: cgRect)
                selectedHasContent = true
            }
            if options.drawsText, let layout = palette.textLayout(for: tile) {
                labels.append((tile, layout))
            }
        }

        for depthIndex in 0..<maximumDepth {
            let base = depthIndex * Self.slotsPerDepth
            for slot in 0..<Self.slotsPerDepth {
                let bucket = base + slot
                guard let path = fillPaths[bucket] else { continue }
                context.addPath(path)
                context.setFillColor(palette.fill(slot: slot, depthIndex: depthIndex))
                context.fillPath()
            }
        }
        for depthIndex in 0..<maximumDepth {
            let base = depthIndex * Self.slotsPerDepth
            for slot in 0..<Self.slotsPerDepth {
                let bucket = base + slot
                guard let path = headerPaths[bucket] else { continue }
                context.addPath(path)
                context.setFillColor(palette.header(slot: slot, depthIndex: depthIndex))
                context.fillPath()
            }
        }
        for depthIndex in 0..<maximumDepth {
            let base = depthIndex * Self.slotsPerDepth
            for slot in 0..<Self.slotsPerDepth {
                let bucket = base + slot
                guard let path = fillPaths[bucket] else { continue }
                context.addPath(path)
                context.setStrokeColor(palette.stroke(slot: slot, depthIndex: depthIndex))
                context.setLineWidth(strokeWidths[bucket])
                context.strokePath()
            }
        }
        if hoverHasContent {
            context.addPath(hoverPath)
            context.setFillColor(palette.hover)
            context.fillPath()
        }
        if selectedHasContent {
            context.addPath(selectedPath)
            context.setStrokeColor(palette.accent)
            context.setLineWidth(2)
            context.strokePath()
        }

        guard options.drawsText, !labels.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for label in labels {
            drawLabel(label.tile, layout: label.layout, palette: palette, context: context)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func addShape(to path: CGMutablePath, rect: CGRect) {
        let minSide = min(rect.width, rect.height)
        let radius = min(CGFloat(TreemapTileChrome.cornerRadius), minSide / 4)
        // Small tiles drop the rounded corners entirely: square rects rasterize
        // much faster and the visual difference is negligible below ~28 pt.
        if radius >= 0.75, minSide >= 28 {
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        } else {
            path.addRect(rect)
        }
    }

    /// A header band whose top corners match the tile radius and whose bottom
    /// edge is square, so it reads as a band rather than a floating pill.
    private static func addHeaderShape(to path: CGMutablePath, rect: CGRect) {
        let minSide = min(rect.width, rect.height)
        let radius = min(CGFloat(TreemapTileChrome.cornerRadius), max(0, minSide / 4))
        guard radius >= 0.75, rect.width >= 28 else {
            path.addRect(rect)
            return
        }
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
    }

    private func drawLabel(
        _ tile: TreemapRenderTile,
        layout: TreemapTileChrome.TextLayout,
        palette: ResolvedPalette,
        context: CGContext
    ) {
        // Each label is clipped to its own region so a parent title can never
        // draw over its children.
        context.saveGState()
        context.clip(to: CGRect(
            x: layout.clipRegion.x,
            y: layout.clipRegion.y,
            width: layout.clipRegion.width,
            height: layout.clipRegion.height
        ))

        palette.nameString(tile.displayName).draw(
            with: Self.cgRect(layout.nameRect),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            context: nil
        )
        if let sizeRect = layout.sizeRect {
            let text = ByteFormattingShort.bytes(tile.effectiveBytes)
            let attributed = palette.sizeString(text)
            if layout.sizeIsInline {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .right
                paragraph.lineBreakMode = .byTruncatingTail
                let aligned = NSMutableAttributedString(attributedString: attributed)
                aligned.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: 0, length: aligned.length)
                )
                aligned.draw(
                    with: Self.cgRect(sizeRect),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    context: nil
                )
            } else {
                attributed.draw(
                    with: Self.cgRect(sizeRect),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    context: nil
                )
            }
        }
        context.restoreGState()
    }

    private static func cgRect(_ rect: TreemapRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: max(0, rect.width), height: max(0, rect.height))
    }

    /// Pre-resolved colors and fonts for one appearance, built once per render.
    final class ResolvedPalette {
        let background: CGColor
        let accent = TreemapPalette.accent.cgColor
        let hover: CGColor
        private var fills: [CGColor] = []
        private var strokes: [CGColor] = []
        private var headers: [CGColor] = []

        private let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        private let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        private var nameAttributes: [NSAttributedString.Key: Any] = [:]
        private var sizeAttributes: [NSAttributedString.Key: Any] = [:]

        init(appearance: TreemapAppearance) {
            background = TreemapPalette.background(appearance).cgColor
            hover = (appearance == .light
                ? TreemapColor(0, 0, 0, 0.07)
                : TreemapColor(1, 1, 1, 0.10)).cgColor

            let count = TreemapPalette.base.count
            for depth in 1...TreemapRenderer.cachedDepthCount {
                for index in 0..<count {
                    fills.append(
                        TreemapPalette.fill(
                            paletteIndex: index, depth: depth, isOther: false, appearance: appearance
                        ).cgColor
                    )
                }
                fills.append(
                    TreemapPalette.fill(
                        paletteIndex: 0, depth: depth, isOther: true, appearance: appearance
                    ).cgColor
                )
                for index in 0..<count {
                    strokes.append(
                        TreemapPalette.stroke(
                            paletteIndex: index, depth: depth, isOther: false, appearance: appearance
                        ).cgColor
                    )
                }
                strokes.append(
                    TreemapPalette.stroke(
                        paletteIndex: 0, depth: depth, isOther: true, appearance: appearance
                    ).cgColor
                )
                for index in 0..<count {
                    headers.append(
                        TreemapPalette.header(
                            paletteIndex: index, depth: depth, isOther: false, appearance: appearance
                        ).cgColor
                    )
                }
                headers.append(
                    TreemapPalette.header(
                        paletteIndex: 0, depth: depth, isOther: true, appearance: appearance
                    ).cgColor
                )
            }

            nameAttributes = [
                .font: nameFont,
                .foregroundColor: TreemapPalette.text(appearance).nsColor
            ]
            sizeAttributes = [
                .font: sizeFont,
                .foregroundColor: TreemapPalette.secondaryText(appearance).nsColor
            ]
        }

        /// `slot` is `0..<6` for palette groups and `6` for "other".
        func fill(slot: Int, depthIndex: Int) -> CGColor {
            fills[depthIndex * TreemapRenderer.slotsPerDepth + slot]
        }

        func stroke(slot: Int, depthIndex: Int) -> CGColor {
            strokes[depthIndex * TreemapRenderer.slotsPerDepth + slot]
        }

        func header(slot: Int, depthIndex: Int) -> CGColor {
            headers[depthIndex * TreemapRenderer.slotsPerDepth + slot]
        }

        /// Text layout for a tile. Expanded directories keep their title inside
        /// the reserved header; leaves use the whole tile.
        func textLayout(for tile: TreemapRenderTile) -> TreemapTileChrome.TextLayout? {
            TreemapTileChrome.textLayout(
                tileRect: tile.rect,
                isExpanded: tile.contentRect != nil
            )
        }

        func nameString(_ value: String) -> NSAttributedString {
            NSAttributedString(string: value, attributes: nameAttributes)
        }

        func sizeString(_ value: String) -> NSAttributedString {
            NSAttributedString(string: value, attributes: sizeAttributes)
        }
    }
}

/// Tiny path-free byte formatter shared with the canvas tooltip.
public enum ByteFormattingShort {
    public static func bytes(_ value: UInt64) -> String {
        let units: [(threshold: Double, suffix: String)] = [
            (1_000_000_000_000, "TB"),
            (1_000_000_000, "GB"),
            (1_000_000, "MB"),
            (1_000, "KB")
        ]
        let doubleValue = Double(value)
        for unit in units where doubleValue >= unit.threshold {
            let scaled = doubleValue / unit.threshold
            let text = scaled >= 10 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
            return "\(text) \(unit.suffix)"
        }
        return "\(value) B"
    }
}
