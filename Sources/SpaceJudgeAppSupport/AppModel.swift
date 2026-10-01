import Foundation
import Observation
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeTreemap
import SpaceJudgeUseCases

/// MainActor state machine for the Phase 3 macOS shell.
///
/// The model owns exactly one active scan. It never touches SQLite, directory
/// enumeration or layout on the main thread: scanning runs in a detached task
/// through `PersistingScanRunner`, snapshot reads go through a separate
/// read-only repository, and only coalesced lightweight values reach the
/// observable surface.
@MainActor
@Observable
public final class AppModel {
    // MARK: Observable state

    /// Coarse lifecycle phase.
    public private(set) var phase: AppPhase = .idle
    /// Root label shown in the header. Never a full path with personal data.
    public private(set) var rootDisplayName: String?
    /// Current or last scan identifier.
    public private(set) var scanID: ScanID?
    /// Root node of the current or last scan.
    public private(set) var rootNodeID: NodeID?
    /// Coalesced progress counters.
    public private(set) var progress: ScanProgress?
    /// Terminal summary when the scan finished.
    public private(set) var summary: ScanSummary?
    /// Volume capacity facts for the chosen root.
    public private(set) var volume: VolumeFacts?
    /// Accumulated persisted issue count.
    public private(set) var issueCount: UInt64 = 0
    /// Derived from `EACCES`/`EPERM` facts only — never a permission probe.
    public private(set) var permissionLimited = false
    /// Bounded list of the largest direct children (at most `childPageLimit`).
    public private(set) var childPage: SnapshotChildPage?
    /// User-facing, path-free error explanation.
    public private(set) var userError: AppUserError?
    /// Latest commit revision applied to `childPage`.
    public private(set) var committedRevision: Revision?
    /// Immutable plan backing the current or last scan. Read-only; exposes the
    /// chosen `kind` for tests and future UI without persisting any path.
    public private(set) var volumePlan: VolumeScanPlan?
    /// Background full-range refresh; the canvas still describes the old scan.
    public private(set) var isRefreshing = false
    public private(set) var refreshMessage: String?
    private var isReplacingSnapshot = false
    private var refreshMetadata: ScanMetadata?
    private var refreshRevision: Revision?
    private var refreshBackup: (phase: AppPhase, progress: ScanProgress?)?

    // MARK: Treemap navigation state

    /// Directory currently filling the treemap. `nil` until the scan starts.
    public private(set) var currentNodeID: NodeID?
    /// Root-to-current path with scan-local names.
    public private(set) var breadcrumbs: [SnapshotPathItem] = []
    /// Directories entered during this scan, oldest first.
    public private(set) var navigationHistory: [NodeID] = []
    /// Index into `navigationHistory` for the current focus.
    public private(set) var historyIndex: Int = -1
    /// Currently selected tile, if any.
    public private(set) var selectedNodeID: NodeID?
    /// Scene item backing the current selection.
    public private(set) var selectedItem: TreemapSceneItem?
    /// Best-known aggregate for the selected directory.
    public private(set) var selectedAggregate: DirectoryAggregateRecord?
    /// Selection of a synthetic "other" tile; never carries a node identity.
    public private(set) var selectedOther: TreemapOtherSelection?
    /// Overview or detail thresholds.
    public private(set) var detailMode: TreemapDetailMode = .overview
    /// Immutable scene handed to the AppKit canvas.
    public private(set) var treemapScene: TreemapSceneData?
    /// Best-known revision of `treemapScene`.
    public private(set) var sceneRevision: Revision?
    /// Path-free explanation when the last scene read failed.
    public private(set) var sceneError: String?
    /// In-place expanded directories, in interaction order.
    public private(set) var expandedNodeIDs: [NodeID] = []
    /// Directories whose automatic preview the user explicitly collapsed. They
    /// stay collapsed across scan refreshes until the focus changes or the user
    /// expands them again.
    public private(set) var suppressedPreviewNodeIDs: [NodeID] = []
    /// Monotonic expansion-set version used to reject stale layouts.
    public private(set) var expansionVersion = 0
    /// Path-free explanation when reveal-in-Finder cannot locate the item.
    public private(set) var revealError: String?

    /// Fixed bound for the "largest items" diagnostic list.
    public let childPageLimit = 100
    /// Maximum direct children loaded for the current focus page.
    public let focusPageLimit = 500
    /// Maximum direct children loaded for one in-place expanded directory.
    public let expandedPageLimit = 200
    /// Maximum number of simultaneously expanded directories.
    public let maximumExpandedCount = 8
    /// Maximum number of directories auto-previewed to show a shallow nesting
    /// by default without any user action.
    public let previewExpandedLimit = 6
    /// Maximum direct children loaded for one auto-previewed directory.
    public let previewPageLimit = 80

    // MARK: Dependencies

    private let engine: any ScanEngine
    private let repository: any SnapshotRepository
    private let loader: SnapshotLoader
    private let sceneLoader: SnapshotLoader
    private let directoryAccess: any DirectoryAccess
    private let planner: any VolumeScanPlanning
    private let shutdownHandler: @Sendable () async -> Void
    /// Grace period, in seconds, for a graceful cancellation terminal before
    /// the consumer task is force-cancelled. Injectable so tests need not wait
    /// the production two seconds.
    private let cancelGracePeriod: Double
    /// Session-only storage boundaries handed to every scan request. Production
    /// passes exactly one workspace root; never persisted or logged.
    private let workspaceExclusions: [SnapshotWorkspaceExclusion]

    // MARK: Private state

    private let buffer = ScanUpdateBuffer()
    private var selection: DirectorySelection?
    private var scopeActive = false
    private var scanTask: Task<Void, Never>?
    private var runnerTask: Task<ScanSummary, any Error>?
    private var pumpTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var refreshInFlight = false
    private var refreshPending = false
    private var scanFinished = true
    private var isShutDown = false
    /// Set synchronously at the start of `chooseRoot()` so a second call cannot
    /// open a second picker while the first is suspended.
    private var isChoosingRoot = false
    private var sceneRefreshInFlight = false
    private var sceneRefreshPending = false
    private var sceneRefreshTask: Task<Void, Never>?
    private var sceneQueryTask: Task<Void, Never>?
    private var sceneQuerySequence = 0
    private var activeSceneToken: SceneQueryToken?
    private var lastSceneRefreshAt: ContinuousClock.Instant?
    private var selectionToken = 0
    /// Single-flight, latest-wins refresh state for the selected directory's
    /// aggregate. Deliberately separate from `selectionToken`: an automatic
    /// detail refresh must never invalidate an in-flight Finder request for the
    /// same user selection.
    private var aggregateQueryTask: Task<Void, Never>?
    private var aggregateQueryGeneration = 0
    private var aggregateQueryPending = false

    // MARK: Init

