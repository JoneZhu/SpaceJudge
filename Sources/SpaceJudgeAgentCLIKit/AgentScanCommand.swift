import Darwin
import Foundation
import SpaceJudgeAppSupport
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeUseCases

/// Outcome of one `scan` invocation, kept separate from the process exit.
public struct AgentScanOutcome: Sendable {
    public let exitCode: Int32
    public let scanID: ScanID?
    public let terminalStatus: ScanStatus?
    public let processError: AgentCLIError?

    public init(
        exitCode: Int32,
        scanID: ScanID?,
        terminalStatus: ScanStatus?,
        processError: AgentCLIError?
    ) {
        self.exitCode = exitCode
        self.scanID = scanID
        self.terminalStatus = terminalStatus
        self.processError = processError
    }
}

/// Thread-safe lifecycle facts shared between the runner callback, the
/// periodic progress emitter and the signal watcher.
final class AgentScanState: @unchecked Sendable {
    private let lock = NSLock()
    private var scanIDValue: ScanID?
    private var progressValue: ScanProgress?
    private var terminalValue: ScanSummary?

    func markStarted(_ scanID: ScanID) {
        lock.lock(); defer { lock.unlock() }
        scanIDValue = scanID
    }

    func updateProgress(_ progress: ScanProgress) {
        lock.lock(); defer { lock.unlock() }
        progressValue = progress
    }

    func markTerminal(_ summary: ScanSummary) {
        lock.lock(); defer { lock.unlock() }
        terminalValue = summary
    }

    var scanID: ScanID? {
        lock.lock(); defer { lock.unlock() }
        return scanIDValue
    }

    var progress: ScanProgress? {
        lock.lock(); defer { lock.unlock() }
        return progressValue
    }

    var terminal: ScanSummary? {
        lock.lock(); defer { lock.unlock() }
        return terminalValue
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminalValue != nil
    }
}

/// `spacejudge-agent-cli scan --root ... --database ... --workspace ...`.
///
/// Emits a long-lived NDJSON stream. `started` is only emitted after the
/// `running` header is persisted; each terminal is persisted by the runner (or
/// by the explicit failure path) before it is emitted. A `SIGINT`/`SIGTERM`
/// forwarded through `cancelSignals` triggers the existing cooperative scan
/// cancellation, and a bounded grace period falls back to cancelling the
/// consumer task so a blocked syscall can never leave an unpersisted state.
public enum AgentScanCommand {
    /// Provision poll interval, matching the design's 250 ms bound.
    public static let progressInterval: Duration = .milliseconds(250)
    /// Grace after a cooperative cancel request before the consumer task is
    /// force-cancelled. The runner synthesizes and persists `cancelled`.
    public static let cancelGrace: Duration = .seconds(2)

    public static func run(
        rootPath: String,
        databasePath: String,
        workspacePath: String,
        emit: @escaping @Sendable (String) -> Void,
        cancelSignals: AsyncStream<Void>
    ) async -> AgentScanOutcome {
        do {
            let workspaceURL = try prepareWorkspace(
                workspacePath: workspacePath,
                databasePath: databasePath
            )
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            _ = try AgentCLIPath.requireDirectory(rootURL.path)

            let workspace = SnapshotWorkspace(
                rootURL: workspaceURL,
                databaseFileName: URL(fileURLWithPath: databasePath).lastPathComponent
            )

            let plan = FoundationVolumeScanPlanner().plan(for: DirectorySelection(url: rootURL))
            let request = plan.makeScanRequest(workspaceExclusions: [workspace.exclusion()])

            let repository = try SQLiteSnapshotRepository(
                path: databasePath,
                capacityProvider: VolumeStorageCapacityProvider(
                    directoryPath: workspaceURL.path
                )
            )
            let counting = CountingSnapshotRepository(wrapping: repository)
            let engine = FileSystemScanEngine(
                configuration: ScanConfiguration(
                    spoolDirectory: workspace.spoolDirectoryURL
                )
            )
            return await runSession(
                request: request,
                engine: engine,
                repository: counting,
                closeRepository: { await repository.close() },
                emit: emit,
                cancelSignals: cancelSignals
            )
        } catch {
            let classified = AgentCLIErrorClassifier.classify(error)
            emit(classified.jsonLine())
            return AgentScanOutcome(
                exitCode: classified.code.exitCode,
                scanID: nil,
                terminalStatus: nil,
                processError: classified
            )
        }
    }

