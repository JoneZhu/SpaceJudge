import AppKit
import Foundation
import Testing
import SpaceJudgeAppSupport
import SpaceJudgeDomain
import SpaceJudgeTreemap
@testable import SpaceJudgeTreemapUI

@MainActor
@Suite("Treemap canvas interaction")
struct TreemapCanvasTests {
    private let bounds = TreemapRect(x: 0, y: 0, width: 200, height: 120)

    private func makeView(tiles: [TreemapRenderTile]? = nil) -> TreemapCanvasView {
        let view = TreemapCanvasView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let resolved = tiles ?? [
            UITestSupport.tile(2, TreemapRect(x: 0, y: 0, width: 100, height: 120), kind: .directory),
            UITestSupport.tile(3, TreemapRect(x: 100, y: 0, width: 100, height: 120))
        ]
        view.setRenderSnapshot(UITestSupport.snapshot(tiles: resolved, bounds: bounds))
        return view
    }

    private func waitUntil(
        timeout: Double = 4,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    @Test("Single click is delayed and cancelled by a double click")
    func clickArbitration() {
        var single = 0
        var double = 0
        let view = makeView()
        view.actions = TreemapCanvasActions(
            singleClick: { _ in single += 1 },
            doubleClick: { _ in double += 1 }
        )
        view.handleClick(at: CGPoint(x: 50, y: 60), clickCount: 1)
        #expect(view.hasPendingSingleClick)
        view.cancelPendingSingleClick()
        #expect(!view.hasPendingSingleClick)
        #expect(single == 0)

        view.handleClick(at: CGPoint(x: 50, y: 60), clickCount: 2)
        #expect(double == 1)
        #expect(!view.hasPendingSingleClick)
    }

    @Test("Exactly one tracking area is owned by the view")
    func singleTrackingArea() {
        let view = makeView()
        view.updateTrackingAreas()
        #expect(view.ownedTrackingAreaCount == 1)
        view.updateTrackingAreas()
        #expect(view.ownedTrackingAreaCount == 1)
        view.teardown()
        #expect(view.ownedTrackingAreaCount == 0)
    }

    @Test("Context menus never offer a write action")
    func contextMenuHasNoWrites() {
        let view = makeView()
        let directory = UITestSupport.tile(2, TreemapRect(x: 0, y: 0, width: 100, height: 120), kind: .directory)
        let file = UITestSupport.tile(3, TreemapRect(x: 0, y: 0, width: 100, height: 120))
        let other = UITestSupport.other(1, TreemapRect(x: 0, y: 0, width: 100, height: 120))

        let directoryTitles = view.makeContextMenu(for: directory).items.map(\.title)
        #expect(directoryTitles.contains("进入目录"))
        #expect(directoryTitles.contains("查看信息"))
        #expect(directoryTitles.contains("在 Finder 中显示"))

        let fileTitles = view.makeContextMenu(for: file).items.map(\.title)
        #expect(fileTitles.contains("查看信息"))
        #expect(!fileTitles.contains("进入目录"))

        let otherTitles = view.makeContextMenu(for: other).items.map(\.title)
        #expect(otherTitles.count == 1)
        #expect(!otherTitles.contains("在 Finder 中显示"))

        let forbidden = ["删除", "移到废纸篓", "打开", "移动", "清理"]
        for title in directoryTitles + fileTitles + otherTitles {
            for word in forbidden {
                #expect(!title.contains(word), "menu leaked write action: \(title)")
            }
        }
    }

    @Test("Codex context menu binds the exact clicked node and never targets Other")
    func codexMenuScope() throws {
        let view = makeView()
        var analyzed: [TreemapRenderTile.Identity] = []
        view.actions = TreemapCanvasActions(analyze: { analyzed.append($0.identity) }, canAnalyze: { _ in true })
        for tile in try #require(view.renderSnapshot).tiles {
            let menu = view.makeContextMenu(for: tile)
            let item = try #require(menu.items.first { $0.title == "用 Codex 分析…" })
            #expect(item.isEnabled)
            _ = view.perform(try #require(item.action), with: item)
            #expect(analyzed.last == tile.identity)
        }
        let other = UITestSupport.other(1, bounds)
        #expect(!view.makeContextMenu(for: other).items.contains { $0.title == "用 Codex 分析…" })
    }

    @Test("Disabled Codex action stays disabled and rechecks eligibility at dispatch")
    func codexMenuEligibility() throws {
        let view = makeView()
        var allowed = false
        var calls = 0
        view.actions = TreemapCanvasActions(analyze: { _ in calls += 1 }, canAnalyze: { _ in allowed })
        let tile = try #require(view.renderSnapshot?.tiles.first)
        let menu = view.makeContextMenu(for: tile)
        let disabled = try #require(menu.items.first { $0.title == "用 Codex 分析…" })
        #expect(!menu.autoenablesItems)
        #expect(!disabled.isEnabled)
        _ = view.perform(try #require(disabled.action), with: disabled)
        #expect(calls == 0)
        allowed = true
        let enabled = try #require(view.makeContextMenu(for: tile).items.first { $0.title == "用 Codex 分析…" })
        #expect(enabled.isEnabled)
        allowed = false
        _ = view.perform(try #require(enabled.action), with: enabled)
        #expect(calls == 0)
    }

    @Test("Menu opened on an old scene cannot analyze after the snapshot is cleared")
    func codexMenuStale() throws {
        let view = makeView()
        var calls = 0
        view.actions = TreemapCanvasActions(analyze: { _ in calls += 1 }, canAnalyze: { _ in true })
        let tile = try #require(view.renderSnapshot?.tiles.first)
        let item = try #require(view.makeContextMenu(for: tile).items.first { $0.title == "用 Codex 分析…" })
        view.clearRenderSnapshot()
        _ = view.perform(try #require(item.action), with: item)
        #expect(calls == 0)
    }

    @Test("Selection changes invalidate and reach the model action")
    func selectionCentralized() {
        var selected: [TreemapRenderTile] = []
        var entered = false
        let view = makeView()
        view.actions = TreemapCanvasActions(
            select: { selected.append($0) },
            keyboardEnter: { _, _ in entered = true }
        )

        view.setSelection(.node(NodeID(2)))
        #expect(view.selectedIdentityForTesting == .node(NodeID(2)))

        view.moveSelection(dx: 1, dy: 0)
        #expect(view.selectedIdentityForTesting == .node(NodeID(3)))
        #expect(selected.last?.identity == .node(NodeID(3)))

        view.keyDown(with: NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )!)
        #expect(entered)
    }

    @Test("Arrow keys with no selection select a tile and notify the model")
    func arrowWithoutSelection() {
        var selected: [TreemapRenderTile] = []
        let view = makeView()
        view.actions = TreemapCanvasActions(select: { selected.append($0) })
        view.moveSelection(dx: 1, dy: 0)
        #expect(view.selectedIdentityForTesting != nil)
        #expect(selected.count == 1)
    }

    @Test("Clicking an other tile selects it without a node identity")
    func otherSelection() async {
        var selected: [TreemapRenderTile] = []
        let other = UITestSupport.other(1, TreemapRect(x: 0, y: 0, width: 200, height: 120), count: 12)
        let view = makeView(tiles: [other])
        view.actions = TreemapCanvasActions(singleClick: { selected.append($0) })
        view.handleClick(at: CGPoint(x: 50, y: 60), clickCount: 1)
        #expect(view.selectedIdentityForTesting == .other(parent: NodeID(1)))
        // Delayed single click commits the selection to the model action.
        #expect(await waitUntil { selected.last?.isOther == true })
        #expect(selected.last?.collapsedCount == 12)
    }

    @Test("Replacing the snapshot clears a stale hover and tooltip")
    func snapshotClearsHover() {
        let view = makeView()
        view.handleHover(at: CGPoint(x: 50, y: 60))
        #expect(view.hoveredIdentityForTesting == .node(NodeID(2)))

        let replacement = [
            UITestSupport.tile(9, TreemapRect(x: 0, y: 0, width: 200, height: 120))
        ]
        view.setRenderSnapshot(UITestSupport.snapshot(tiles: replacement, bounds: bounds))
        #expect(view.hoveredIdentityForTesting == nil)
        #expect(!view.hasTooltipForTesting)
    }

    @Test("Best-known tooltip marks scanning values")
    func bestKnownTooltip() {
        let view = makeView()
        let tile = UITestSupport.tile(2, TreemapRect(x: 0, y: 0, width: 100, height: 120), kind: .directory)
        view.isBestKnownValues = false
        #expect(!view.tooltipTextForTesting(tile).contains("正在统计"))
        view.isBestKnownValues = true
        #expect(view.tooltipTextForTesting(tile).contains("正在统计"))
    }

    @Test("Right click selects once without expanding or entering")
    func rightClickSelectsOnly() {
        var selectCount = 0
        var singleCount = 0
        var expandCount = 0
        var enterCount = 0
        let view = makeView()
        view.actions = TreemapCanvasActions(
            select: { _ in selectCount += 1 },
            singleClick: { _ in singleCount += 1 },
            enterDirectory: { _ in enterCount += 1 },
            expand: { _ in expandCount += 1 }
        )
        let tile = view.handleRightClick(at: CGPoint(x: 50, y: 60))
        #expect(tile?.identity == .node(NodeID(2)))
        #expect(selectCount == 1)
        #expect(singleCount == 0)
        #expect(expandCount == 0)
        #expect(enterCount == 0)
        #expect(view.selectedIdentityForTesting == .node(NodeID(2)))
        #expect(!view.hasPendingSingleClick)
    }

    @Test("Best-known marker applies before the tooltip task fires")
    func tooltipBestKnownBeforeAppears() async {
        let view = makeView()
        view.handleHover(at: CGPoint(x: 50, y: 60))
        view.isBestKnownValues = true
        #expect(await waitUntil { view.hasTooltipForTesting })
        #expect(view.visibleTooltipTextForTesting?.contains("正在统计") == true)
    }

    @Test("Terminal transition refreshes an already visible tooltip")
    func tooltipBestKnownWhileVisible() async {
        let view = makeView()
        view.handleHover(at: CGPoint(x: 50, y: 60))
        #expect(await waitUntil { view.hasTooltipForTesting })
        #expect(view.visibleTooltipTextForTesting?.contains("正在统计") == false)
        view.isBestKnownValues = true
        #expect(view.visibleTooltipTextForTesting?.contains("正在统计") == true)
        view.isBestKnownValues = false
        #expect(view.visibleTooltipTextForTesting?.contains("正在统计") == false)
    }

    @Test("Other tooltip also marks best-known values")
    func otherTooltipBestKnown() {
        let view = makeView()
        let other = UITestSupport.other(1, TreemapRect(x: 0, y: 0, width: 200, height: 120), count: 3)
        view.isBestKnownValues = false
        #expect(view.tooltipTextForTesting(other).contains("正在统计") == false)
        view.isBestKnownValues = true
        #expect(view.tooltipTextForTesting(other).contains("正在统计"))
    }

    @Test("The canvas is a single opaque flipped drawing surface")
    func canvasSurfaceContract() {
        let view = makeView()
        #expect(view.isFlipped)
        #expect(view.isOpaque)
        // No per-tile subviews: the canvas owns its drawing.
        #expect(view.subviews.isEmpty)
    }

    @Test("Hover over an empty area clears the hover state")
    func hoverClears() {
        let view = makeView()
        #expect(view.hoveredIdentityForTesting == nil)
        view.handleHover(at: CGPoint(x: 150, y: 60))
        #expect(view.hoveredIdentityForTesting == .node(NodeID(3)))
        view.handleHover(at: CGPoint(x: 999, y: 999))
        #expect(view.hoveredIdentityForTesting == nil)
        #expect(!view.hasTooltipForTesting)
    }
}

@MainActor
@Suite("Treemap representable coordinator")
struct TreemapCoordinatorTests {
    private let scanID = ScanID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000E2")!)

    private func scene(
        generation: Int,
        focus: UInt64,
        expansionVersion: Int = 1
    ) -> TreemapSceneData {
        let item = SnapshotChildItem(
            node: NodeRecord(
                id: NodeID(2),
                scanID: scanID,
                parentID: NodeID(focus),
                name: NameID(2),
                kind: .regularFile,
                logicalBytes: 100,
                allocatedBytes: 100,
                attributedBytes: 100
            ),
            name: NameRecord(id: NameID(2), bytes: Array("a".utf8))
        )
        let page = TreemapScenePage.make(
            from: SnapshotChildPage(
                items: [item],
                totalCount: 1,
                snapshotRevision: Revision(UInt64(generation))
            ),
            parentID: NodeID(focus)
        )
        return TreemapSceneData(
            scanID: scanID,
            scanGeneration: generation,
            revision: Revision(UInt64(generation)),
            focusNodeID: NodeID(focus),
            focusName: "root",
            focusKind: .directory,
            focusAggregate: nil,
            focusPage: page,
            expandedPages: [:],
            expansionOrder: [],
            expansionVersion: expansionVersion,
            detailMode: .detail,
            isTerminal: true,
            rootDisplayName: "root"
        )
    }

    /// Scene whose focus contains one directory (node 2) that is expanded and
    /// contains one child (node 20).
    private func expandedScene(
        generation: Int,
        focus: UInt64,
        expansionVersion: Int
    ) -> TreemapSceneData {
        func item(_ id: UInt64, _ name: String, _ kind: NodeKind) -> TreemapSceneItem {
            TreemapSceneItem(
                nodeID: NodeID(id),
                name: name,
                kind: kind,
                flags: [],
                effectiveBytes: 1_000,
                modifiedAt: nil,
                logicalBytes: nil,
                allocatedBytes: nil
            )
        }
        let focusPage = TreemapScenePage(
            parentID: NodeID(focus),
            items: [item(2, "dir", .directory)],
            totalCount: 1,
            snapshotRevision: Revision(UInt64(generation)),
            omittedCount: 0,
            omittedWeight: nil,
            aggregate: nil
        )
        let childPage = TreemapScenePage(
            parentID: NodeID(2),
            items: [item(20, "child", .regularFile)],
            totalCount: 1,
            snapshotRevision: Revision(UInt64(generation)),
            omittedCount: 0,
            omittedWeight: nil,
            aggregate: nil
        )
        return TreemapSceneData(
            scanID: scanID,
            scanGeneration: generation,
            revision: Revision(UInt64(generation)),
            focusNodeID: NodeID(focus),
            focusName: "root",
            focusKind: .directory,
            focusAggregate: nil,
            focusPage: focusPage,
            expandedPages: [NodeID(2): childPage],
            expansionOrder: [NodeID(2)],
            expansionVersion: expansionVersion,
            detailMode: .detail,
            isTerminal: true,
            rootDisplayName: "root"
        )
    }

    private func content(
        _ scene: TreemapSceneData?,
        detailMode: TreemapDetailMode = .detail,
        expansionVersion: Int = 1,
        selectedIdentity: TreemapRenderTile.Identity? = nil
    ) -> TreemapViewRepresentable.Content {
        TreemapViewRepresentable.Content(
            scene: scene,
            detailMode: detailMode,
            selectedIdentity: selectedIdentity,
            appearance: .light,
            scanGeneration: scene?.scanGeneration ?? 0,
            expansionVersion: expansionVersion,
            accessibilityValue: "test",
            isTerminal: true
        )
    }

    private func waitUntil(
        timeout: Double = 3,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    private func makeCoordinator(
        width: CGFloat = 200,
        height: CGFloat = 120
    ) -> (TreemapViewRepresentable, TreemapViewRepresentable.Coordinator, TreemapCanvasView) {
        let representable = TreemapViewRepresentable(content: content(nil), actions: TreemapCanvasActions())
        let coordinator = representable.makeCoordinator()
        let view = TreemapCanvasView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        coordinator.view = view
        return (representable, coordinator, view)
    }

    @Test("The coordinator applies the latest generation and rejects older ones")
    func latestGenerationWins() async {
        let (_, coordinator, view) = makeCoordinator()
        coordinator.update(content: content(scene(generation: 1, focus: 1)), actions: TreemapCanvasActions())
        coordinator.update(content: content(scene(generation: 2, focus: 1)), actions: TreemapCanvasActions())

        #expect(await waitUntil { view.snapshotForTesting?.key.scanGeneration == 2 })
        #expect(coordinator.submittedLayoutCount >= 1)
        coordinator.teardown()
    }

    @Test("An old size key is rejected and the latest size wins")
    func latestSizeWins() async {
        let (_, coordinator, view) = makeCoordinator()
        coordinator.update(content: content(scene(generation: 1, focus: 1)), actions: TreemapCanvasActions())
        view.setFrameSize(NSSize(width: 400, height: 300))
        coordinator.boundsChanged(CGSize(width: 400, height: 300))

        #expect(await waitUntil { view.snapshotForTesting?.key.width == 400 })
        #expect(view.snapshotForTesting?.key.height == 300)
        coordinator.teardown()
    }

    @Test("An old detail/expansion key is rejected")
    func latestModeAndExpansionWin() async {
        let (_, coordinator, view) = makeCoordinator()
        coordinator.update(
            content: content(scene(generation: 1, focus: 1, expansionVersion: 1), detailMode: .overview, expansionVersion: 1),
            actions: TreemapCanvasActions()
        )
        coordinator.update(
            content: content(scene(generation: 1, focus: 1, expansionVersion: 2), detailMode: .detail, expansionVersion: 2),
            actions: TreemapCanvasActions()
        )
        #expect(await waitUntil {
            view.snapshotForTesting?.key.expansionVersion == 2
                && view.snapshotForTesting?.key.detailMode == .detail
        })
        coordinator.teardown()
    }

    @Test("A mode-only change relayouts from the same scene")
    func modeOnlyRelayout() async {
        let (_, coordinator, view) = makeCoordinator()
        let scene = scene(generation: 1, focus: 1)
        coordinator.update(
            content: content(scene, detailMode: .overview, expansionVersion: 1),
            actions: TreemapCanvasActions()
        )
        #expect(await waitUntil { view.snapshotForTesting?.key.detailMode == .overview })
        let before = coordinator.submittedLayoutCount
        coordinator.update(
            content: content(scene, detailMode: .detail, expansionVersion: 1),
            actions: TreemapCanvasActions()
        )
        #expect(await waitUntil { view.snapshotForTesting?.key.detailMode == .detail })
        #expect(coordinator.submittedLayoutCount == before + 1)
        coordinator.teardown()
    }

    @Test("A scene arriving after a model-version bump is still laid out")
    func staleModelVersionDoesNotSkipNewScene() async {
        let (_, coordinator, view) = makeCoordinator()
        // Step 1: the old scene (expansionVersion 1) is paired with a model
        // version that already ran ahead (2). This must key on the scene.
        coordinator.update(
            content: content(
                scene(generation: 1, focus: 1, expansionVersion: 1),
                detailMode: .detail,
                expansionVersion: 2
            ),
            actions: TreemapCanvasActions()
        )
        #expect(await waitUntil { view.snapshotForTesting?.key.expansionVersion == 1 })
        let submittedBefore = coordinator.submittedLayoutCount

        // Step 2: the real expanded scene arrives with the same
        // scan/focus/revision/mode/size and the model version still 2.
        coordinator.update(
            content: content(
                expandedScene(generation: 1, focus: 1, expansionVersion: 2),
                detailMode: .detail,
                expansionVersion: 2
            ),
            actions: TreemapCanvasActions()
        )
        #expect(await waitUntil { view.snapshotForTesting?.key.expansionVersion == 2 })
        #expect(coordinator.submittedLayoutCount > submittedBefore)
        let childVisible = view.snapshotForTesting?.tiles.contains {
            $0.identity == TreemapRenderTile.Identity.node(NodeID(20))
        } == true
        #expect(childVisible)
        coordinator.teardown()
    }

    @Test("A nil scene clears the canvas")
    func nilSceneClears() async {
        let (_, coordinator, view) = makeCoordinator()
        coordinator.update(content: content(scene(generation: 1, focus: 1)), actions: TreemapCanvasActions())
        #expect(await waitUntil { view.snapshotForTesting != nil })
        coordinator.update(content: content(nil), actions: TreemapCanvasActions())
        #expect(view.snapshotForTesting == nil)
        coordinator.teardown()
    }

    @Test("100 rapid size/key changes converge to the latest key")
    func rapidChangesLatestWins() async {
        let (_, coordinator, view) = makeCoordinator()
        var lastKey: TreemapLayoutKey?
        for step in 0..<100 {
            let width = CGFloat(200 + step)
            let height = CGFloat(120 + step / 2)
            view.setFrameSize(NSSize(width: width, height: height))
            coordinator.update(
                content: content(
                    scene(generation: step + 1, focus: 1, expansionVersion: step + 1),
                    detailMode: step.isMultiple(of: 2) ? .overview : .detail,
                    expansionVersion: step + 1
                ),
                actions: TreemapCanvasActions()
            )
            lastKey = TreemapLayoutKey(
                scanGeneration: step + 1,
                scanID: scanID,
                focusNodeID: NodeID(1),
                sceneRevision: Revision(UInt64(step + 1)),
                expansionVersion: step + 1,
                detailMode: step.isMultiple(of: 2) ? .overview : .detail,
                width: Double(width),
                height: Double(height),
                backingScale: 2
            )
        }
        #expect(await waitUntil { view.snapshotForTesting?.key == lastKey })
        #expect(coordinator.submittedLayoutCount <= 100)
        coordinator.teardown()
    }

    @Test("Teardown prevents late layout application")
    func teardownPreventsLateApplication() async {
        let (_, coordinator, view) = makeCoordinator()
        coordinator.update(content: content(scene(generation: 1, focus: 1)), actions: TreemapCanvasActions())
        coordinator.teardown()
        // Give any detached task time to finish; the view must stay empty.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(view.snapshotForTesting == nil)
        #expect(coordinator.submittedLayoutCount >= 0)
    }
}