    public init(
        engine: any ScanEngine,
        repository: any SnapshotRepository,
        reader: any SnapshotRepository,
        directoryAccess: any DirectoryAccess,
        planner: any VolumeScanPlanning = FoundationVolumeScanPlanner(),
        sceneReader: (any SnapshotRepository)? = nil,
        workspaceExclusions: [SnapshotWorkspaceExclusion] = [],
        cancelGracePeriod: Double = 2,
        shutdown: @escaping @Sendable () async -> Void
    ) {
        self.engine = engine
        self.repository = repository
        self.loader = SnapshotLoader(repository: reader)
        self.sceneLoader = SnapshotLoader(repository: sceneReader ?? reader)
        self.directoryAccess = directoryAccess
        self.planner = planner
        self.shutdownHandler = shutdown
        self.workspaceExclusions = workspaceExclusions
        self.cancelGracePeriod = max(0, cancelGracePeriod)
        buffer.setImmediateWake { [weak self] in
            Task { @MainActor [weak self] in
                self?.drain()
            }
        }
    }

    // MARK: Derived presentation values

    /// Whether a scan task is currently active.
    public var isScanning: Bool { phase.isActive }

    /// A synthetic “other” tile is not an actionable scope. Analysis uses the
    /// actual selected node, or the current focus when nothing is selected.
    public var canAnalyzeWithAgent: Bool {
        isTerminal && !isRefreshing && !isSceneStale && selectedOther == nil
            && scanID != nil && currentNodeID != nil
    }

    public func captureAgentAnalysis(nodeID requestedNodeID: NodeID? = nil) async throws -> AgentAnalysisSnapshot {
        guard canAnalyzeWithAgent, let scan = scanID,
              let node = requestedNodeID ?? selectedNodeID ?? currentNodeID else {
            throw AgentAnalysisSnapshot.CaptureError.unstableSnapshot
        }
        let focus = currentNodeID
        let snapshot = try await AgentAnalysisSnapshot.capture(loader: loader, scanID: scan, nodeID: node)
        guard canAnalyzeWithAgent, scanID == scan, currentNodeID == focus,
              requestedNodeID != nil || (selectedNodeID ?? currentNodeID) == node else {
            throw AgentAnalysisSnapshot.CaptureError.unstableSnapshot
        }
        return snapshot
    }

    public func captureCleanupHandoff(nodeID: NodeID) async throws
        -> (snapshot: AgentAnalysisSnapshot, context: CodexCleanupContext) {
        guard let scan = scanID, let root = rootNodeID, let selectedRoot = selection else {
            throw AgentAnalysisSnapshot.CaptureError.missingScope
        }
        let focus = currentNodeID
        let snapshot = try await captureAgentAnalysis(nodeID: nodeID)
        let context = try await CodexCleanupContext.capture(loader: loader, scanID: scan,
            nodeID: nodeID, rootNodeID: root, rootPath: selectedRoot.fileSystemPath,
            snapshot: snapshot, volume: volume)
        guard canAnalyzeWithAgent, scanID == scan, currentNodeID == focus, selection == selectedRoot else {
            throw AgentAnalysisSnapshot.CaptureError.unstableSnapshot
        }
        return (snapshot, context)
    }

    /// One-line capacity summary; unknown values render as em dashes.
    public var capacityLine: String { ByteFormatting.capacityLine(volume) }

    /// Attributed bytes for the *current focus* only, from its snapshot
    /// aggregate. `nil` when the read has not provided an aggregate yet; this
    /// must never fall back to the whole-scan root total.
    public var focusAttributedBytes: UInt64? {
        guard !isSceneStale else { return nil }
        return treemapScene?.focusAggregate?.attributedBytes
    }

    /// Whether the current focus aggregate is still being built.
    public var focusAggregateIsComplete: Bool? {
        guard !isSceneStale else { return nil }
        return treemapScene?.focusAggregate?.isComplete
    }

    /// Compact "current location" size line. Unknown is an em dash, never a 0,
    /// and an incomplete aggregate is marked with the shared active/terminal
    /// wording (never "still counting" after a cancel or failure).
    public var focusSizeLine: String {
        let complete = focusAggregateIsComplete
        let suffix = complete == false
            ? progressWording.incompleteSuffix(isComplete: false)
            : ""
        return "当前位置 \(ByteFormatting.bytes(focusAttributedBytes))\(suffix)"
    }

    /// Shared active/terminal progress wording.
    public var progressWording: AppProgressWording {
        AppProgressWording(phase: isRefreshing ? refreshBackup?.phase ?? phase : phase)
    }

    /// Root reconciliation for the whole scan, explicitly labelled so it is
    /// never read as the current map's size.
    public var scanScopeReconciliationLine: String? {
        guard let attribution = attributionLine else { return nil }
        return "扫描范围 · \(attribution)"
    }

    /// Testable, path-free presentation classification for the shell.
    public var presentationState: AppPresentationState {
        AppPresentationState.resolve(
            phase: phase,
            progress: progress,
            scene: treemapScene,
            sceneError: sceneError != nil,
            attribution: bestKnownAttributedBytes,
            isLoading: isSceneLoading,
            sceneMatchesFocus: !isSceneStale
        )
    }

    /// Whether a snapshot read for the current focus is in flight or queued.
    public var isSceneLoading: Bool {
        sceneRefreshInFlight || sceneRefreshPending
            || sceneRefreshTask != nil || sceneQueryTask != nil
    }

    /// Whether the displayed map belongs to a different focus than the current
    /// navigation path (an old map kept on screen while the new one loads).
    public var isSceneStale: Bool {
        if isReplacingSnapshot { return true }
        guard let scene = treemapScene, let focus = currentNodeID else { return false }
        return scene.focusNodeID != focus
    }

    /// Best-known attributed bytes for the current scope, from terminal facts
    /// or in-flight progress, else `nil`.
    public var bestKnownAttributedBytes: UInt64 {
        switch scanAttribution {
        case .terminal(let attributedBytes, _):
            return attributedBytes
        case .scanning(let attributedBytes):
            return attributedBytes
        case .none:
            return 0
        }
    }

    /// Compact capacity strip values and provenance label.
    public var capacityPresentation: CapacityPresentation {
        CapacityPresentation(volume: volume)
    }

    /// Shared enablement policy for the toolbar and the menu bar. Derived from
    /// live state, so both surfaces stay in sync and the menu can observe it.
    public var commandPolicy: AppCommandPolicy {
        AppCommandPolicy(phase: phase, hasRoot: hasRoot, isShutDown: isShutDown)
    }

    /// Whether the choose-location action is currently allowed. Single source
    /// of truth for the toolbar and the menu.
    public var canChooseRoot: Bool { commandPolicy.canChooseRoot }

    /// Whether the rescan action is currently allowed. Single source of truth
    /// for the toolbar and the menu so `Command+R` cannot restart a live scan.
    public var canRescan: Bool { commandPolicy.canRescan }

    /// Whether the cancel action is currently allowed.
    public var canCancel: Bool { commandPolicy.canCancel }

    /// Counting/rate line for the scanning state.
    public var progressLine: String { ByteFormatting.progressLine(progress) }