    /// Runs one session against injected engine/repository values. The
    /// repository stays open until a terminal has been persisted and confirmed;
    /// every return path closes it exactly once.
    static func runSession(
        request: ScanRequest,
        engine: any ScanEngine,
        repository: any SnapshotRepository,
        closeRepository: @escaping @Sendable () async -> Void,
        emit: @escaping @Sendable (String) -> Void,
        cancelSignals: AsyncStream<Void>
    ) async -> AgentScanOutcome {
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        let state = AgentScanState()

        let onUpdate: @Sendable (PersistingScanUpdate) -> Void = { update in
            switch update {
            case .started(let metadata):
                state.markStarted(metadata.scanID)
                emit(AgentJSON.line([
                    "type": "started",
                    "scanId": metadata.scanID.description,
                    "rootNodeId": AgentJSON.uint64(metadata.rootNodeID.rawValue)
                ]))
            case .progress(_, let value):
                state.updateProgress(value)
            case .terminal(let summary):
                state.markTerminal(summary)
                emit(terminalLine(summary))
            case .committed, .issueRecorded:
                break
            }
        }

        let runnerTask = Task.detached(priority: .userInitiated) {
            try await runner.run(request, onUpdate: onUpdate)
        }

        let cancelTask = Task.detached {
            for await _ in cancelSignals {
                if let scanID = state.scanID {
                    await engine.cancel(scanID: scanID)
                    try? await Task.sleep(for: cancelGrace)
                }
                runnerTask.cancel()
            }
        }

        let progressTask = Task.detached {
            while !state.isFinished {
                try? await Task.sleep(for: progressInterval)
                if state.isFinished { break }
                guard let progress = state.progress else { continue }
                let persisted = await persistedNodeCount(of: repository)
                let visited = progress.fileCount.addingReportingOverflow(
                    progress.directoryCount
                )
                emit(AgentJSON.line([
                    "type": "progress",
                    "visitedEntries": AgentJSON.uint64(
                        visited.overflow ? UInt64.max : visited.partialValue
                    ),
                    "persistedNodes": AgentJSON.uint64(persisted),
                    "attributedBytes": AgentJSON.uint64(progress.attributedBytes),
                    "attributedGB": AgentJSON.gigabytes(progress.attributedBytes)
                ]))
            }
        }

        let result: Result<ScanSummary, any Error>
        do {
            result = .success(try await runnerTask.value)
        } catch {
            result = .failure(error)
        }
        cancelTask.cancel()
        progressTask.cancel()

        switch result {
        case .success(let summary):
            await closeRepository()
            // completed/cancelled are a successful protocol outcome; a failed
            // terminal already carries its own non-zero signal.
            let code: Int32 = summary.status == .failed ? 1 : 0
            return AgentScanOutcome(
                exitCode: code,
                scanID: summary.scanID,
                terminalStatus: summary.status,
                processError: nil
            )

        case .failure(let error):
            let classified = AgentCLIErrorClassifier.classify(error)
            guard let scanID = state.scanID else {
                // Never started: there is no persisted terminal to confirm, so
                // this is an ordinary process-level error.
                await closeRepository()
                emit(classified.jsonLine())
                return AgentScanOutcome(
                    exitCode: classified.code.exitCode,
                    scanID: nil,
                    terminalStatus: nil,
                    processError: classified
                )
            }
            // A scan that already started must end in exactly one persisted
            // `failed` terminal and never an additional process-level error.
            // The terminal is published only when the database confirms the
            // `.failed` state; an unconfirmable failure is an INTERNAL error
            // and never a fabricated terminal.
            try? await repository.fail(scanID: scanID)
            let snapshot = try? await repository.scanState(scanID)
            await closeRepository()
            guard let snapshot, snapshot.status == .failed else {
                let failure = AgentCLIError(code: .internalError)
                emit(failure.jsonLine())
                return AgentScanOutcome(
                    exitCode: failure.code.exitCode,
                    scanID: scanID,
                    terminalStatus: nil,
                    processError: failure
                )
            }
            let summary = ScanSummary(
                scanID: scanID,
                status: .failed,
                startedAt: snapshot.startedAt,
                finishedAt: snapshot.finishedAt,
                fileCount: snapshot.fileCount,
                directoryCount: snapshot.directoryCount,
                inaccessibleCount: snapshot.inaccessibleCount,
                issueCount: snapshot.issueCount,
                rootAttributedBytes: snapshot.rootAttributedBytes
            )
            emit(failedLine(summary, code: classified.code))
            return AgentScanOutcome(
                exitCode: 1,
                scanID: scanID,
                terminalStatus: .failed,
                processError: classified
            )
        }
    }

    /// `persistedNodes` is only known for the counting decorator; an injected
    /// repository without that surface reports unknown as `0`.
    private static func persistedNodeCount(of repository: any SnapshotRepository) async -> UInt64 {
        if let counting = repository as? CountingSnapshotRepository {
            return await counting.persistedNodeCount
        }
        return 0
    }

    // MARK: Terminal lines

