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
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var model: AppModel?
    @Published private(set) var bootstrapError: String?

    private var shutdownRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                let repositories = try await Self.bootstrapRepositories()
                let writer = repositories.writer
                let reader = repositories.reader
                let engine = FileSystemScanEngine(
                    configuration: ScanConfiguration(
                        spoolDirectory: repositories.workspace.spoolDirectoryURL
                    )
                )
                self.model = AppModel(
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
#if DEBUG
                // Pi-only smoke seam paired with `SPACEJUDGE_TEST_ROOT_PATH`.
                if ProcessInfo.processInfo.environment["SPACEJUDGE_TEST_ROOT_PATH"]?.hasPrefix("/") == true {
                    await self.model?.chooseRoot()
                }
#endif
            } catch {
                self.bootstrapError = "无法准备本地快照数据库。请重新启动应用；如仍然失败，请联系支持。"
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if shutdownRequested { return .terminateLater }
        shutdownRequested = true
        Task { @MainActor in
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
            let writer = try SQLiteSnapshotRepository(path: path)
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
