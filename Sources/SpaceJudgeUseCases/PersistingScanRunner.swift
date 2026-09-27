import Foundation
import SpaceJudgeDomain

/// Failures raised by `PersistingScanRunner` itself, distinct from engine and
/// store errors. Store/engine errors are rethrown unchanged.
public enum PersistingScanRunnerError: Error, Equatable, Sendable {
    /// The engine's stream finished without a terminal event.
    case streamEndedWithoutTerminal
    /// A second `.started` event arrived for the same run.
    case duplicateStarted
    /// A second terminal event arrived for the same run.
    case duplicateTerminal
    /// An event carried a `ScanID` different from the started run.
    case scanIDMismatch(expected: ScanID, found: ScanID)
    /// A `.completed`/`.cancelled` event carried a summary with the wrong status.
    case terminalStatusMismatch(expected: ScanStatus, found: ScanStatus)
    /// A batch/issue/terminal arrived before `.started`.
    case eventBeforeStarted
    /// Accumulated issue count would overflow `UInt64`.
    case issueCountOverflow
}

/// Lightweight progress notification for an observer such as the app shell.
///
/// Updates never carry a `NodeBatch`, a SQLite statement or a connection, so an
/// observer cannot accidentally copy large facts or hold storage resources. It
/// must return quickly; batching and throttling belong to the observer.
public enum PersistingScanUpdate: Sendable, Equatable {
    /// Emitted only after `repository.begin` succeeded.
    case started(ScanMetadata)
    /// Emitted only after the batch transaction committed.
    case committed(scanID: ScanID, revision: Revision)
    /// Forwarded progress counters. Never persisted; safe to coalesce.
    case progress(scanID: ScanID, value: ScanProgress)
    /// Emitted only after `repository.record` succeeded. `totalCount` is the
    /// accumulated persisted issue count for the scan.
    case issueRecorded(scanID: ScanID, totalCount: UInt64)
    /// Emitted only after `repository.finish` succeeded.
    case terminal(ScanSummary)
}

