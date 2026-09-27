import AppKit
import Foundation
import SpaceJudgeDomain
import SpaceJudgeTreemap

/// Actions the canvas forwards to the SwiftUI/model layer.
///
/// All closures are invoked on the main actor and carry an immutable render
/// tile, never a live `NSView`, `NodeRecord` batch or SQLite handle.
public struct TreemapCanvasActions {
    public var select: (TreemapRenderTile) -> Void
    public var singleClick: (TreemapRenderTile) -> Void
    public var doubleClick: (TreemapRenderTile) -> Void
    public var enterDirectory: (TreemapRenderTile) -> Void
    public var expand: (TreemapRenderTile) -> Void
    public var showInfo: (TreemapRenderTile) -> Void
    public var reveal: (TreemapRenderTile) -> Void
    public var keyboardEnter: (TreemapRenderTile, Bool) -> Void
    public var escape: () -> Void

    public init(
        select: @escaping (TreemapRenderTile) -> Void = { _ in },
        singleClick: @escaping (TreemapRenderTile) -> Void = { _ in },
        doubleClick: @escaping (TreemapRenderTile) -> Void = { _ in },
        enterDirectory: @escaping (TreemapRenderTile) -> Void = { _ in },
        expand: @escaping (TreemapRenderTile) -> Void = { _ in },
        showInfo: @escaping (TreemapRenderTile) -> Void = { _ in },
        reveal: @escaping (TreemapRenderTile) -> Void = { _ in },
        keyboardEnter: @escaping (TreemapRenderTile, Bool) -> Void = { _, _ in },
        escape: @escaping () -> Void = {}
    ) {
        self.select = select
        self.singleClick = singleClick
        self.doubleClick = doubleClick
        self.enterDirectory = enterDirectory
        self.expand = expand
        self.showInfo = showInfo
        self.reveal = reveal
        self.keyboardEnter = keyboardEnter
        self.escape = escape
    }
}

/// Single AppKit drawing surface for the treemap.
///
/// It owns exactly one tracking area, one hit index and no per-tile `NSView`,
/// `CALayer`, tracking area or accessibility element.
@MainActor
public final class TreemapCanvasView: NSView {
    /// Delay before a single click is committed, so a double click can cancel it.
    public static let singleClickDelay: TimeInterval = 0.23
    /// Delay before the hover tooltip appears.
    public static let tooltipDelay: TimeInterval = 0.35

    public var actions = TreemapCanvasActions()
    /// Called with the new size when the view is resized. The coordinator
    /// throttles and performs the actual relayout.
    public var onBoundsChanged: ((CGSize) -> Void)?
    /// Accessibility value updated by the representable.
    public var accessibilityValueText: String = "" {
        didSet { setAccessibilityValue(accessibilityValueText) }
    }
    /// True while scan values are best-known. The tooltip marks them as still
    /// being counted; this never triggers a query or layout.
    public var isBestKnownValues = false {
        didSet {
            guard isBestKnownValues != oldValue else { return }
            // Visible tooltip text is computed at draw time; a full repaint
            // erases the old marker and the possibly wider new frame.
            if tooltip != nil { needsDisplay = true }
        }
    }

    private(set) var renderSnapshot: TreemapRenderSnapshot?
    private var hitIndex: TreemapHitIndex?
    private var appearanceMode: TreemapAppearance = .light
    private var selectedIdentity: TreemapRenderTile.Identity?
    private var hoveredIdentity: TreemapRenderTile.Identity?
    private var trackingArea: NSTrackingArea?
    private var singleClickTask: Task<Void, Never>?
    private var tooltipTask: Task<Void, Never>?
    private var tooltip: (tile: TreemapRenderTile, rect: CGRect)?
    private let renderer = TreemapRenderer()

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var canBecomeKeyView: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("目录空间图")
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Snapshot

    /// Installs a new immutable render snapshot and rebuilds the hit index.
    func setRenderSnapshot(_ snapshot: TreemapRenderSnapshot) {
        renderSnapshot = snapshot
        hitIndex = TreemapHitIndex(tiles: snapshot.tiles, bounds: snapshot.bounds)
        // A hovered tile that disappeared in the new snapshot must not keep
        // its overlay or tooltip.
        if let hovered = hoveredIdentity,
           !snapshot.tiles.contains(where: { $0.identity == hovered }) {
            hoveredIdentity = nil
        }
        clearTooltip(invalidateBounds: true)
        needsDisplay = true
        updateAccessibilitySummary()
    }

    /// Clears the rendered scene (used when a new root resets the model).
    func clearRenderSnapshot() {
        renderSnapshot = nil
        hitIndex = nil
        selectedIdentity = nil
        hoveredIdentity = nil
        clearTooltip(invalidateBounds: true)
        needsDisplay = true
        updateAccessibilitySummary()
    }