    /// Best-known attribution derived from live state. The terminal summary
    /// always wins over in-flight progress; nothing is cached here, so it can
    /// never drift from `summary`/`progress`.
    public var scanAttribution: ScanAttributionState? {
        if let summary {
            return .terminal(
                attributedBytes: summary.rootAttributedBytes,
                isComplete: summary.status == .completed
            )
        }
        if let progress {
            return .scanning(attributedBytes: progress.attributedBytes)
        }
        return nil
    }

    /// Compact volume-vs-scope reconciliation line, or `nil` before any scan
    /// fact exists (no placeholder noise).
    public var attributionLine: String? {
        ByteFormatting.attributionLine(scanAttribution, volume: volume)
    }

    /// Whether the user has explicitly chosen a root.
    public var hasRoot: Bool { rootDisplayName != nil }

    /// Explanatory text for the "largest items" section.
    public var largestItemsCaption: String {
        guard let childPage else { return "最大项目（真实快照，最多 \(childPageLimit) 项）" }
        if childPage.totalCount > UInt64(childPage.items.count) {
            return "最大项目（显示前 \(childPage.items.count) / \(childPage.totalCount) 项）"
        }
        return "最大项目（真实快照，最多 \(childPageLimit) 项）"
    }

    /// Whether Full Disk Access guidance should be offered.
    public var showsPermissionHelp: Bool { permissionLimited }

    // MARK: User actions

    /// Clears a path-free scan/startup error after the user acknowledges it.
    /// The underlying phase is preserved so results stay browsable.
    public func dismissUserError() {
        userError = nil
    }

    /// Clears a reveal-in-Finder failure message.
    public func dismissRevealError() {
        revealError = nil
    }

    /// Retries the snapshot read after a scene error. The error text is kept
    /// until a new read actually succeeds, so the UI never claims success early.
    public func retrySceneLoad() {
        scheduleSceneRefresh(force: true)
    }

    /// Presents the open panel and, on success, adopts the selection and starts
    /// a scan. Cancelling the panel is not an error and restores the previous
    /// stable phase exactly.
    public func chooseRoot(initialURL: URL? = nil) async {
        guard !isShutDown, !isChoosingRoot else { return }
        isChoosingRoot = true
        defer { isChoosingRoot = false }
        if isScanning { await cancelScan() }
        let previous = phase
        phase = .choosingRoot
        let picked = await directoryAccess.pickDirectory(initialURL: initialURL)
        guard let picked else {
            // Restore the captured stable state, keeping e.g. `.failed` and its
            // path-free error, `.permissionLimited`, or `.cancelled` intact.
            phase = stablePhase(fallback: previous)
            return
        }
        await adopt(selection: picked)
    }

    /// Starts (or restarts) a scan for the current selection.
    public func startScan() async {
        guard !isShutDown, let selection else { return }
        if isScanning { await cancelScan() }
        // A rescan reuses the plan resolved for this selection so one session
        // cannot drift between two plans.
        let plan = volumePlan ?? planner.plan(for: selection)
        beginScan(selection: selection, plan: plan)
    }

    /// Re-runs the current selection.
    public func rescan() async {
        guard canRescan, let selection else { return }
        beginScan(selection: selection, plan: volumePlan ?? planner.plan(for: selection),
                  preservingResults: scanID != nil && treemapScene != nil)
    }

    /// Requests engine cancellation and waits for the runner to settle,
    /// preserving the cancelled snapshot.
    public func cancelScan() async {
        guard phase.isActive else { return }
        phase = .cancelling
        await cancelAndWait()
        if phase == .cancelling { phase = .cancelled }
    }

