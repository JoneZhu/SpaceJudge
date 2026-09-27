import AppKit
import Foundation
import SpaceJudgeAppSupport
import SpaceJudgeDomain
import SpaceJudgeTreemap
import SwiftUI

/// SwiftUI bridge around `TreemapCanvasView`.
///
/// `updateNSView` only stores immutable values and submits a background layout
/// task. It never performs SQLite queries or layout work on the main thread,
/// and it never sets the managed view's frame — SwiftUI owns that.
public struct TreemapViewRepresentable: NSViewRepresentable {
    /// Everything the canvas needs, in one `Equatable` value.
    public struct Content: Equatable {
        public var scene: TreemapSceneData?
        public var detailMode: TreemapDetailMode
        /// Identity of the selected tile, including synthetic `other` tiles.
        public var selectedIdentity: TreemapRenderTile.Identity?
        public var appearance: TreemapAppearance
        /// Model generation/expansion values used only as change triggers. The
        /// layout key is derived from the scene itself so it always describes
        /// the content that is actually installed.
        public var scanGeneration: Int
        public var expansionVersion: Int
        public var accessibilityValue: String
        public var isTerminal: Bool

        public init(
            scene: TreemapSceneData?,
            detailMode: TreemapDetailMode,
            selectedIdentity: TreemapRenderTile.Identity?,
            appearance: TreemapAppearance,
            scanGeneration: Int,
            expansionVersion: Int,
            accessibilityValue: String,
            isTerminal: Bool
        ) {
            self.scene = scene
            self.detailMode = detailMode
            self.selectedIdentity = selectedIdentity
            self.appearance = appearance
            self.scanGeneration = scanGeneration
            self.expansionVersion = expansionVersion
            self.accessibilityValue = accessibilityValue
            self.isTerminal = isTerminal
        }
    }

    public var content: Content
    public var actions: TreemapCanvasActions

    public init(content: Content, actions: TreemapCanvasActions) {
        self.content = content
        self.actions = actions
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> TreemapCanvasView {
        let view = TreemapCanvasView(frame: .zero)
        context.coordinator.view = view
        view.onBoundsChanged = { [weak coordinator = context.coordinator] size in
            coordinator?.boundsChanged(size)
        }
        return view
    }

    public func updateNSView(_ nsView: TreemapCanvasView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(content: content, actions: actions)
    }

    public static func dismantleNSView(_ nsView: TreemapCanvasView, coordinator: Coordinator) {
        coordinator.teardown()
        nsView.teardown()
    }

    /// Owns the single background layout task and rejects stale results.
    @MainActor
    public final class Coordinator: NSObject {
        var parent: TreemapViewRepresentable
        weak var view: TreemapCanvasView?

        private var layoutTask: Task<Void, Never>?
        private var throttleTask: Task<Void, Never>?
        private var content: Content?
        private var pendingKey: TreemapLayoutKey?
        private var appliedKey: TreemapLayoutKey?
        private var lastSubmitAt: ContinuousClock.Instant?
        /// Minimum elapsed time between live-resize layout submissions.
        static let resizeInterval: Double = 0.05
        /// Test hook: number of times a layout was actually submitted.
        private(set) var submittedLayoutCount = 0
        /// Test hook: last key handed to the composer.
        private(set) var lastSubmittedKey: TreemapLayoutKey?

        init(_ parent: TreemapViewRepresentable) {
            self.parent = parent
        }

        func update(content: Content, actions: TreemapCanvasActions) {
            self.content = content
            guard let view else { return }
            view.actions = actions
            view.accessibilityValueText = content.accessibilityValue
            view.setAppearance(content.appearance)
            view.isBestKnownValues = !content.isTerminal
            view.setSelection(content.selectedIdentity)
            scheduleLayout(force: true)
        }

        func boundsChanged(_ size: CGSize) {
            scheduleLayout(force: false)
        }

        /// Test hook: force a layout pass for a specific content and size.
        func scheduleLayoutForTesting() {
            scheduleLayout(force: true)
        }

        private func scheduleLayout(force: Bool) {
            guard let view else { return }
            guard let content else { return }
            guard let scene = content.scene else {
                view.clearRenderSnapshot()
                appliedKey = nil
                pendingKey = nil
                return
            }
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let scale = Double(view.window?.backingScaleFactor ?? 2)
            // The key must describe the scene that is actually installed, not
            // a model version that may run ahead of it. Otherwise a layout
            // computed from an old scene with a newer expansion version would
            // collide with the layout of the real new scene and be skipped.
            let key = TreemapLayoutKey(
                scanGeneration: scene.scanGeneration,
                scanID: scene.scanID,
                focusNodeID: scene.focusNodeID,
                sceneRevision: scene.revision,
                expansionVersion: scene.expansionVersion,
                detailMode: content.detailMode,
                width: Double(size.width),
                height: Double(size.height),
                backingScale: scale
            )
            if key == appliedKey || key == pendingKey {
                return
            }
            if !force, let last = lastSubmitAt {
                let elapsed = last.duration(to: ContinuousClock.now)
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                if seconds < Self.resizeInterval {
                    if throttleTask == nil {
                        let remaining = max(0, Self.resizeInterval - seconds)
                        throttleTask = Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                            guard let self, !Task.isCancelled else { return }
                            self.throttleTask = nil
                            self.scheduleLayout(force: true)
                        }
                    }
                    return
                }
            }
            submit(key: key, scene: scene, size: size)
        }

        private func submit(key: TreemapLayoutKey, scene: TreemapSceneData, size: CGSize) {
            layoutTask?.cancel()
            throttleTask?.cancel()
            throttleTask = nil
            pendingKey = key
            lastSubmitAt = ContinuousClock.now
            submittedLayoutCount += 1
            lastSubmittedKey = key

            let hierarchy = scene.hierarchy()
            let bounds = TreemapRect(
                x: 0,
                y: 0,
                width: Double(size.width),
                height: Double(size.height)
            )
            layoutTask = Task.detached(priority: .userInitiated) { [weak self] in
                let snapshot = TreemapHierarchyComposer.snapshot(
                    hierarchy,
                    key: key,
                    bounds: bounds
                )
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self, let view = self.view else { return }
                    guard self.pendingKey == key else { return }
                    self.appliedKey = key
                    self.pendingKey = nil
                    view.setRenderSnapshot(snapshot)
                }
            }
        }

        func teardown() {
            layoutTask?.cancel()
            layoutTask = nil
            throttleTask?.cancel()
            throttleTask = nil
            pendingKey = nil
            content = nil
            view = nil
        }
    }
}
