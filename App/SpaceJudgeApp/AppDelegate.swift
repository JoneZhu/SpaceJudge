import AppKit
import Foundation
import SpaceJudgeAppSupport
import SpaceJudgeScan
import SpaceJudgeStore

/// Owns app lifecycle, the async database bootstrap and the single
/// `AppModel`.
///
/// Repositories are opened off the main thread by a detached task and only then
/// handed to the MainActor model, so the main thread never creates a SQLite
/// connection. Shutdown always cancels the scan, releases the security scope
/// and closes both connections.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, ObservableObject {
    @Published private(set) var model: AppModel?
    @Published private(set) var bootstrapError: String?
    /// True while the database bootstrap is in flight, so the retry entry can
    /// be disabled and the UI shows a preparing state instead of a stale error.
    @Published private(set) var isBootstrapping = false
    /// Live enablement policy for the menu bar.
    ///
    /// The `AppModel` is `@Observable` while this delegate is `ObservableObject`,
    /// so a menu cannot observe the model directly. The delegate mirrors the
    /// model's shared `AppCommandPolicy` into a `@Published` value and keeps it
    /// current with `withObservationTracking`, giving the Commands a real
    /// dynamic dependency on both lifecycle levels.
    @Published private(set) var commandPolicy = AppCommandPolicy.unavailable

    private var shutdownRequested = false
    /// Set as soon as termination starts; a late bootstrap result is discarded
    /// (and its connections closed) instead of being applied after quit.
    private var isTerminating = false
    private var bootstrapGate = BootstrapGate()
    /// AppKit menu items installed by `installScanMenu()`.
    private var scanMenuItems: (choose: NSMenuItem, rescan: NSMenuItem)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        applyDebugSeams()
        #endif
        installScanMenu()
#if DEBUG
        if ProcessInfo.processInfo.environment["SPACEJUDGE_TEST_MENU_SELFTEST"] == "1" {
            scheduleMenuSelfTest()
        }
#endif
        Task { @MainActor in
            await self.bootstrap()
        }
    }

#if DEBUG
    /// Pi-only self-test: after the scan settles, post the ⌘R key equivalent to
    /// the app's own main menu and log whether the wired action fires. This does
    /// not depend on OS activation, so it verifies the AppKit menu wiring while
    /// another SpaceJudge instance is frontmost.
    private func scheduleMenuSelfTest() {
        for delay in [3.0, 20.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: 0, context: nil,
                    characters: "r", charactersIgnoringModifiers: "r",
                    isARepeat: false, keyCode: 15
                )
                let handled = event.map { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false }
                FileHandle.standardError.write(Data(
                    "MENUSELFTEST t=\(delay) handled=\(handled ?? false) rescanEnabled=\(self.scanMenuItems?.rescan.isEnabled ?? false)\n".utf8
                ))
            }
        }
    }
#endif

