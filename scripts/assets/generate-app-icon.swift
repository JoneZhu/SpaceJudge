// SpaceJudge AppIcon generator.
//
// Renders the deterministic Phase 5D source-of-truth icon (soft light ground,
// treemap of rounded rectangles in WeChat-style greens, no text) directly from
// vector-ish Core Graphics drawing at every required pixel size. Nothing is
// downloaded or upscaled: each slot is drawn at its own target resolution and
// written as PNG into the asset catalog appiconset directory.
//
// Usage:
//   swift scripts/assets/generate-app-icon.swift [output-appiconset-directory]
//
// Default output directory is
//   App/SpaceJudgeApp/Assets.xcassets/AppIcon.appiconset
// resolved relative to the repository root (the script's grandparent).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

/// Treemap tiles in normalized (0...1) coordinates of the treemap area.
/// Deterministic and hand-tuned so the 16 px slot still reads as blocks.
private struct Tile {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let color: (CGFloat, CGFloat, CGFloat)
}

private let tiles: [Tile] = [
    Tile(x: 0.00, y: 0.00, width: 0.52, height: 0.60, color: (0.027, 0.757, 0.376)), // #07C160
    Tile(x: 0.00, y: 0.63, width: 0.52, height: 0.37, color: (0.247, 0.816, 0.498)), // #3FD07F
    Tile(x: 0.55, y: 0.00, width: 0.45, height: 0.34, color: (0.184, 0.663, 0.420)), // #2FA96B
    Tile(x: 0.55, y: 0.37, width: 0.45, height: 0.26, color: (0.561, 0.890, 0.706)), // #8FE3B4
    Tile(x: 0.55, y: 0.66, width: 0.45, height: 0.34, color: (0.718, 0.937, 0.816)), // #B7EFD0
]

private func drawIcon(in context: CGContext, size: CGFloat) {
    let full = CGRect(x: 0, y: 0, width: size, height: size)

    // Transparent canvas; the rounded plate is part of the artwork.
    context.clear(full)

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Soft plate: inset rounded rectangle with a gentle light-green wash.
    let plateInset = size * 0.055
    let plate = full.insetBy(dx: plateInset, dy: plateInset)
    let plateRadius = plate.width * 0.235
    let platePath = CGPath(
        roundedRect: plate,
        cornerWidth: plateRadius,
        cornerHeight: plateRadius,
        transform: nil
    )

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let plateColors = [
        CGColor(red: 0.973, green: 0.988, blue: 0.965, alpha: 1.0), // #F8FCF6
        CGColor(red: 0.902, green: 0.953, blue: 0.886, alpha: 1.0), // #E6F3E2
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: plateColors,
        locations: [0.0, 1.0]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.maxY),
            end: CGPoint(x: plate.maxX, y: plate.minY),
            options: []
        )
    }
    context.restoreGState()

    // Thin rim so the plate stays legible on dark backgrounds.
    context.saveGState()
    context.addPath(platePath)
    context.setStrokeColor(CGColor(red: 0.788, green: 0.878, blue: 0.769, alpha: 1.0))
    context.setLineWidth(max(1.0, size * 0.006))
    context.strokePath()
    context.restoreGState()

    // Treemap area inside the plate.
    let areaInset = size * 0.14
    let area = full.insetBy(dx: areaInset, dy: areaInset)
    let tileRadius = area.width * 0.075

    for tile in tiles {
        let rect = CGRect(
            x: area.minX + tile.x * area.width,
            y: area.minY + tile.y * area.height,
            width: tile.width * area.width,
            height: tile.height * area.height
        )
        // At very small sizes the radius would swallow the tile; clamp it.
        let radius = min(tileRadius, rect.width * 0.5, rect.height * 0.5)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(CGColor(red: tile.color.0, green: tile.color.1, blue: tile.color.2, alpha: 1.0))
        context.fillPath()
    }
}

private func writePNG(pixels: Int, to url: URL) throws {
    let size = CGFloat(pixels)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw NSError(domain: "SpaceJudgeIcon", code: 1)
    }
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "SpaceJudgeIcon", code: 2)
    }

    drawIcon(in: context, size: size)
    guard let image = context.makeImage() else {
        throw NSError(domain: "SpaceJudgeIcon", code: 3)
    }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "SpaceJudgeIcon", code: 4)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "SpaceJudgeIcon", code: 5)
    }
}

// MARK: - Slots

/// macOS AppIcon slots: filename pixel size plus the 2x counterpart.
private struct Slot {
    let fileName: String
    let pixels: Int
}

private let slots: [Slot] = [
    Slot(fileName: "icon_16x16.png", pixels: 16),
    Slot(fileName: "icon_16x16@2x.png", pixels: 32),
    Slot(fileName: "icon_32x32.png", pixels: 32),
    Slot(fileName: "icon_32x32@2x.png", pixels: 64),
    Slot(fileName: "icon_128x128.png", pixels: 128),
    Slot(fileName: "icon_128x128@2x.png", pixels: 256),
    Slot(fileName: "icon_256x256.png", pixels: 256),
    Slot(fileName: "icon_256x256@2x.png", pixels: 512),
    Slot(fileName: "icon_512x512.png", pixels: 512),
    Slot(fileName: "icon_512x512@2x.png", pixels: 1024),
]

private let contentsJSON = """
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

// MARK: - Entry point

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let defaultOutput = scriptURL
    .deletingLastPathComponent()   // scripts/assets
    .deletingLastPathComponent()   // scripts
    .deletingLastPathComponent()   // repo root
    .appendingPathComponent("App/SpaceJudgeApp/Assets.xcassets/AppIcon.appiconset")

let outputDirectory: URL
if CommandLine.arguments.count > 1 {
    outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
} else {
    outputDirectory = defaultOutput
}

try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for slot in slots {
    try writePNG(pixels: slot.pixels, to: outputDirectory.appendingPathComponent(slot.fileName))
}
// Optional standalone 1024 master for visual review; never part of the asset
// catalog so Xcode reports no unassigned child.
if let masterPath = ProcessInfo.processInfo.environment["SJ_ICON_MASTER"], masterPath.hasPrefix("/") {
    let masterURL = URL(fileURLWithPath: masterPath)
    try fileManager.createDirectory(
        at: masterURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try writePNG(pixels: 1024, to: masterURL)
}
try contentsJSON.write(
    to: outputDirectory.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
print("Wrote \(slots.count) PNGs + Contents.json to \(outputDirectory.path)")