    static func terminalLine(_ summary: ScanSummary) -> String {
        AgentJSON.line([
            "type": AgentJSON.statusName(summary.status),
            "scanId": summary.scanID.description,
            "status": AgentJSON.statusName(summary.status),
            "startedAt": AgentJSON.dateOrNull(summary.startedAt),
            "finishedAt": AgentJSON.dateOrNull(summary.finishedAt),
            "fileCount": AgentJSON.uint64(summary.fileCount),
            "directoryCount": AgentJSON.uint64(summary.directoryCount),
            "inaccessibleCount": AgentJSON.uint64(summary.inaccessibleCount),
            "issueCount": AgentJSON.uint64(summary.issueCount),
            "rootAttributedBytes": AgentJSON.uint64(summary.rootAttributedBytes),
            "rootAttributedGB": AgentJSON.gigabytes(summary.rootAttributedBytes)
        ])
    }

    private static func failedLine(_ summary: ScanSummary, code: AgentCLIErrorCode) -> String {
        AgentJSON.line([
            "type": "failed",
            "scanId": summary.scanID.description,
            "status": "failed",
            "code": code.rawValue,
            "message": code.message,
            "startedAt": AgentJSON.dateOrNull(summary.startedAt),
            "finishedAt": AgentJSON.dateOrNull(summary.finishedAt),
            "fileCount": AgentJSON.uint64(summary.fileCount),
            "directoryCount": AgentJSON.uint64(summary.directoryCount),
            "inaccessibleCount": AgentJSON.uint64(summary.inaccessibleCount),
            "issueCount": AgentJSON.uint64(summary.issueCount),
            "rootAttributedBytes": AgentJSON.uint64(summary.rootAttributedBytes),
            "rootAttributedGB": AgentJSON.gigabytes(summary.rootAttributedBytes)
        ])
    }

    // MARK: Workspace provisioning

    /// Validates an existing, already owner-only workspace and pre-creates the
    /// `0600` database trio for a brand-new database that is a **direct child**
    /// of that workspace.
    ///
    /// SpaceJudge never creates, chmods or otherwise mutates a caller-supplied
    /// directory. The MCP adapter owns its freshly `mkdtemp`-created task
    /// directory, but the CLI treats any existing directory as user state:
    /// it must already be owned by the effective user, be a real directory and
    /// carry no group/other permission bits. Nested caller directories are
    /// refused rather than created.
    static func prepareWorkspace(workspacePath: String, databasePath: String) throws -> URL {
        guard workspacePath.hasPrefix("/"), databasePath.hasPrefix("/") else {
            throw AgentCLIError(code: .invalidArgument)
        }
        let workspaceURL = try requireOwnedWorkspace(workspacePath)
        try AgentCLIPath.requireNewFile(databasePath)

        let databaseURL = URL(fileURLWithPath: databasePath)
        let parent = databaseURL.deletingLastPathComponent()
        guard AgentCLIPath.canonical(parent.path)
            == AgentCLIPath.canonical(workspaceURL.path) else {
            throw AgentCLIError(code: .invalidArgument)
        }

        for name in [
            databaseURL.lastPathComponent,
            databaseURL.lastPathComponent + "-wal",
            databaseURL.lastPathComponent + "-shm"
        ] {
            try createOwnerOnlyFile(workspaceURL.appendingPathComponent(name).path)
        }
        return workspaceURL
    }

    /// Fail-closed validation of a caller-supplied workspace directory. No
    /// permission bits are changed; an unsafe directory is rejected unchanged.
    private static func requireOwnedWorkspace(_ path: String) throws -> URL {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else {
            if errno == ENOENT { throw AgentCLIError(code: .notFound) }
            throw AgentCLIError(code: .accessDenied)
        }
        let type = status.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFLNK) {
            throw AgentCLIError(code: .invalidArgument)
        }
        guard type == mode_t(S_IFDIR) else {
            throw AgentCLIError(code: .invalidArgument)
        }
        guard status.st_uid == geteuid() else {
            throw AgentCLIError(code: .accessDenied)
        }
        guard (status.st_mode & 0o077) == 0 else {
            throw AgentCLIError(code: .invalidArgument)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func createOwnerOnlyFile(_ path: String) throws {
        var status = stat()
        if path.withCString({ lstat($0, &status) }) == 0 {
            throw AgentCLIError(code: .conflict)
        }
        guard errno == ENOENT else { throw AgentCLIError(code: .accessDenied) }
        let raw = path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_EXCL, 0o600) }
        guard raw >= 0 else { throw AgentCLIError(code: .accessDenied) }
        close(raw)
        try tightenOwnerOnlyFile(path)
    }

    private static func tightenOwnerOnlyFile(_ path: String) throws {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else {
            throw AgentCLIError(code: .accessDenied)
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw AgentCLIError(code: .invalidArgument)
        }
        guard (status.st_mode & 0o077) != 0 else { return }
        guard path.withCString({ chmod($0, 0o600) }) == 0 else {
            throw AgentCLIError(code: .accessDenied)
        }
    }
}
