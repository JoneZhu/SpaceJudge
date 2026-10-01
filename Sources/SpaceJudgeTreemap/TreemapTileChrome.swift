import Foundation

/// Shared geometry for the text drawn inside one treemap tile.
///
/// Both the hierarchy composer (which reserves a header above expanded
/// children) and the renderer (which draws the labels and clips them) use this
/// single definition, so a parent title can never overlap its children.
///
/// Rules:
/// - an expanded directory draws its title only inside its reserved header;
///   children start below that header;
/// - a two-line title (name above size) is only reserved when the tile is tall
///   enough to still leave room for children;
/// - a narrow tile may show the size on the same line as the name when there is
///   enough width, or omit it entirely;
/// - a tile too short or too narrow for a legible name draws no text.
public enum TreemapTileChrome {
    /// Horizontal inset for text.
    public static let textInset: Double = 8
    /// Vertical inset above the first text line.
    public static let textTopInset: Double = 6
    /// Vertical inset below the last text line inside a header.
    public static let textBottomInset: Double = 5
    /// Height of the name line for a 13 pt font.
    public static let nameLineHeight: Double = 16
    /// Height of the size line for an 11 pt font.
    public static let sizeLineHeight: Double = 14
    /// Gap between the name and size lines.
    public static let lineGap: Double = 1
    /// A name narrower than this is not drawn.
    public static let minimumNameWidth: Double = 40
    /// At or above this width the size is drawn on the name line, right aligned.
    public static let inlineSizeMinimumWidth: Double = 150
    /// Corner radius for the rounded tile shape.
    public static let cornerRadius: Double = 8
    /// A header may never take more than this fraction of the tile height.
    public static let maximumHeaderFraction: Double = 0.42
    /// Minimum usable name line height (a little smaller than the nominal line
    /// so short tiles can still show one line).
    public static let minimumNameLineHeight: Double = 12

    /// Header height reserved for a two-line title (name above size).
    public static var twoLineHeaderHeight: Double {
        textTopInset + nameLineHeight + lineGap + sizeLineHeight + textBottomInset
    }

    /// Header height reserved for a single-line title.
    public static var oneLineHeaderHeight: Double {
        textTopInset + nameLineHeight + textBottomInset
    }

    /// Header height reserved above an expanded tile's children.
    ///
    /// A wide tile shows the size inline, so it only needs one line. A narrow
    /// tile reserves two lines when the tile is tall enough; otherwise it
    /// reserves one line or whatever fraction still fits.
    public static func headerHeight(tileWidth: Double, tileHeight: Double) -> Double {
        guard tileWidth > 0, tileHeight > 0 else { return 0 }
        let maximum = tileHeight * maximumHeaderFraction
        let showsInlineSize = tileWidth >= inlineSizeMinimumWidth
        if !showsInlineSize, maximum >= twoLineHeaderHeight {
            return twoLineHeaderHeight
        }
        if maximum >= oneLineHeaderHeight {
            return oneLineHeaderHeight
        }
        return max(0, min(oneLineHeaderHeight, maximum))
    }

    /// Which labels and clip region a tile should use.
    public struct TextLayout: Sendable, Equatable {
        /// The name label frame.
        public let nameRect: TreemapRect
        /// The size label frame, or `nil` when it does not fit.
        public let sizeRect: TreemapRect?
        /// `true` when the size shares the name line, right aligned.
        public let sizeIsInline: Bool
        /// The region the labels must be clipped to. For an expanded tile this
        /// is the reserved header band; for a leaf it is the whole tile.
        public let clipRegion: TreemapRect
    }

    /// Computes the label layout inside `tileRect`.
    ///
    /// Returns `nil` when no legible name fits.
    public static func textLayout(tileRect: TreemapRect, isExpanded: Bool) -> TextLayout? {
        guard tileRect.width > 0, tileRect.height > 0 else { return nil }
        let contentWidth = tileRect.width - textInset * 2
        guard contentWidth >= minimumNameWidth else { return nil }

        let bandHeight = isExpanded
            ? headerHeight(tileWidth: tileRect.width, tileHeight: tileRect.height)
            : tileRect.height
        guard bandHeight >= textTopInset + minimumNameLineHeight else { return nil }

        let nameTop = tileRect.y + textTopInset
        let clipRegion = TreemapRect(
            x: tileRect.x,
            y: tileRect.y,
            width: tileRect.width,
            height: bandHeight
        )
        let nameHeight = min(nameLineHeight, bandHeight - textTopInset)

        if tileRect.width >= inlineSizeMinimumWidth {
            let sizeWidth = min(84.0, max(48.0, contentWidth * 0.32))
            let nameWidth = contentWidth - sizeWidth - 6
            if nameWidth >= minimumNameWidth {
                let nameRect = TreemapRect(
                    x: tileRect.x + textInset, y: nameTop,
                    width: nameWidth, height: nameHeight
                )
                let sizeHeight = min(sizeLineHeight, bandHeight - textTopInset)
                let sizeRect = TreemapRect(
                    x: tileRect.x + textInset + nameWidth + 6,
                    y: nameTop + (nameLineHeight - sizeLineHeight) / 2,
                    width: sizeWidth,
                    height: sizeHeight
                )
                return TextLayout(
                    nameRect: nameRect, sizeRect: sizeRect,
                    sizeIsInline: true, clipRegion: clipRegion
                )
            }
        }

        let nameRect = TreemapRect(
            x: tileRect.x + textInset, y: nameTop,
            width: contentWidth, height: nameHeight
        )
        let sizeTop = nameTop + nameLineHeight + lineGap
        if bandHeight >= textTopInset + nameLineHeight + lineGap + sizeLineHeight {
            let sizeRect = TreemapRect(
                x: tileRect.x + textInset, y: sizeTop,
                width: contentWidth, height: sizeLineHeight
            )
            return TextLayout(
                nameRect: nameRect, sizeRect: sizeRect,
                sizeIsInline: false, clipRegion: clipRegion
            )
        }
        return TextLayout(
            nameRect: nameRect, sizeRect: nil,
            sizeIsInline: false, clipRegion: clipRegion
        )
    }
}