    /// Cancels any scan, releases the security scope, closes repositories and
    /// stops background tasks. Safe to call more than once.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        await cancelAndWait()
        releaseScope()
        stopPump()
        stopSceneRefresh()
        buffer.clearImmediateWake()
        // The session-only plan (and its path) must not linger after shutdown.
        volumePlan = nil
        await shutdownHandler()
    }

    // MARK: Scan lifecycle

    private func adopt(selection: DirectorySelection) async {
        await cancelAndWait()
        releaseScope()
        self.selection = selection
        scopeActive = directoryAccess.startAccess(for: selection)
        rootDisplayName = selection.displayName
        // Resolve the plan once per new selection using public volume facts.
        let plan = planner.plan(for: selection)
        beginScan(selection: selection, plan: plan)
    }

    private func beginScan(selection: DirectorySelection, plan: VolumeScanPlan, preservingResults: Bool = false) {
        let retainedID = preservingResults ? scanID : nil
        if preservingResults {
            stopSceneRefresh()
            refreshBackup = (phase, progress)
            isRefreshing = true
            refreshMetadata = nil
            refreshRevision = nil
            progress = nil
            userError = nil
        } else {
            resetScanState()
        }
        refreshMessage = nil
        volumePlan = plan
        refreshGeneration += 1
        phase = .preparing
        buffer.reset()
        scanFinished = false
        startPump()
        let request = plan.makeScanRequest(workspaceExclusions: workspaceExclusions)
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        let buffer = self.buffer
        let repository = self.repository
        let task = Task.detached(priority: .userInitiated) { () throws -> ScanSummary in
            await repository.retainForRefresh(retainedID)
            return try await runner.run(request) { update in
                buffer.deliver(update)
            }
        }
        runnerTask = task
        scanTask = Task { @MainActor [weak self] in
            let result: Result<ScanSummary, any Error>
            do {
                result = .success(try await task.value)
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.drain()
            await self.finishScan(result)
        }
    }

    /// Cancels the running scan (if any) and waits for it to settle. The
    /// security scope is intentionally left active so results remain usable.
    private func cancelAndWait() async {
        guard let runnerTask else { return }
        let activeID = isRefreshing ? refreshMetadata?.scanID : scanID
        if let activeID {
            await engine.cancel(scanID: activeID)
        }
        let engineCancelRequested = activeID != nil
        if !engineCancelRequested {
            // Cancellation before `.started`: cancel the consumer so the
            // stream terminates and the coordinator releases its workers.
            runnerTask.cancel()
        }
        var finished = await awaitScanCompletion(seconds: cancelGracePeriod)
        if !finished {
            runnerTask.cancel()
            finished = await awaitScanCompletion(seconds: cancelGracePeriod)
        }
        _ = finished
        await scanTask?.value
        scanTask = nil
        self.runnerTask = nil
        stopPump()
        drain()
    }

    private func awaitScanCompletion(seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !scanFinished {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    private func finishScan(_ result: Result<ScanSummary, any Error>) async {
        stopPump()
        if isRefreshing {
            await finishRefresh(result)
            runnerTask = nil
            scanTask = nil
            scanFinished = true
            return
        }
        runnerTask = nil
        scanTask = nil
        switch result {
        case .success(let summary):
            self.summary = summary
            // A successful terminal (including a synthesized forced cancel) is
            // not an error; never leave a stale path-free error on screen.
            userError = nil
            if let volume = summary.volume { self.volume = volume }
            issueCount = max(issueCount, summary.issueCount)
            switch summary.status {
            case .cancelled:
                phase = .cancelled
            case .completed:
                phase = permissionLimited ? .permissionLimited : .completed
            case .failed:
                phase = .failed
            case .running, .cancelling, .interrupted:
                phase = permissionLimited ? .permissionLimited : .completed
            }
        case .failure(let error):
            let classified = AppUserError.classify(error)
            userError = classified
            if classified == .rootPermissionDenied {
                permissionLimited = true
                phase = .permissionLimited
            } else {
                phase = .failed
            }
        }
        scheduleRefresh(force: true)
        scheduleIssueRefresh()
        scheduleSceneRefresh(force: true)
        scanFinished = true
    }

    private func finishRefresh(_ result: Result<ScanSummary, any Error>) async {
        let backup = refreshBackup
        defer {
            isRefreshing = false
            isReplacingSnapshot = false
            refreshBackup = nil
            refreshMetadata = nil
            refreshRevision = nil
        }
        // An interrupted replacement must not destroy a previously complete map.
        guard case .success(let newSummary) = result,
              newSummary.status == .completed,
              phase != .cancelling, !isShutDown,
              let metadata = refreshMetadata, let oldScan = scanID else {
            phase = backup?.phase ?? .completed
            progress = backup?.progress
            if case .failure(let error) = result, !(error is CancellationError) {
                userError = AppUserError.classify(error)
                refreshMessage = "刷新失败 · 已保留上次结果"
            } else {
                refreshMessage = "刷新已取消 · 已保留上次结果"
            }
            return
        }
        isReplacingSnapshot = true
        stopSceneRefresh()
        do {
            // Capture the location at completion, not at refresh start: the
            // user can keep browsing the retained snapshot while scanning.
            let components = try await relativeNameBytes(scanID: oldScan, nodeID: currentNodeID)
            let selectedComponents = try await relativeNameBytes(scanID: oldScan, nodeID: selectedNodeID)
            var path = [SnapshotPathItem(nodeID: metadata.rootNodeID,
                                         name: rootDisplayName ?? "", kind: .directory)]
            var focus = metadata.rootNodeID
            for bytes in components {
                guard let child = try await sceneLoader.child(named: bytes, parent: focus, scanID: metadata.scanID),
                      child.kind.isDirectoryLike else { break }
                focus = child.id
                path.append(SnapshotPathItem(nodeID: child.id,
                                             name: String(decoding: bytes, as: UTF8.self), kind: child.kind))
            }
            let token = SceneQueryToken(generation: refreshGeneration, scanID: metadata.scanID,
                focus: focus, expansionVersion: expansionVersion + 1,
                expansionSet: [], suppressedPreview: [], isTerminal: true)
            guard let scene = await Self.buildScene(loader: sceneLoader, token: token,
                focusName: path.last?.name ?? "", focusKind: path.last?.kind ?? .directory,
                rootDisplayName: rootDisplayName ?? "", previewLimit: previewExpandedLimit,
                previewPageLimit: previewPageLimit) else { throw AppRefreshError.sceneUnavailable }
            let limited = try await loader.isPermissionLimited(scanID: metadata.scanID)
            var restoredSelection: NodeID?
            if !selectedComponents.isEmpty {
                var parent = metadata.rootNodeID
                var found = true
                for bytes in selectedComponents {
                    guard let child = try await sceneLoader.child(named: bytes, parent: parent, scanID: metadata.scanID) else {
                        found = false; break
                    }
                    parent = child.id
                }
                if found { restoredSelection = parent }
            }
            guard phase != .cancelling, !isShutDown else { throw CancellationError() }
            let oldBytes = summary?.rootAttributedBytes
            // No suspension from here to the completed replacement state.
            scanID = metadata.scanID
            rootNodeID = metadata.rootNodeID
            currentNodeID = focus
            breadcrumbs = path
            navigationHistory = path.map(\.nodeID)
            historyIndex = navigationHistory.count - 1
            expandedNodeIDs = []
            suppressedPreviewNodeIDs = []
            expansionVersion += 1
            selectedNodeID = restoredSelection
            selectedItem = restoredSelection.flatMap { scene.item($0) }
            if selectedItem == nil { selectedNodeID = nil }
            selectedAggregate = selectedNodeID.flatMap { scene.knownAggregate(for: $0) }
            selectedOther = nil
            selectionToken += 1
            revealError = nil
            treemapScene = scene.withDetailMode(detailMode)
            sceneRevision = scene.revision
            sceneError = nil
            committedRevision = refreshRevision
            childPage = nil
            summary = newSummary
            if let volume = newSummary.volume { self.volume = volume }
            issueCount = newSummary.issueCount
            permissionLimited = limited
            phase = limited ? .permissionLimited : .completed
            userError = nil
            if let oldBytes, oldBytes > newSummary.rootAttributedBytes {
                refreshMessage = "已更新 · 扫描范围减少 \(ByteFormatting.bytes(oldBytes - newSummary.rootAttributedBytes))"
            } else {
                refreshMessage = "已更新 · \(components.count > path.count - 1 ? "原目录已不存在，返回上级" : "当前位置已保留")"
            }
            scheduleRefresh(force: true)
            isReplacingSnapshot = false
            if let selectedNodeID { requestAggregateRefresh(nodeID: selectedNodeID) }
        } catch {
            phase = backup?.phase ?? .completed
            progress = backup?.progress
            refreshMessage = error is CancellationError
                ? "刷新已取消 · 已保留上次结果" : "无法读取新结果 · 已保留上次结果"
            if !(error is CancellationError) { userError = AppUserError.classify(error) }
        }
    }

    private enum AppRefreshError: Error { case sceneUnavailable }

    /// Session-only raw names, not persisted paths; preserves invalid UTF-8.
    private func relativeNameBytes(scanID: ScanID, nodeID: NodeID?) async throws -> [Data] {
        guard let nodeID else { return [] }
        let chain = try await sceneLoader.ancestors(scanID: scanID, nodeID: nodeID)
        var names: [Data] = []
        for node in chain.dropFirst() {
            guard let name = try await sceneLoader.name(id: node.name, scanID: scanID) else {
                throw AppRefreshError.sceneUnavailable
            }
            names.append(name.utf8)
        }
        return names
    }

    // MARK: Update application (10 Hz)

    /// Applies the newest pending update per channel. Internal for tests.
    func drain() {
        let pending = buffer.takePending()
        if isRefreshing {
            if let metadata = pending.started {
                refreshMetadata = metadata
                if phase == .preparing { phase = .scanning }
            }
            if let progress = pending.progress { self.progress = progress }
            if let revision = pending.committedRevision { refreshRevision = revision }
            // Do not attach new-scan facts to old-scan IDs or reload the old
            // scene for each new commit. Replacement happens atomically below.
            return
        }
        if let metadata = pending.started {
            scanID = metadata.scanID
            rootNodeID = metadata.rootNodeID
            if let volume = metadata.volume { self.volume = volume }
            if currentNodeID == nil {
                currentNodeID = metadata.rootNodeID
                navigationHistory = [metadata.rootNodeID]
                historyIndex = 0
                breadcrumbs = [
                    SnapshotPathItem(
                        nodeID: metadata.rootNodeID,
                        name: rootDisplayName ?? metadata.request.root.displayName,
                        kind: .directory
                    )
                ]
            }
            if phase == .preparing || phase == .ready { phase = .scanning }
            scheduleSceneRefresh(force: true)
        }
        if let progress = pending.progress {
            self.progress = progress
            if phase == .preparing { phase = .scanning }
        }
        if let revision = pending.committedRevision {
            committedRevision = revision
            scheduleRefresh(force: false)
            scheduleSceneRefresh(force: false)
        }
        if let total = pending.issueTotalCount {
            issueCount = total
        }
        if let terminal = pending.terminal {
            summary = terminal
            if let volume = terminal.volume { self.volume = volume }
            issueCount = max(issueCount, terminal.issueCount)
            switch terminal.status {
            case .cancelled:
                phase = .cancelled
            case .completed:
                phase = permissionLimited ? .permissionLimited : .completed
            case .failed:
                phase = .failed
            case .running, .cancelling, .interrupted:
                phase = permissionLimited ? .permissionLimited : .completed
            }
            scheduleRefresh(force: true)
            scheduleIssueRefresh()
            scheduleSceneRefresh(force: true)
        }
    }

    private func startPump() {
        pumpTask?.cancel()
        pumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                self.drain()
            }
        }
    }

    private func stopPump() {
        pumpTask?.cancel()
        pumpTask = nil
    }

    // MARK: Bounded snapshot refresh

    private func scheduleRefresh(force: Bool) {
        guard let scanID, let rootNodeID else { return }
        if refreshInFlight {
            refreshPending = true
            return
        }
        refreshInFlight = true
        let generation = refreshGeneration
        let loader = self.loader
        let limit = childPageLimit
        Task { @MainActor [weak self] in
            let page = try? await loader.loadChildren(
                scanID: scanID,
                nodeID: rootNodeID,
                limit: limit
            )
            guard let self else { return }
            if generation == self.refreshGeneration, let page {
                self.childPage = page
            }
            self.refreshInFlight = false
            if self.refreshPending {
                self.refreshPending = false
                self.scheduleRefresh(force: false)
            }
        }
    }

    private func scheduleIssueRefresh() {
        guard let scanID else { return }
        let generation = refreshGeneration
        let loader = self.loader
        Task { @MainActor [weak self] in
            let limited = (try? await loader.isPermissionLimited(scanID: scanID)) ?? false
            guard let self else { return }
            guard generation == self.refreshGeneration else { return }
            if limited {
                self.permissionLimited = true
                if self.phase == .completed { self.phase = .permissionLimited }
            }
        }
    }

    /// Generation guard used by tests: a refresh captured with an older
    /// generation must not overwrite newer state.
    func acceptsRefresh(generation: Int) -> Bool {
        generation == refreshGeneration
    }

    /// Test hook exposing the current refresh generation.
    var refreshGenerationForTesting: Int { refreshGeneration }

    // MARK: Treemap navigation

    /// Whether a previous focus exists in this scan's history.
    public var canGoBack: Bool { !isReplacingSnapshot && historyIndex > 0 }

    /// Whether the breadcrumb path has a parent of the current focus.
    public var canGoUp: Bool { !isReplacingSnapshot && breadcrumbs.count > 1 }

    /// Number of direct children currently shown in the focus page.
    public var visibleItemCount: Int { treemapScene?.focusPage.items.count ?? 0 }

    /// Monotonic root/scan generation, used by the layout key.
    public var sceneGeneration: Int { refreshGeneration }

    /// Whether the scan has reached a terminal phase.
    public var isTerminal: Bool { isTerminalPhase() }

    /// Selects a real scene item. Blocked while the displayed map belongs to a
    /// different focus (a retained old map being replaced), so a stale tile can
    /// never create a new selection.
    public func select(_ item: TreemapSceneItem) {
        guard !isSceneStale else { return }
        selectionToken += 1
        revealError = nil
        selectedOther = nil
        selectedNodeID = item.nodeID
        selectedItem = item
        // Seed from the scene when the directory's own page is already loaded;
        // otherwise a bounded refresh fills it in.
        selectedAggregate = treemapScene?.knownAggregate(for: item.nodeID)
        requestAggregateRefresh(nodeID: item.nodeID)
    }

    /// Selects a synthetic "other" tile. It carries no node identity, so it can
    /// never trigger Finder or directory navigation.
    public func selectOther(parentID: NodeID, collapsedCount: UInt64, effectiveBytes: UInt64) {
        guard !isSceneStale else { return }
        selectionToken += 1
        invalidateAggregateQuery()
        revealError = nil
        selectedOther = TreemapOtherSelection(
            parentID: parentID,
            collapsedCount: collapsedCount,
            effectiveBytes: effectiveBytes
        )
        selectedNodeID = nil
        selectedItem = nil
        selectedAggregate = nil
    }

    /// Selects a node already present in the scene, if known. Blocked while the
    /// map is stale for the current focus.
    public func selectNode(_ nodeID: NodeID) {
        guard !isSceneStale else { return }
        guard let item = treemapScene?.item(nodeID) else {
            selectionToken += 1
            invalidateAggregateQuery()
            selectedOther = nil
            selectedNodeID = nodeID
            selectedItem = nil
            selectedAggregate = nil
            return
        }
        select(item)
    }

    /// Clears the current selection.
    public func clearSelection() {
        selectionToken += 1
        invalidateAggregateQuery()
        selectedNodeID = nil
        selectedItem = nil
        selectedAggregate = nil
        selectedOther = nil
        revealError = nil
    }

    /// Compact, path-free status for children omitted by the query limit whose
    /// weight is not yet known. No fake area is drawn for them.
    public var hiddenOmittedMessage: String? {
        guard let count = treemapScene?.hiddenOmittedCount else { return nil }
        return progressWording.omittedItemsMessage(count: count)
    }

    /// Best-known effective bytes for the current selection, or `nil` when a
    /// selected directory's aggregate is unknown. A directory's scene weight is
    /// trusted when it is positive; a zero scene weight is only a real zero when
    /// an aggregate says so, otherwise it is unknown (never a fabricated 0).
    public var selectedEffectiveBytes: UInt64? {
        guard let item = selectedItem else { return nil }
        if !item.isDirectoryLike { return item.effectiveBytes }
        if let aggregate = selectedAggregate { return aggregate.attributedBytes }
        return item.effectiveBytes > 0 ? item.effectiveBytes : nil
    }

    /// Best-known effective bytes for one bounded-list row, or `nil` when a
    /// directory's aggregate is unknown. Files always have a known weight; a
    /// directory whose page is loaded can use its own aggregate; and a directory
    /// under a *completed* parent is final, so a zero scene weight there is a
    /// real zero rather than an unknown. A positive scene weight is always real
    /// evidence. No extra query is issued for any of these.
    public func listEffectiveBytes(for item: TreemapSceneItem) -> UInt64? {
        if !item.isDirectoryLike { return item.effectiveBytes }
        if let aggregate = treemapScene?.knownAggregate(for: item.nodeID) {
            return aggregate.attributedBytes
        }
        if item.effectiveBytes == 0,
           treemapScene?.containingPage(for: item.nodeID)?.aggregate?.isComplete == true {
            // The containing parent's complete aggregate proves this child's
            // statistics are final, so an observed zero is a known zero.
            return 0
        }
        return item.effectiveBytes > 0 ? item.effectiveBytes : nil
    }

    /// Path-free display path of the current selection relative to the scan
    /// root, built only from scan-local names. `nil` when the selection is not
    /// reachable from the current scene.
    public var selectedRelativePath: String? {
        if let other = selectedOther {
            return "其他（\(other.collapsedCount) 项）"
        }
        guard let nodeID = selectedNodeID,
              !isSceneStale,
              let scene = treemapScene,
              let relative = scene.displayPath(from: nodeID) else {
            return nil
        }
        let prefix = breadcrumbs.map(\.name).filter { !$0.isEmpty }
        var components = prefix
        components.append(contentsOf: relative)
        return components.joined(separator: " / ")
    }

    /// Switches overview/detail thresholds. Does not touch SQLite.
    public func setDetailMode(_ mode: TreemapDetailMode) {
        detailMode = mode
    }

    /// Expands a directory in place. Blocked while the map is stale so an old
    /// tile cannot mutate the new focus's expansion state. The ninth expansion
    /// evicts the earliest expanded directory that is not the current
    /// selection. An explicit expand also clears any earlier preview suppression.
    public func expand(_ nodeID: NodeID) {
        guard !isSceneStale else { return }
        if suppressedPreviewNodeIDs.contains(nodeID) {
            suppressedPreviewNodeIDs.removeAll { $0 == nodeID }
        }
        guard let item = treemapScene?.item(nodeID), item.isDirectoryLike else { return }
        guard !expandedNodeIDs.contains(nodeID) else { return }
        guard expandedNodeIDs.count < maximumExpandedCount else {
            if let victim = expandedNodeIDs.firstIndex(where: { $0 != selectedNodeID }) {
                expandedNodeIDs.remove(at: victim)
            } else if !expandedNodeIDs.isEmpty {
                expandedNodeIDs.removeFirst()
            }
            expandedNodeIDs.append(nodeID)
            expansionVersion += 1
            scheduleSceneRefresh(force: true)
            return
        }
        expandedNodeIDs.append(nodeID)
        expansionVersion += 1
        scheduleSceneRefresh(force: true)
    }

    /// Collapses a directory in place. A directory that was only shown by the
    /// automatic shallow preview is added to the suppressed set so the next
    /// scan refresh does not reopen it. A directory the user explicitly expanded
    /// and then collapsed is suppressed the same way.
    public func collapse(_ nodeID: NodeID) {
        guard !isSceneStale else { return }
        let wasExpanded = expandedNodeIDs.contains(nodeID)
            || treemapScene?.expandedPages[nodeID] != nil
        guard wasExpanded else { return }
        expandedNodeIDs.removeAll { $0 == nodeID }
        if !suppressedPreviewNodeIDs.contains(nodeID) {
            suppressedPreviewNodeIDs.append(nodeID)
        }
        expansionVersion += 1
        scheduleSceneRefresh(force: true)
    }

    /// Whether `nodeID` currently has children shown, either because the user
    /// expanded it or because of the automatic shallow preview.
    public func isExpanded(_ nodeID: NodeID) -> Bool {
        treemapScene?.expandedPages[nodeID] != nil
    }

    /// Whether `nodeID` is expanded only by the automatic preview (not by an
    /// explicit user expansion).
    public func isPreviewExpanded(_ nodeID: NodeID) -> Bool {
        !expandedNodeIDs.contains(nodeID) && treemapScene?.expandedPages[nodeID] != nil
    }

    /// Whether `nodeID` may be expanded (a directory-like item that is not
    /// already expanded).
    public func canExpand(_ nodeID: NodeID) -> Bool {
        guard let item = treemapScene?.item(nodeID) else { return false }
        return item.isDirectoryLike && !isExpanded(nodeID)
    }

    /// Enters a directory: resets in-place expansion and pushes history.
    public func enter(_ nodeID: NodeID) async {
        guard currentNodeID != nodeID else { return }
        await moveFocus(to: nodeID, pushHistory: true)
    }

    /// Jumps back one entry in this scan's navigation history.
    public func goBack() async {
        guard canGoBack else { return }
        historyIndex -= 1
        await moveFocus(to: navigationHistory[historyIndex], pushHistory: false)
    }

    /// Moves to the breadcrumb parent of the current focus, as a new history
    /// entry.
    public func goUp() async {
        guard breadcrumbs.count > 1 else { return }
        await moveFocus(to: breadcrumbs[breadcrumbs.count - 2].nodeID, pushHistory: true)
    }

    /// Enters one breadcrumb ancestor.
    public func navigate(to nodeID: NodeID) async {
        await enter(nodeID)
    }

    private func moveFocus(to nodeID: NodeID, pushHistory: Bool) async {
        guard !isReplacingSnapshot else { return }
        guard let scanID else { return }
        currentNodeID = nodeID
        expandedNodeIDs = []
        suppressedPreviewNodeIDs = []
        expansionVersion += 1
        selectionToken += 1
        invalidateAggregateQuery()
        selectedNodeID = nil
        selectedItem = nil
        selectedAggregate = nil
        selectedOther = nil
        revealError = nil
        if pushHistory {
            if historyIndex + 1 < navigationHistory.count {
                navigationHistory = Array(navigationHistory.prefix(historyIndex + 1))
            }
            navigationHistory.append(nodeID)
            historyIndex = navigationHistory.count - 1
        }
        await loadBreadcrumbs(scanID: scanID, nodeID: nodeID)
        scheduleSceneRefresh(force: true)
    }

    private func loadBreadcrumbs(scanID: ScanID, nodeID: NodeID) async {
        do {
            let nodes = try await sceneLoader.ancestors(scanID: scanID, nodeID: nodeID)
            var items: [SnapshotPathItem] = []
            items.reserveCapacity(nodes.count)
            for node in nodes {
                let fetched = (try? await sceneLoader.name(id: node.name, scanID: scanID)) ?? nil
                items.append(
                    SnapshotPathItem(
                        nodeID: node.id,
                        name: fetched?.decodedString ?? "",
                        kind: node.kind
                    )
                )
            }
            guard generationMatches(scanID: scanID), currentNodeID == nodeID else { return }
            breadcrumbs = items
        } catch {
            // Keep the previous breadcrumbs; the empty path is never worse than
            // a fabricated one.
        }
    }

    private func generationMatches(scanID: ScanID) -> Bool {
        self.scanID == scanID
    }

    /// Requests a bounded, single-flight aggregate refresh for `nodeID`.
    ///
    /// At most one query is in flight; a request while one is running marks it
    /// pending and runs once afterwards, so scene revisions can never spawn an
    /// unbounded number of tasks. Files have no aggregate row and clear it.
    private func requestAggregateRefresh(nodeID: NodeID) {
        guard let scanID, selectedNodeID == nodeID else { return }
        guard let item = selectedItem, item.isDirectoryLike else {
            selectedAggregate = nil
            return
        }
        if aggregateQueryTask != nil {
            aggregateQueryPending = true
            return
        }
        startAggregateQuery(scanID: scanID, nodeID: nodeID)
    }

    private func startAggregateQuery(scanID: ScanID, nodeID: NodeID) {
        aggregateQueryGeneration += 1
        let generation = aggregateQueryGeneration
        let loader = sceneLoader
        aggregateQueryTask = Task { @MainActor [weak self] in
            let aggregate = try? await loader.aggregate(scanID: scanID, nodeID: nodeID)
            guard let self else { return }
            // A superseded task may return after a newer query started (for
            // example a loader that ignores cancellation while blocked on
            // SQLite). It must not touch the new task handle, the pending flag
            // or the aggregate: check the generation before any bookkeeping.
            guard generation == self.aggregateQueryGeneration else { return }
            self.aggregateQueryTask = nil
            if self.selectedNodeID == nodeID {
                self.selectedAggregate = aggregate
            }
            if self.aggregateQueryPending {
                self.aggregateQueryPending = false
                self.requestAggregateRefresh(nodeID: nodeID)
            }
        }
    }

    /// Invalidates any in-flight aggregate query. Used by selection changes,
    /// navigation, a new scan, clear and shutdown so an old query can never
    /// overwrite a newer, complete aggregate.
    private func invalidateAggregateQuery() {
        aggregateQueryGeneration += 1
        aggregateQueryTask?.cancel()
        aggregateQueryTask = nil
        aggregateQueryPending = false
    }

    /// Refreshes the selected item and aggregate from a newly applied scene.
    ///
    /// The scene token already guarantees the same scan generation and focus.
    /// A loaded page for the selected directory carries its own aggregate, so
    /// that value wins and invalidates any slower in-flight query; otherwise the
    /// bounded refresh fetches just that directory.
    private func refreshSelectionFromScene(_ scene: TreemapSceneData) {
        guard selectedOther == nil, let nodeID = selectedNodeID else { return }
        if let item = scene.item(nodeID) {
            selectedItem = item
        }
        if let aggregate = scene.knownAggregate(for: nodeID) {
            aggregateQueryGeneration += 1
            aggregateQueryTask?.cancel()
            aggregateQueryTask = nil
            aggregateQueryPending = false
            selectedAggregate = aggregate
        } else if let item = selectedItem, item.isDirectoryLike {
            // Once the aggregate is final it cannot change, so a scene revision
            // does not need another query for this selection.
            if selectedAggregate?.isComplete != true {
                requestAggregateRefresh(nodeID: nodeID)
            }
        }
    }

    /// Resolves the selected node to a session-only file URL and verifies it
    /// still exists. Returns `nil` and records a path-free reason on failure.
    public func finderURLForSelection() async -> URL? {
        let token = selectionToken
        guard !isSceneStale else {
            revealError = "当前位置正在更新，请稍候再试"
            return nil
        }
        guard let scanID,
              let nodeID = selectedNodeID,
              let rootNodeID,
              let selection else {
            return nil
        }
        do {
            let nodes = try await sceneLoader.ancestors(scanID: scanID, nodeID: nodeID)
            var names: [NameRecord] = []
            names.reserveCapacity(nodes.count)
            for node in nodes {
                guard let record = try await sceneLoader.name(id: node.name, scanID: scanID) else {
                    throw RuntimePathResolverError.invalidChain
                }
                names.append(record)
            }
            let resolver = RuntimePathResolver(
                rootPath: selection.fileSystemPath,
                rootNodeID: rootNodeID
            )
            let url = try resolver.url(ancestorNodes: nodes, names: names)
            let path = url.path
            let exists = await Task.detached(priority: .userInitiated) {
                FileManager.default.fileExists(atPath: path)
            }.value
            guard token == selectionToken else { return nil }
            guard exists else {
                revealError = "项目已不存在或位置已变化"
                return nil
            }
            revealError = nil
            return url
        } catch {
            guard token == selectionToken else { return nil }
            revealError = "无法定位所选项目"
            return nil
        }
    }

    // MARK: Treemap scene refresh

    private func isTerminalPhase() -> Bool {
        switch isRefreshing ? refreshBackup?.phase ?? phase : phase {
        case .completed, .cancelled, .failed, .permissionLimited:
            return true
        case .idle, .choosingRoot, .ready, .preparing, .scanning, .cancelling:
            return false
        }
    }

    private func stopSceneRefresh() {
        sceneRefreshTask?.cancel()
        sceneRefreshTask = nil
        sceneQueryTask?.cancel()
        sceneQueryTask = nil
        sceneQuerySequence += 1
        activeSceneToken = nil
        sceneRefreshInFlight = false
        sceneRefreshPending = false
        // A new scan, shutdown or reset invalidates any in-flight aggregate
        // query so an old result cannot attach to a later selection.
        invalidateAggregateQuery()
    }

    /// Full data identity of a scene query: every model value whose change
    /// makes a captured result stale. Detail mode is deliberately excluded —
    /// it only changes layout thresholds, not which pages are read, so a mode
    /// toggle during an in-flight query must not strand the result.
    private struct SceneQueryToken: Equatable {
        let generation: Int
        let scanID: ScanID
        let focus: NodeID
        let expansionVersion: Int
        let expansionSet: [NodeID]
        let suppressedPreview: [NodeID]
        let isTerminal: Bool
    }

    private func currentSceneToken() -> SceneQueryToken? {
        guard let scanID, let focus = currentNodeID else { return nil }
        return SceneQueryToken(
            generation: refreshGeneration,
            scanID: scanID,
            focus: focus,
            expansionVersion: expansionVersion,
            expansionSet: expandedNodeIDs,
            suppressedPreview: suppressedPreviewNodeIDs.sorted { $0.rawValue < $1.rawValue },
            isTerminal: isTerminalPhase()
        )
    }

    private func scheduleSceneRefresh(force: Bool) {
        guard !isShutDown, let scanID, let focus = currentNodeID else { return }
        if sceneRefreshInFlight {
            sceneRefreshPending = true
            return
        }
        let interval: Double = expandedNodeIDs.isEmpty ? 0.25 : 0.5
        if !force, let last = lastSceneRefreshAt {
            let elapsed = last.duration(to: ContinuousClock.now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            if seconds < interval {
                if sceneRefreshTask == nil {
                    let remaining = max(0, interval - seconds)
                    sceneRefreshTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                        guard let self, !Task.isCancelled else { return }
                        self.sceneRefreshTask = nil
                        self.scheduleSceneRefresh(force: true)
                    }
                }
                return
            }
        }
        sceneRefreshTask?.cancel()
        sceneRefreshTask = nil
        startSceneRefresh(scanID: scanID, focus: focus)
    }

    private func startSceneRefresh(scanID: ScanID, focus: NodeID) {
        guard let token = currentSceneToken() else { return }
        sceneRefreshInFlight = true
        lastSceneRefreshAt = ContinuousClock.now
        sceneQuerySequence += 1
        let sequence = sceneQuerySequence
        activeSceneToken = token
        let loader = sceneLoader
        let display = rootDisplayName ?? ""
        let focusName = breadcrumbs.last?.name ?? display
        let focusKind = breadcrumbs.last?.kind ?? .directory
        let previewLimit = previewExpandedLimit
        let previewPageLimit = previewPageLimit
        sceneQueryTask = Task { @MainActor [weak self] in
            let scene = await AppModel.buildScene(
                loader: loader,
                token: token,
                focusName: focusName,
                focusKind: focusKind,
                rootDisplayName: display,
                previewLimit: previewLimit,
                previewPageLimit: previewPageLimit
            )
            guard let self else { return }
            // A newer query superseded this one; it must not touch any state.
            guard sequence == self.sceneQuerySequence else { return }
            self.sceneQueryTask = nil
            self.activeSceneToken = nil
            self.sceneRefreshInFlight = false
            // The result is only applied while every captured data value still
            // matches the live model.
            if self.currentSceneToken() == token {
                if let scene {
                    // Re-stamp the live detail mode: the query itself is
                    // mode-independent, so a toggle during the read must not
                    // leave a stale scene or strand the update.
                    self.treemapScene = scene.withDetailMode(self.detailMode)
                    self.sceneRevision = scene.revision
                    self.sceneError = nil
                    // Keep the current real selection in sync with the new
                    // scene: its item weight and (when its page is loaded) its
                    // aggregate update without the user re-selecting.
                    self.refreshSelectionFromScene(scene)
                } else {
                    self.sceneError = "无法读取快照；已保留上一版地图"
                }
            }
            if self.sceneRefreshPending {
                self.sceneRefreshPending = false
                self.scheduleSceneRefresh(force: true)
            }
        }
    }

    nonisolated private static func buildScene(
        loader: SnapshotLoader,
        token: SceneQueryToken,
        focusName: String,
        focusKind: NodeKind,
        rootDisplayName: String,
        previewLimit: Int,
        previewPageLimit: Int
    ) async -> TreemapSceneData? {
        do {
            let focusPage = try await loader.loadChildren(
                scanID: token.scanID,
                nodeID: token.focus,
                limit: 500
            )
            var expanded: [NodeID: TreemapScenePage] = [:]
            var maxRevision = focusPage.snapshotRevision
            for id in token.expansionSet {
                let page = try await loader.loadChildren(
                    scanID: token.scanID,
                    nodeID: id,
                    limit: 200
                )
                maxRevision = max(maxRevision, page.snapshotRevision)
                expanded[id] = TreemapScenePage.make(from: page, parentID: id)
            }
            // Bounded shallow preview: open the largest directory-like focus
            // children so the first screen already shows two levels, without
            // ever reading the whole tree. User expansions and explicit
            // preview suppressions always win.
            let suppressed = Set(token.suppressedPreview)
            let userExpanded = Set(token.expansionSet)
            let previewCandidates = focusPage.items
                .filter { item in
                    item.node.kind.isDirectoryLike
                        && item.effectiveAttributedBytes > 0
                        && !userExpanded.contains(item.node.id)
                        && !suppressed.contains(item.node.id)
                }
                .sorted { lhs, rhs in
                    if lhs.effectiveAttributedBytes != rhs.effectiveAttributedBytes {
                        return lhs.effectiveAttributedBytes > rhs.effectiveAttributedBytes
                    }
                    return lhs.node.id.rawValue < rhs.node.id.rawValue
                }
                .prefix(previewLimit)
            var previewOrder: [NodeID] = []
            for item in previewCandidates {
                let id = item.node.id
                let page = try await loader.loadChildren(
                    scanID: token.scanID,
                    nodeID: id,
                    limit: previewPageLimit
                )
                maxRevision = max(maxRevision, page.snapshotRevision)
                expanded[id] = TreemapScenePage.make(from: page, parentID: id)
                previewOrder.append(id)
            }
            return TreemapSceneData(
                scanID: token.scanID,
                scanGeneration: token.generation,
                revision: maxRevision,
                focusNodeID: token.focus,
                focusName: focusName,
                focusKind: focusKind,
                focusAggregate: focusPage.parentAggregate,
                focusPage: TreemapScenePage.make(from: focusPage, parentID: token.focus),
                expandedPages: expanded,
                expansionOrder: token.expansionSet + previewOrder,
                expansionVersion: token.expansionVersion,
                // Stamped with the live mode when the result is applied.
                detailMode: .overview,
                isTerminal: token.isTerminal,
                rootDisplayName: rootDisplayName
            )
        } catch {
            return nil
        }
    }

    // MARK: Helpers

    private func resetScanState() {
        isRefreshing = false
        isReplacingSnapshot = false
        refreshBackup = nil
        refreshMetadata = nil
        refreshRevision = nil
        refreshMessage = nil
        stopSceneRefresh()
        scanID = nil
        rootNodeID = nil
        progress = nil
        summary = nil
        volume = nil
        issueCount = 0
        permissionLimited = false
        childPage = nil
        committedRevision = nil
        userError = nil
        currentNodeID = nil
        breadcrumbs = []
        navigationHistory = []
        historyIndex = -1
        selectedNodeID = nil
        selectedItem = nil
        selectedAggregate = nil
        selectedOther = nil
        expandedNodeIDs = []
        suppressedPreviewNodeIDs = []
        expansionVersion = 0
        treemapScene = nil
        sceneRevision = nil
        sceneError = nil
        revealError = nil
        volumePlan = nil
        selectionToken += 1
    }

    private func releaseScope() {
        if scopeActive, let selection {
            directoryAccess.stopAccess(for: selection)
        }
        scopeActive = false
    }

    private func stablePhase(fallback: AppPhase) -> AppPhase {
        // `chooseRoot()` captures the phase only after cancelling any active
        // scan, so the fallback is already a stable state. Restore it exactly;
        // do not recompute from `rootDisplayName`, which would turn a failed
        // scan back into `.ready` and leave a stale error on screen.
        if fallback == .choosingRoot {
            return rootDisplayName != nil ? .ready : .idle
        }
        return fallback
    }

    /// Test hook: waits until the current scan's finalizer has run.
    func waitForScanToFinish() async {
        await scanTask?.value
    }

    /// Test hook: forces a scene re-read without changing navigation, so tests
    /// can prove preview suppression survives a scan refresh.
    func reloadSceneForTesting() {
        scheduleSceneRefresh(force: true)
    }
}
