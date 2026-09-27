import Foundation

/// Platform-independent size used by the treemap module.
///
/// The core deliberately avoids `CGRect`/`CGSize` so it stays free of AppKit
/// and CoreGraphics and remains trivially `Sendable`/`Equatable`.
public struct TreemapSize: Sendable, Equatable, Hashable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = TreemapSize(width: 0, height: 0)

    public var area: Double { width * height }
}

/// Platform-independent rectangle used by the treemap module.
public struct TreemapRect: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: TreemapPoint, size: TreemapSize) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public static let zero = TreemapRect(x: 0, y: 0, width: 0, height: 0)

    public var origin: TreemapPoint { TreemapPoint(x: x, y: y) }
    public var size: TreemapSize { TreemapSize(width: width, height: height) }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public var area: Double { width * height }

    public var isDegenerate: Bool {
        width <= 0 || height <= 0
    }

    /// Area of the intersection with another rectangle (zero when disjoint).
    public func intersectionArea(with other: TreemapRect) -> Double {
        let overlapWidth = min(maxX, other.maxX) - max(minX, other.minX)
        let overlapHeight = min(maxY, other.maxY) - max(minY, other.minY)
        guard overlapWidth > 0, overlapHeight > 0 else { return 0 }
        return overlapWidth * overlapHeight
    }

    /// `true` when this rectangle lies within `other` up to `tolerance`.
    public func isContained(in other: TreemapRect, tolerance: Double = 1e-9) -> Bool {
        minX >= other.minX - tolerance
            && minY >= other.minY - tolerance
            && maxX <= other.maxX + tolerance
            && maxY <= other.maxY + tolerance
    }

    /// Intersection of two rectangles. Returns `nil` when they are disjoint.
    public func intersection(_ other: TreemapRect) -> TreemapRect? {
        let nx = max(minX, other.minX)
        let ny = max(minY, other.minY)
        let nMaxX = min(maxX, other.maxX)
        let nMaxY = min(maxY, other.maxY)
        guard nMaxX > nx, nMaxY > ny else { return nil }
        return TreemapRect(x: nx, y: ny, width: nMaxX - nx, height: nMaxY - ny)
    }

    /// Shrinks the rectangle by `dx`/`dy` on each side, clamping dimensions at
    /// zero so callers never see negative geometry.
    public func insetBy(dx: Double, dy: Double) -> TreemapRect {
        TreemapRect(
            x: x + dx,
            y: y + dy,
            width: max(0, width - 2 * dx),
            height: max(0, height - 2 * dy)
        )
    }
}

/// Platform-independent point.
public struct TreemapPoint: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = TreemapPoint(x: 0, y: 0)
}