#if DEBUG
    /// Pi/Codex-only verification seams. Never compiled into Release, so they
    /// cannot change a real user's appearance or window size.
    private func applyDebugSeams() {
        let environment = ProcessInfo.processInfo.environment
        switch environment["SPACEJUDGE_TEST_APPEARANCE"]?.lowercased() {
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        default:
            break
        }
        guard let raw = environment["SPACEJUDGE_TEST_WINDOW_SIZE"],
              let size = Self.parseWindowSize(raw) else { return }
        var attempts = 0
        func resize() {
            if let window = NSApp.windows.first {
                window.setContentSize(size)
                window.center()
            } else if attempts < 20 {
                attempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { resize() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { resize() }
    }

    /// Parses `WIDTHxHEIGHT` in points. Returns `nil` for anything unsafe.
    private static func parseWindowSize(_ raw: String) -> NSSize? {
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width >= 320, height >= 240, width <= 20_000, height <= 20_000 else {
            return nil
        }
        return NSSize(width: width, height: height)
    }
#endif

    /// Retries the database bootstrap after a startup failure. Guarded so a
    /// rapid double activation cannot open two repository pairs: the gate
    /// rejects every call while one bootstrap is already running.
    func retryBootstrap() async {
        guard model == nil, !isTerminating, !bootstrapGate.isRunning else { return }
        // Replace the stale failure with a preparing state immediately.
        bootstrapError = nil
        await bootstrap()
    }

    private func bootstrap() async {
        guard bootstrapGate.begin() else { return }
        isBootstrapping = true
        defer {
            isBootstrapping = false
            bootstrapGate.end()
        }
        do {
            let repositories = try await Self.bootstrapRepositories()
            // A result that arrives after termination must not resurrect the
            // app: close the late connections and drop it.
            guard !isTerminating else {
                await repositories.reader.close()
                await repositories.writer.close()
                return
            }
            let writer = repositories.writer
            let reader = repositories.reader
            var scanConfiguration = ScanConfiguration(
                spoolDirectory: repositories.workspace.spoolDirectoryURL,
                progressiveDirectoryLimit: 512
            )
#if DEBUG
            // Verification-only pacing of real fixture I/O. No fabricated
            // data/progress and never compiled into a user Release build.
            if let raw = ProcessInfo.processInfo.environment["SPACEJUDGE_TEST_PAGE_DELAY_MS"],
               let delay = Int(raw), (1...500).contains(delay) {
                scanConfiguration.enumerator = PacedPreviewEnumerator(delay: Double(delay) / 1000)
            }
#endif
            let engine = FileSystemScanEngine(
                configuration: scanConfiguration
            )
            let model = AppModel(
                engine: engine,
                repository: writer,
                reader: reader,
                directoryAccess: OpenPanelDirectoryAccess(),
                planner: FoundationVolumeScanPlanner(),
                workspaceExclusions: [repositories.workspace.exclusion()],
                shutdown: {
                    // Reader first, then the writer, so the writer's bounded
                    // checkpoint is not blocked by the UI read connection.
                    await reader.close()
                    await writer.close()
                }
            )
            self.model = model
            self.observeCommandPolicy(model)
            self.bootstrapError = nil
#if DEBUG
            // Pi-only smoke seam paired with `SPACEJUDGE_TEST_ROOT_PATH`.
            if ProcessInfo.processInfo.environment["SPACEJUDGE_TEST_ROOT_PATH"]?.hasPrefix("/") == true {
                await self.model?.chooseRoot()
            }
#endif
        } catch {
            if !isTerminating {
                self.bootstrapError = "无法准备本地快照数据库。请重新启动应用；如仍然失败，请联系支持。"
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        guard let model else { return .terminateNow }
        if shutdownRequested { return .terminateLater }
        shutdownRequested = true
        Task { @MainActor in
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Menu commands

    /// Installs the Scan menu after SwiftUI has built the main menu.
    ///
    /// The menu items are real AppKit items with this delegate as their target,
    /// so `validateMenuItem` can drive their enabled state from the shared
    /// `AppCommandPolicy`. A SwiftUI `.commands` builder would be evaluated
    /// against the `@Observable` model through an `ObservableObject` delegate,
    /// which is exactly the two-level lifecycle that left the items permanently
    /// disabled; AppKit validation is the reliable bridge.
    private func installScanMenu() {
        scheduleScanMenuInstall(after: 0)
    }

    private func scheduleScanMenuInstall(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.buildScanMenu()
        }
    }

    private func buildScanMenu() {
        guard scanMenuItems == nil, let mainMenu = NSApp.mainMenu, mainMenu.items.count >= 2 else {
            // SwiftUI may not have finished installing the menu bar yet.
            scheduleScanMenuInstall(after: 0.1)
            return
        }
        let menu = NSMenu(title: "扫描")
        // We own enablement through `refreshScanMenuEnabledState` and
        // `validateMenuItem`; AppKit's default auto-enabling would otherwise
        // re-enable a responding item and ignore the policy.
        menu.autoenablesItems = false
        let choose = NSMenuItem(
            title: "选择文件夹或磁盘…",
            action: #selector(chooseLocationFromMenu(_:)),
            keyEquivalent: "o"
        )
        choose.keyEquivalentModifierMask = [.command]
        choose.target = self
        let rescan = NSMenuItem(
            title: "刷新整个扫描范围",
            action: #selector(rescanFromMenu(_:)),
            keyEquivalent: "r"
        )
        rescan.keyEquivalentModifierMask = [.command]
        rescan.target = self
        menu.addItem(choose)
        menu.addItem(rescan)
        let container = NSMenuItem(title: "扫描", action: nil, keyEquivalent: "")
        container.submenu = menu
        mainMenu.insertItem(container, at: min(1, mainMenu.items.count))
        scanMenuItems = (choose, rescan)
        refreshScanMenuEnabledState()
    }

    @objc private func chooseLocationFromMenu(_ sender: Any?) {
#if DEBUG
        Self.logMenuSelfTest("choose action fired")
#endif
        guard let model else { return }
        Task { await model.chooseRoot() }
    }

    @objc private func rescanFromMenu(_ sender: Any?) {
#if DEBUG
        Self.logMenuSelfTest("rescan action fired")
#endif
        guard let model else { return }
        Task { await model.rescan() }
    }

#if DEBUG
    /// Emits a line only when the menu self-test seam is enabled, so normal
    /// Debug runs stay quiet.
    private static func logMenuSelfTest(_ message: String) {
        guard ProcessInfo.processInfo.environment["SPACEJUDGE_TEST_MENU_SELFTEST"] == "1" else {
            return
        }
        FileHandle.standardError.write(Data("MENUSELFTEST \(message)\n".utf8))
    }
#endif

    /// Menu validation is the single source of truth for the menu items, using
    /// the same `AppCommandPolicy` as the toolbar.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === scanMenuItems?.choose {
            return model != nil && commandPolicy.canChooseRoot
        }
        if menuItem === scanMenuItems?.rescan {
            return model != nil && commandPolicy.canRescan
        }
        return true
    }

    private func refreshScanMenuEnabledState() {
        let chooseEnabled = model != nil && commandPolicy.canChooseRoot
        let rescanEnabled = model != nil && commandPolicy.canRescan
        scanMenuItems?.choose.isEnabled = chooseEnabled
        scanMenuItems?.rescan.isEnabled = rescanEnabled
    }

    // MARK: Menu command policy

    /// Mirrors the model's shared command policy into this delegate's
    /// `@Published` surface. The model re-arms the observation after every
    /// change, so the menu updates when bootstrap finishes, a root is chosen, a
    /// scan starts/finishes, or a picker opens — without ever force-enabling.
    private func observeCommandPolicy(_ model: AppModel) {
        commandPolicy = model.commandPolicy
        refreshScanMenuEnabledState()
        model.observeCommandPolicy { [weak self] policy in
            self?.commandPolicy = policy
            self?.refreshScanMenuEnabledState()
        }
    }

    // MARK: Bootstrap

    private struct Repositories: Sendable {
        let writer: SQLiteSnapshotRepository
        let reader: SQLiteSnapshotRepository
        let workspace: SnapshotWorkspace
    }

    private static func bootstrapRepositories() async throws -> Repositories {
        let workspace = try workspace()
        let path = workspace.databaseURL.path
        return try await Task.detached(priority: .userInitiated) {
            // Startup cleanup touches only SpaceJudge-managed members.
            try workspace.prepare()
            // Pre-create the WAL/SHM as 0600 so SQLite adopts owner-only files
            // instead of creating them with the process default mode.
            try workspace.prepareDatabaseFiles()
            let writer = try SQLiteSnapshotRepository(path: path, maximumRetainedScans: 2)
            do {
                let reader = try SQLiteSnapshotRepository.openReadOnly(path: path)
                // Safety net for any file (re)created during open.
                try workspace.tightenDatabaseFilePermissions()
                return Repositories(writer: writer, reader: reader, workspace: workspace)
            } catch {
                await writer.close()
                throw error
            }
        }.value
    }

    /// Normal user workspace under Foundation's `Caches/SpaceJudge`, with a
    /// DEBUG-only override used by the task's manual end-to-end smoke test.
    ///
    /// `SPACEJUDGE_TEST_DATABASE_PATH` is ignored in Release. In Debug it must
    /// be an absolute path ending in `.sqlite`; anything else refuses to launch
    /// rather than silently touching the real user workspace. The override only
    /// controls that named database; cleanup still never removes its parent
    /// directory.
    private static func workspace() throws -> SnapshotWorkspace {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SPACEJUDGE_TEST_DATABASE_PATH"] {
            guard raw.hasPrefix("/"), raw.hasSuffix(".sqlite") else {
                throw BootstrapError.invalidTestDatabasePath
            }
            return SnapshotWorkspace.debugOverride(databasePath: raw)
        }
        #endif
        return try SnapshotWorkspace.production()
    }

    private enum BootstrapError: Error {
        case invalidTestDatabasePath
    }
}

#if DEBUG
private struct PacedPreviewEnumerator: DirectoryEnumerator {
    let delay: TimeInterval
    func makeCursor(in directory: DirectoryHandle, request: EnumerationRequest) throws -> any DirectoryCursor {
        PacedPreviewCursor(base: try DarwinBulkEnumerator().makeCursor(in: directory, request: request), delay: delay)
    }
}

private final class PacedPreviewCursor: DirectoryCursor {
    var base: any DirectoryCursor
    let delay: TimeInterval
    init(base: any DirectoryCursor, delay: TimeInterval) { self.base = base; self.delay = delay }
    func nextPage() throws -> DirectoryEntryPage {
        Thread.sleep(forTimeInterval: delay)
        return try base.nextPage()
    }
}
#endif
