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
    /// Six low-saturation directory colors in a fixed order.
    public static let base: [TreemapColor] = [
        TreemapColor(0.60, 0.82, 0.66),
        TreemapColor(0.62, 0.78, 0.90),
        TreemapColor(0.88, 0.84, 0.70),
        TreemapColor(0.77, 0.71, 0.88),
        TreemapColor(0.93, 0.79, 0.66),
        TreemapColor(0.72, 0.80, 0.75)
    ]

    public static let baseDark: [TreemapColor] = [
        TreemapColor(0.16, 0.34, 0.23),
        TreemapColor(0.17, 0.31, 0.44),
        TreemapColor(0.40, 0.36, 0.20),
        TreemapColor(0.30, 0.25, 0.44),
        TreemapColor(0.45, 0.30, 0.19),
        TreemapColor(0.24, 0.32, 0.27)
    ]

    public static let otherLight = TreemapColor(0.70, 0.70, 0.72)
    public static let otherDark = TreemapColor(0.30, 0.30, 0.33)

    public static func background(_ appearance: TreemapAppearance) -> TreemapColor {
        appearance == .light ? TreemapColor(0.95, 0.95, 0.96) : TreemapColor(0.10, 0.10, 0.11)
    }

    public static func text(_ appearance: TreemapAppearance) -> TreemapColor {
        appearance == .light ? TreemapColor(0.13, 0.13, 0.15) : TreemapColor(0.93, 0.93, 0.94)
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
        // Descendants keep their top-level hue and step lighter with depth.
        let target = appearance == .light
            ? TreemapColor(1, 1, 1)
            : TreemapColor(0, 0, 0)
        let amount = min(0.18 * Double(depth - 1), 0.5)
        return baseColor.blended(with: target, fraction: amount)
    }

    /// Slightly darker stroke for the fill.
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
            ? TreemapColor(0, 0, 0)
            : TreemapColor(1, 1, 1)
        return fill.blended(with: target, fraction: appearance == .light ? 0.18 : 0.16)
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
        var strokeWidths = [CGFloat](repeating: 0, count: bucketCount)
        let headerPath = CGMutablePath()
        var headerHasContent = false
        let hoverPath = CGMutablePath()
        var hoverHasContent = false
        let selectedPath = CGMutablePath()
        var selectedHasContent = false
        var labels: [(tile: TreemapRenderTile, rect: CGRect)] = []

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

            if tile.isExpanded, let content = tile.contentRect {
                let headerHeight = max(0, CGFloat(content.y) - cgRect.minY)
                if headerHeight > 1 {
                    headerPath.addRect(
                        CGRect(x: cgRect.minX, y: cgRect.minY, width: cgRect.width, height: headerHeight)
                    )
                    headerHasContent = true
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
            if options.drawsText, cgRect.width >= 32, cgRect.height >= 13 {
                labels.append((tile, cgRect))
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
        if headerHasContent {
            context.addPath(headerPath)
            context.setFillColor(palette.header)
            context.fillPath()
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
            drawLabel(label.tile, cgRect: label.rect, palette: palette)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func addShape(to path: CGMutablePath, rect: CGRect) {
        let minSide = min(rect.width, rect.height)
        let radius = min(4.0, minSide / 4)
        // Small tiles drop the rounded corners entirely: square rects rasterize
        // much faster and the visual difference is negligible below ~28 pt.
        if radius >= 0.75, minSide >= 28 {
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        } else {
            path.addRect(rect)
        }
    }

    private func drawLabel(
        _ tile: TreemapRenderTile,
        cgRect: CGRect,
        palette: ResolvedPalette
    ) {
        let nameRect = CGRect(
            x: cgRect.minX + 4,
            y: cgRect.minY + 3,
            width: max(0, cgRect.width - 8),
            height: 13
        )
        palette.nameString(tile.displayName).draw(
            with: nameRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            context: nil
        )
        guard cgRect.height >= 30, cgRect.width >= 96 else { return }
        let sizeRect = CGRect(
            x: cgRect.minX + 4,
            y: cgRect.minY + 16,
            width: max(0, cgRect.width - 8),
            height: 12
        )
        palette.sizeString(ByteFormattingShort.bytes(tile.effectiveBytes)).draw(
            with: sizeRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            context: nil
        )
    }

    /// Pre-resolved colors and fonts for one appearance, built once per render.
    final class ResolvedPalette {
        let background: CGColor
        let header: CGColor
        let accent = TreemapPalette.accent.cgColor
        let hover: CGColor
        private var fills: [CGColor] = []
        private var strokes: [CGColor] = []

        private let nameFont = NSFont.systemFont(ofSize: 11)
        private let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        private var nameAttributes: [NSAttributedString.Key: Any] = [:]
        private var sizeAttributes: [NSAttributedString.Key: Any] = [:]

        init(appearance: TreemapAppearance) {
            background = TreemapPalette.background(appearance).cgColor
            header = TreemapPalette.stroke(
                paletteIndex: 0,
                depth: 1,
                isOther: false,
                appearance: appearance
            ).blended(with: TreemapColor(1, 1, 1, 0), fraction: 0.4).cgColor
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
            }

            let textColor = TreemapPalette.text(appearance).nsColor
            let sizeTextColor = TreemapPalette.text(appearance).blended(
                with: TreemapColor(0.5, 0.5, 0.5),
                fraction: 0.35
            ).nsColor
            nameAttributes = [.font: nameFont, .foregroundColor: textColor]
            sizeAttributes = [.font: sizeFont, .foregroundColor: sizeTextColor]
        }

        /// `slot` is `0..<6` for palette groups and `6` for "other".
        func fill(slot: Int, depthIndex: Int) -> CGColor {
            fills[depthIndex * TreemapRenderer.slotsPerDepth + slot]
        }

        func stroke(slot: Int, depthIndex: Int) -> CGColor {
            strokes[depthIndex * TreemapRenderer.slotsPerDepth + slot]
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