    /// Single place that mutates the visual selection, so both the old and the
    /// new tile rects are invalidated.
    private func updateSelection(_ identity: TreemapRenderTile.Identity?) {
        guard selectedIdentity != identity else { return }
        let previous = selectedIdentity
        selectedIdentity = identity
        invalidate(identity: previous)
        invalidate(identity: identity)
        updateAccessibilitySummary()
    }

    func setSelection(_ identity: TreemapRenderTile.Identity?) {
        updateSelection(identity)
    }

    func setAppearance(_ appearance: TreemapAppearance) {
        guard self.appearanceMode != appearance else { return }
        self.appearanceMode = appearance
        needsDisplay = true
    }

    /// Test hook: number of tracking areas owned by this view.
    var ownedTrackingAreaCount: Int {
        trackingAreas.filter { $0.owner === self }.count
    }

    /// Test hook: current render snapshot.
    var snapshotForTesting: TreemapRenderSnapshot? { renderSnapshot }

    /// Test hook: hovered identity.
    var hoveredIdentityForTesting: TreemapRenderTile.Identity? { hoveredIdentity }

    /// Test hook: current visual selection.
    var selectedIdentityForTesting: TreemapRenderTile.Identity? { selectedIdentity }

    /// Test hook: whether a tooltip is currently displayed.
    var hasTooltipForTesting: Bool { tooltip != nil }

    /// Test hook: text currently drawn for the visible tooltip, computed from
    /// live state (including the best-known marker).
    var visibleTooltipTextForTesting: String? {
        tooltip.map { tooltipText(for: $0.tile) }
    }

    /// Test hook: computed tooltip string for a tile.
    func tooltipTextForTesting(_ tile: TreemapRenderTile) -> String {
        tooltipText(for: tile)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let snapshot = renderSnapshot else {
            context.setFillColor(TreemapPalette.background(appearanceMode).cgColor)
            context.fill(dirtyRect)
            return
        }
        renderer.render(
            snapshot: snapshot,
            in: context,
            dirtyRect: dirtyRect,
            options: TreemapRenderer.Options(
                appearance: appearanceMode,
                selected: selectedIdentity,
                hovered: hoveredIdentity
            )
        )
        drawTooltip(in: context)
    }

