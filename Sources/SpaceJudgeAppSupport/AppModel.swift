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

    /// One-line capacity summary; unknown values render as em dashes.
    public var capacityLine: String { ByteFormatting.capacityLine(volume) }

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

    /// Presents the open panel and, on success, adopts the selection and starts
    /// a scan. Cancelling the panel is not an error and restores the previous
    /// stable phase exactly.
    public func chooseRoot() async {
        guard !isShutDown, !isChoosingRoot else { return }
        isChoosingRoot = true
        defer { isChoosingRoot = false }
        if isScanning { await cancelScan() }
        let previous = phase
        phase = .choosingRoot
        let picked = await directoryAccess.pickDirectory()
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
        await startScan()
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

    private func beginScan(selection: DirectorySelection, plan: VolumeScanPlan) {
        resetScanState()
        volumePlan = plan
        refreshGeneration += 1
        phase = .preparing
        buffer.reset()
        scanFinished = false
        startPump()
        let request = plan.makeScanRequest(workspaceExclusions: workspaceExclusions)
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        let buffer = self.buffer
        let task = Task.detached(priority: .userInitiated) { () throws -> ScanSummary in
            try await runner.run(request) { update in
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
            self.finishScan(result)
        }
    }

    /// Cancels the running scan (if any) and waits for it to settle. The
    /// security scope is intentionally left active so results remain usable.
    private func cancelAndWait() async {
        guard let runnerTask else { return }
        if let scanID {
            await engine.cancel(scanID: scanID)
        }
        let engineCancelRequested = scanID != nil
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

    private func finishScan(_ result: Result<ScanSummary, any Error>) {
        stopPump()
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

    // MARK: Update application (10 Hz)

    /// Applies the newest pending update per channel. Internal for tests.
    func drain() {
        let pending = buffer.takePending()
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
    public var canGoBack: Bool { historyIndex > 0 }

    /// Whether the breadcrumb path has a parent of the current focus.
    public var canGoUp: Bool { breadcrumbs.count > 1 }

    /// Number of direct children currently shown in the focus page.
    public var visibleItemCount: Int { treemapScene?.focusPage.items.count ?? 0 }

    /// Monotonic root/scan generation, used by the layout key.
    public var sceneGeneration: Int { refreshGeneration }

    /// Whether the scan has reached a terminal phase.
    public var isTerminal: Bool { isTerminalPhase() }

    /// Selects a real scene item.
    public func select(_ item: TreemapSceneItem) {
        selectedOther = nil
        selectedNodeID = item.nodeID
        selectedItem = item
        loadSelectedAggregate()
    }

    /// Selects a synthetic "other" tile. It carries no node identity, so it can
    /// never trigger Finder or directory navigation.
    public func selectOther(parentID: NodeID, collapsedCount: UInt64, effectiveBytes: UInt64) {
        selectionToken += 1
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

    /// Selects a node already present in the scene, if known.
    public func selectNode(_ nodeID: NodeID) {
        guard let item = treemapScene?.item(nodeID) else {
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
        selectedNodeID = nil
        selectedItem = nil
        selectedAggregate = nil
        selectedOther = nil
        revealError = nil
    }

    /// Compact, path-free status for children omitted by the query limit whose
    /// weight is not yet known. No fake area is drawn for them.
    public var hiddenOmittedMessage: String? {
        guard let count = treemapScene?.hiddenOmittedCount, count > 0 else { return nil }
        return "还有 \(count) 项正在统计"
    }

    /// Path-free display path of the current selection relative to the scan
    /// root, built only from scan-local names. `nil` when the selection is not
    /// reachable from the current scene.
    public var selectedRelativePath: String? {
        if let other = selectedOther {
            return "其他（\(other.collapsedCount) 项）"
        }
        guard let nodeID = selectedNodeID,
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

    /// Expands a directory in place. The ninth expansion evicts the earliest
    /// expanded directory that is not the current selection.
    public func expand(_ nodeID: NodeID) {
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

    /// Collapses a previously expanded directory.
    public func collapse(_ nodeID: NodeID) {
        guard let index = expandedNodeIDs.firstIndex(of: nodeID) else { return }
        expandedNodeIDs.remove(at: index)
        expansionVersion += 1
        scheduleSceneRefresh(force: true)
    }

    /// Enters a directory: resets in-place expansion and pushes history.
    public func enter(_ nodeID: NodeID) async {
        guard currentNodeID != nodeID else { return }
        await moveFocus(to: nodeID, pushHistory: true)
    }

    /// Jumps back one entry in this scan's navigation history.
    public func goBack() async {
        guard historyIndex > 0 else { return }
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
        guard let scanID else { return }
        currentNodeID = nodeID
        expandedNodeIDs = []
        expansionVersion += 1
        selectionToken += 1
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

    private func loadSelectedAggregate() {
        selectionToken += 1
        let token = selectionToken
        revealError = nil
        guard let scanID,
              let item = selectedItem,
              item.isDirectoryLike else {
            selectedAggregate = nil
            return
        }
        selectedAggregate = nil
        let nodeID = item.nodeID
        let loader = sceneLoader
        Task { @MainActor [weak self] in
            let aggregate = try? await loader.aggregate(scanID: scanID, nodeID: nodeID)
            guard let self, token == self.selectionToken, self.selectedNodeID == nodeID else { return }
            self.selectedAggregate = aggregate
        }
    }

    /// Resolves the selected node to a session-only file URL and verifies it
    /// still exists. Returns `nil` and records a path-free reason on failure.
    public func finderURLForSelection() async -> URL? {
        let token = selectionToken
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
        switch phase {
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
        sceneQueryTask = Task { @MainActor [weak self] in
            let scene = await AppModel.buildScene(
                loader: loader,
                token: token,
                focusName: focusName,
                focusKind: focusKind,
                rootDisplayName: display
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
        rootDisplayName: String
    ) async -> TreemapSceneData? {
        do {
            let focusPage = try await loader.loadChildren(
                scanID: token.scanID,
                nodeID: token.focus,
                limit: 500
            )
            var expanded: [NodeID: TreemapScenePage] = [:]
            for id in token.expansionSet {
                let page = try await loader.loadChildren(
                    scanID: token.scanID,
                    nodeID: id,
                    limit: 200
                )
                expanded[id] = TreemapScenePage.make(from: page, parentID: id)
            }
            return TreemapSceneData(
                scanID: token.scanID,
                scanGeneration: token.generation,
                revision: focusPage.snapshotRevision,
                focusNodeID: token.focus,
                focusName: focusName,
                focusKind: focusKind,
                focusAggregate: focusPage.parentAggregate,
                focusPage: TreemapScenePage.make(from: focusPage, parentID: token.focus),
                expandedPages: expanded,
                expansionOrder: token.expansionSet,
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
}