/// Consumes a `ScanEngine` stream and persists it through a
/// `SnapshotRepository`.
///
/// The runner consumes events strictly in order and `await`s every repository
/// call, so a slow SQLite writer applies real backpressure to the scan stream.
/// Once `.started` has been seen, any exit that does not return a valid
/// terminal event — including a normal end-of-stream with no terminal, a store
/// error, or a stream error — cancels the engine and tries to mark the
/// still-running snapshot failed. The original error is rethrown.
///
/// The one deliberate exception is forced user/shutdown cancellation: when the
/// enclosing task is cancelled and the engine has not yet published a terminal,
/// the runner synthesizes a `cancelled` summary from the last known facts and
/// persists it. That summary is published and returned only after
/// `repository.finish` succeeds; if persisting it fails, the runner does not
/// emit a cancelled terminal, best-effort fails the scan and rethrows the
/// persistence error so the app reports failure rather than a false cancel.
///
/// When an `onUpdate` observer is supplied it only observes facts that were
/// successfully persisted: no "fake" committed revision or terminal summary is
/// ever published after a failed store call.
public actor PersistingScanRunner {
    private let engine: any ScanEngine
    private let repository: any SnapshotRepository

    public init(engine: any ScanEngine, repository: any SnapshotRepository) {
        self.engine = engine
        self.repository = repository
    }

    /// Runs one scan to its terminal event and returns the terminal summary.
    @discardableResult
    public func run(_ request: ScanRequest) async throws -> ScanSummary {
        try await run(request, onUpdate: { _ in })
    }

    /// Runs one scan while publishing lightweight updates after each successful
    /// persistence step.
    @discardableResult
    public func run(
        _ request: ScanRequest,
        onUpdate: @escaping @Sendable (PersistingScanUpdate) -> Void
    ) async throws -> ScanSummary {
        var startedScanID: ScanID?
        var startedMetadata: ScanMetadata?
        var lastProgress: ScanProgress?
        var terminal: ScanSummary?
        var persistedIssueCount: UInt64 = 0

        do {
            for try await event in engine.events(for: request) {
                switch event {
                case .started(let metadata):
                    guard startedScanID == nil else {
                        throw PersistingScanRunnerError.duplicateStarted
                    }
                    startedScanID = metadata.scanID
                    startedMetadata = metadata
                    try await repository.begin(metadata)
                    onUpdate(.started(metadata))

                case .batch(let batch):
                    guard let scanID = startedScanID else {
                        throw PersistingScanRunnerError.eventBeforeStarted
                    }
                    guard batch.scanID == scanID else {
                        throw PersistingScanRunnerError.scanIDMismatch(
                            expected: scanID,
                            found: batch.scanID
                        )
                    }
                    try await repository.write(batch)
                    onUpdate(.committed(scanID: scanID, revision: batch.revision))

                case .issue(let issue):
                    guard let scanID = startedScanID else {
                        throw PersistingScanRunnerError.eventBeforeStarted
                    }
                    guard issue.scanID == scanID else {
                        throw PersistingScanRunnerError.scanIDMismatch(
                            expected: scanID,
                            found: issue.scanID
                        )
                    }
                    let (prospective, overflow) = persistedIssueCount
                        .addingReportingOverflow(issue.count)
                    guard !overflow else {
                        throw PersistingScanRunnerError.issueCountOverflow
                    }
                    try await repository.record(issue)
                    persistedIssueCount = prospective
                    onUpdate(.issueRecorded(scanID: scanID, totalCount: persistedIssueCount))

                case .progress(let progress):
                    // Progress is UI-only and never persisted. It is forwarded
                    // only once the scan header exists. It is also the last
                    // known fact used to synthesize a cancelled summary when a
                    // forced consumer cancellation prevents a terminal event.
                    lastProgress = progress
                    if let scanID = startedScanID {
                        onUpdate(.progress(scanID: scanID, value: progress))
                    }

                case .completed(let summary):
                    try await finish(
                        summary,
                        expected: .completed,
                        startedScanID: startedScanID,
                        terminal: terminal
                    )
                    terminal = summary
                    onUpdate(.terminal(summary))

                case .cancelled(let summary):
                    try await finish(
                        summary,
                        expected: .cancelled,
                        startedScanID: startedScanID,
                        terminal: terminal
                    )
                    terminal = summary
                    onUpdate(.terminal(summary))
                }
            }
            guard let terminal else {
                throw PersistingScanRunnerError.streamEndedWithoutTerminal
            }
            return terminal
        } catch {
            // A forced consumer cancellation after an explicit user/shutdown
            // `engine.cancel` is not a scan failure. The engine accepted the
            // cancel but a blocked syscall may not let it publish a terminal
            // event before the caller cancels this task, so synthesize a
            // consistent `cancelled` terminal from the last persisted and
            // progress facts. Only a cancelled *Task* with a started scan and no
            // terminal qualifies: ordinary store/stream errors still fail.
            if let scanID = startedScanID, Task.isCancelled, terminal == nil {
                await engine.cancel(scanID: scanID)
                let summary = Self.cancelledSummary(
                    scanID: scanID,
                    metadata: startedMetadata,
                    lastProgress: lastProgress,
                    issueCount: persistedIssueCount,
                    finishedAt: Date()
                )
                do {
                    try await repository.finish(summary)
                } catch {
                    // Persisting the synthesized terminal failed. Never publish
                    // a cancelled terminal the database cannot back; best-effort
                    // fail the scan and surface the persistence error instead of
                    // claiming a cancellation that was not recorded.
                    try? await repository.fail(scanID: scanID)
                    throw error
                }
                onUpdate(.terminal(summary))
                return summary
            }
            // Any other failure after `.started` (including a normal EOF without
            // a terminal) must stop the engine and fail the snapshot.
            if let scanID = startedScanID {
                await engine.cancel(scanID: scanID)
                try? await repository.fail(scanID: scanID)
            }
            throw error
        }
    }

    /// Best-known terminal facts for a user cancellation whose engine terminal
    /// never arrived. Counters come from the last progress event and the
    /// persisted issue total; unknown values stay at their neutral default and
    /// are never presented as a completed scan.
    private static func cancelledSummary(
        scanID: ScanID,
        metadata: ScanMetadata?,
        lastProgress: ScanProgress?,
        issueCount: UInt64,
        finishedAt: Date
    ) -> ScanSummary {
        ScanSummary(
            scanID: scanID,
            status: .cancelled,
            startedAt: metadata?.startedAt ?? finishedAt,
            finishedAt: finishedAt,
            fileCount: lastProgress?.fileCount ?? 0,
            directoryCount: lastProgress?.directoryCount ?? 0,
            inaccessibleCount: 0,
            issueCount: issueCount,
            rootAttributedBytes: lastProgress?.attributedBytes ?? 0,
            volume: metadata?.volume
        )
    }

    private func finish(
        _ summary: ScanSummary,
        expected: ScanStatus,
        startedScanID: ScanID?,
        terminal: ScanSummary?
    ) async throws {
        guard let scanID = startedScanID else {
            throw PersistingScanRunnerError.eventBeforeStarted
        }
        guard summary.scanID == scanID else {
            throw PersistingScanRunnerError.scanIDMismatch(
                expected: scanID,
                found: summary.scanID
            )
        }
        guard terminal == nil else {
            throw PersistingScanRunnerError.duplicateTerminal
        }
        guard summary.status == expected else {
            throw PersistingScanRunnerError.terminalStatusMismatch(
                expected: expected,
                found: summary.status
            )
        }
        try await repository.finish(summary)
    }
}