    private func drawTooltip(in context: CGContext) {
        guard let tooltip else { return }
        // Text is computed from live state, so a terminal transition between
        // hover start and draw can never leave stale best-known wording.
        let text = tooltipText(for: tooltip.tile)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let clamped = tooltipFrame(for: tooltip)
        let path = CGPath(
            roundedRect: clamped,
            cornerWidth: 5,
            cornerHeight: 5,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 0.92).cgColor)
        context.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        string.draw(at: CGPoint(x: clamped.minX + 6, y: clamped.minY + 3))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Frame of the drawn tooltip for a stored `(tile, anchor)` pair.
    private func tooltipFrame(for tooltip: (tile: TreemapRenderTile, rect: CGRect)) -> CGRect {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11)
        ]
        let text = tooltipText(for: tooltip.tile)
        let size = NSAttributedString(string: text, attributes: attributes).size()
        let padding = 6.0
        let rect = CGRect(
            x: tooltip.rect.minX,
            y: tooltip.rect.maxY + 6,
            width: size.width + padding * 2,
            height: size.height + padding
        )
        return clampTooltip(rect)
    }

    /// Cancels pending tooltip work, hides any visible tooltip and repaints its
    /// old bounds so no stale content remains.
    private func clearTooltip(invalidateBounds: Bool) {
        tooltipTask?.cancel()
        tooltipTask = nil
        guard let tooltip else { return }
        if invalidateBounds {
            let frame = tooltipFrame(for: tooltip).insetBy(dx: -4, dy: -4)
            setNeedsDisplay(frame)
        }
        self.tooltip = nil
    }

    private func clampTooltip(_ rect: CGRect) -> CGRect {
        var result = rect
        if result.maxX > bounds.maxX - 4 {
            result.origin.x = max(4, bounds.maxX - 4 - result.width)
        }
        if result.maxY > bounds.maxY - 4 {
            result.origin.y = max(4, bounds.maxY - 4 - result.height)
        }
        return result
    }

    private func invalidate(identity: TreemapRenderTile.Identity?) {
        guard let identity, let snapshot = renderSnapshot else { return }
        guard let tile = snapshot.tiles.first(where: { $0.identity == identity }) else { return }
        let rect = CGRect(
            x: tile.rect.x - 2,
            y: tile.rect.y - 2,
            width: tile.rect.width + 4,
            height: tile.rect.height + 4
        )
        setNeedsDisplay(rect)
    }

    // MARK: Tracking

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onBoundsChanged?(newSize)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
    }

    // MARK: Mouse

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        handleHover(at: point)
    }

    /// Test hook: hover handling without synthesizing an `NSEvent`.
    func handleHover(at point: CGPoint) {
        let tile = hitTestTile(at: point)
        let identity = tile?.identity
        guard identity != hoveredIdentity else { return }
        let previous = hoveredIdentity
        hoveredIdentity = identity
        invalidate(identity: previous)
        invalidate(identity: identity)
        clearTooltip(invalidateBounds: true)
        guard let tile else { return }
        let rect = CGRect(
            x: tile.rect.x,
            y: tile.rect.y,
            width: tile.rect.width,
            height: tile.rect.height
        )
        tooltipTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.tooltipDelay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.hoveredIdentity == identity else { return }
            // The tile, not the text, is stored: the text is computed at draw
            // time so a best-known transition is always reflected.
            self.tooltip = (tile, rect)
            self.needsDisplay = true
        }
    }

    public override func mouseExited(with event: NSEvent) {
        let previous = hoveredIdentity
        hoveredIdentity = nil
        invalidate(identity: previous)
        clearTooltip(invalidateBounds: true)
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let tile = hitTestTile(at: point) else { return }
        if event.clickCount >= 2 {
            cancelSingleClick()
            updateSelection(tile.identity)
            actions.doubleClick(tile)
            return
        }
        cancelSingleClick()
        let identity = tile.identity
        updateSelection(identity)
        let capturedPoint = TreemapPoint(x: point.x, y: point.y)
        singleClickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.singleClickDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.singleClickTask = nil
            guard let current = self.hitIndex?.tile(at: capturedPoint), current.identity == identity else {
                return
            }
            self.actions.singleClick(current)
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let tile = handleRightClick(at: point) else { return }
        presentContextMenu(for: tile, event: event)
    }

    /// Right click selects the tile and returns it for a read-only menu. It
    /// deliberately does not run the delayed single-click action, which would
    /// auto-expand a directory.
    func handleRightClick(at point: CGPoint) -> TreemapRenderTile? {
        cancelSingleClick()
        guard let tile = hitTestTile(at: point) else { return nil }
        updateSelection(tile.identity)
        actions.select(tile)
        return tile
    }

    /// Test hook: cancels a pending single click (as a double click would).
    func cancelPendingSingleClick() {
        cancelSingleClick()
    }

    /// Test hook: whether a single click is currently pending.
    var hasPendingSingleClick: Bool { singleClickTask != nil }

    private func cancelSingleClick() {
        singleClickTask?.cancel()
        singleClickTask = nil
    }

    /// Test hook exposing the click arbitration without synthesizing AppKit
    /// events.
    func handleClick(at point: CGPoint, clickCount: Int) {
        guard let tile = hitTestTile(at: point) else { return }
        if clickCount >= 2 {
            cancelSingleClick()
            updateSelection(tile.identity)
            actions.doubleClick(tile)
            return
        }
        cancelSingleClick()
        updateSelection(tile.identity)
        let capturedPoint = TreemapPoint(x: point.x, y: point.y)
        let identity = tile.identity
        singleClickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.singleClickDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.singleClickTask = nil
            guard let current = self.hitIndex?.tile(at: capturedPoint),
                  current.identity == identity else { return }
            self.actions.singleClick(current)
        }
    }

    private func hitTestTile(at point: CGPoint) -> TreemapRenderTile? {
        guard let hitIndex else { return nil }
        return hitIndex.tile(at: TreemapPoint(x: point.x, y: point.y))
    }

    // MARK: Context menu

    private func tooltipText(for tile: TreemapRenderTile) -> String {
        let size = ByteFormattingShort.bytes(tile.effectiveBytes)
        let base: String
        if tile.isOther {
            base = "其他 · \(tile.collapsedCount) 项 · \(size)"
        } else {
            let kind: String
            switch tile.kind {
            case .directory: kind = "目录"
            case .mountPoint: kind = "宗卷"
            case .regularFile: kind = "文件"
            case .symbolicLink: kind = "链接"
            case .socket, .fifo, .characterDevice, .blockDevice: kind = "特殊项"
            case .unknown, .none: kind = "未知"
            }
            let expanded = tile.isExpanded ? " · 已展开" : ""
            base = "\(tile.displayName) · \(kind) · \(size)\(expanded)"
        }
        return isBestKnownValues ? base + " · 正在统计（best-known）" : base
    }

    private func presentContextMenu(for tile: TreemapRenderTile, event: NSEvent) {
        NSMenu.popUpContextMenu(makeContextMenu(for: tile), with: event, for: self)
    }

    /// Builds the context menu for one tile. Exposed for tests so the absence
    /// of write actions can be asserted directly.
    func makeContextMenu(for tile: TreemapRenderTile) -> NSMenu {
        let menu = NSMenu()
        if tile.isOther {
            let item = NSMenuItem(
                title: "其他（\(tile.collapsedCount) 项，\(ByteFormattingShort.bytes(tile.effectiveBytes))）",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        } else if let kind = tile.kind, kind.isDirectoryLike {
            menu.addItem(menuItem(title: "进入目录", action: #selector(handleEnterMenu(_:)), tile: tile))
            if !tile.isExpanded {
                menu.addItem(menuItem(title: "展开", action: #selector(handleExpandMenu(_:)), tile: tile))
            }
            menu.addItem(.separator())
            menu.addItem(menuItem(title: "查看信息", action: #selector(handleInfoMenu(_:)), tile: tile))
            menu.addItem(menuItem(title: "在 Finder 中显示", action: #selector(handleRevealMenu(_:)), tile: tile))
        } else {
            menu.addItem(menuItem(title: "查看信息", action: #selector(handleInfoMenu(_:)), tile: tile))
            menu.addItem(menuItem(title: "在 Finder 中显示", action: #selector(handleRevealMenu(_:)), tile: tile))
        }
        return menu
    }

    private func menuItem(title: String, action: Selector, tile: TreemapRenderTile) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = MenuPayload(tile: tile)
        return item
    }

    private final class MenuPayload: NSObject {
        let tile: TreemapRenderTile
        init(tile: TreemapRenderTile) {
            self.tile = tile
        }
    }

    @objc private func handleEnterMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload else { return }
        actions.enterDirectory(payload.tile)
    }

    @objc private func handleExpandMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload else { return }
        actions.expand(payload.tile)
    }

    @objc private func handleInfoMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload else { return }
        actions.showInfo(payload.tile)
    }

    @objc private func handleRevealMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload else { return }
        actions.reveal(payload.tile)
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123:
            moveSelection(dx: -1, dy: 0)
        case 124:
            moveSelection(dx: 1, dy: 0)
        case 125:
            moveSelection(dx: 0, dy: 1)
        case 126:
            moveSelection(dx: 0, dy: -1)
        case 36, 76:
            handleReturn(command: event.modifierFlags.contains(.command))
        case 53:
            updateSelection(nil)
            actions.escape()
        default:
            super.keyDown(with: event)
        }
    }

    private func handleReturn(command: Bool) {
        guard let snapshot = renderSnapshot, let selectedIdentity else { return }
        guard let tile = snapshot.tiles.first(where: { $0.identity == selectedIdentity }) else { return }
        actions.keyboardEnter(tile, command)
    }

    /// Picks the nearest selectable tile whose center lies in the requested
    /// direction from the current selection.
    func moveSelection(dx: Double, dy: Double) {
        guard let snapshot = renderSnapshot else { return }
        let candidates = snapshot.tiles.filter { tile in
            guard tile.kind != nil, tile.rect.width > 0, tile.rect.height > 0 else { return false }
            return true
        }
        guard !candidates.isEmpty else { return }
        let anchors = snapshot.tiles.filter { $0.identity == selectedIdentity }
        guard let anchor = anchors.first else {
            updateSelection(candidates[0].identity)
            actions.select(candidates[0])
            return
        }
        let originX = anchor.rect.x + anchor.rect.width / 2
        let originY = anchor.rect.y + anchor.rect.height / 2
        var best: TreemapRenderTile?
        var bestScore = Double.greatestFiniteMagnitude
        for tile in candidates where tile.identity != anchor.identity {
            let cx = tile.rect.x + tile.rect.width / 2
            let cy = tile.rect.y + tile.rect.height / 2
            let vx = cx - originX
            let vy = cy - originY
            let forward = vx * dx + vy * dy
            guard forward > 0.5 else { continue }
            let cross = abs(vx * dy - vy * dx)
            let score = forward + cross * 0.6
            if score < bestScore {
                bestScore = score
                best = tile
            }
        }
        guard let best else { return }
        updateSelection(best.identity)
        actions.select(best)
    }

    // MARK: Accessibility

    private func updateAccessibilitySummary() {
        let value = accessibilityValueText.isEmpty
            ? "\(renderSnapshot?.tiles.count ?? 0) 个可见项"
            : accessibilityValueText
        setAccessibilityValue(value)
    }

    // MARK: Lifecycle

    /// Cancels all in-flight tasks and removes the tracking area.
    func teardown() {
        singleClickTask?.cancel()
        singleClickTask = nil
        clearTooltip(invalidateBounds: false)
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        trackingArea = nil
        onBoundsChanged = nil
    }
}
