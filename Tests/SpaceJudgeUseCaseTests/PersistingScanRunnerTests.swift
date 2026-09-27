import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeUseCases

private enum TestError: Error, Equatable {
    case storeWrite
    case streamFatal
}

/// Engine that replays a fixed event list, optionally finishing with an error.
private actor ScriptedEngine: ScanEngine {
    private nonisolated let events: [ScanEvent]
    private nonisolated let terminalError: Error?
    private var cancelled: [ScanID] = []

    init(events: [ScanEvent], terminalError: Error? = nil) {
        self.events = events
        self.terminalError = terminalError
    }

    nonisolated func events(for request: ScanRequest) -> AsyncThrowingStream<ScanEvent, any Error> {
        let events = self.events
        let error = self.terminalError
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    func cancel(scanID: ScanID) async {
        cancelled.append(scanID)
    }

    var cancelledScanIDs: [ScanID] {
        cancelled
    }
}

/// Engine that yields `.started` and then holds the stream open forever. It
/// accepts `cancel` but never publishes a terminal, modeling a scan blocked in
/// a directory syscall past the caller's cancellation grace period.
private actor HoldingEngine: ScanEngine {
    private nonisolated let scanMetadata: ScanMetadata
    private var cancelled: [ScanID] = []

    init(metadata: ScanMetadata) {
        self.scanMetadata = metadata
    }

    nonisolated func events(for request: ScanRequest) -> AsyncThrowingStream<ScanEvent, any Error> {
        let metadata = scanMetadata
        return AsyncThrowingStream { continuation in
            continuation.yield(.started(metadata))
        }
    }

    func cancel(scanID: ScanID) async {
        cancelled.append(scanID)
    }

    var cancelledScanIDs: [ScanID] {
        cancelled
    }
}

/// Repository that records calls and can fail writes on demand.
private actor RecordingRepository: SnapshotRepository {
    enum Call: Equatable {
        case begin(ScanID)
        case write(Revision)
        case record(ScanIssueCategory)
        case finish(ScanStatus)
        case fail(ScanID)
    }

    private(set) var calls: [Call] = []
    private var failWrites = false
    private var failFinish = false

    init(failWrites: Bool = false, failFinish: Bool = false) {
        self.failWrites = failWrites
        self.failFinish = failFinish
    }

    func begin(_ metadata: ScanMetadata) async throws {
        calls.append(.begin(metadata.scanID))
    }

    func write(_ batch: NodeBatch) async throws {
        if failWrites {
            throw TestError.storeWrite
        }
        calls.append(.write(batch.revision))
    }

    func record(_ issue: ScanIssue) async throws {
        calls.append(.record(issue.category))
    }

    func finish(_ summary: ScanSummary) async throws {
        if failFinish {
            throw TestError.storeWrite
        }
        calls.append(.finish(summary.status))
    }

    func fail(scanID: ScanID) async throws {
        calls.append(.fail(scanID))
    }

    func children(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] { [] }
    func childPage(
        of nodeID: NodeID,
        in scanID: ScanID,
        limit: Int
    ) async throws -> SnapshotChildPage {
        SnapshotChildPage(items: [], totalCount: 0)
    }
    func name(id: NameID, in scanID: ScanID) async throws -> NameRecord? { nil }
    func aggregate(of nodeID: NodeID, in scanID: ScanID) async throws -> DirectoryAggregateRecord? { nil }
    func ancestors(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] { [] }
    func scanState(_ scanID: ScanID) async throws -> ScanSnapshotState? { nil }
    func scanSummary(_ scanID: ScanID) async throws -> ScanSnapshotSummary? { nil }
    func issueSummary(_ scanID: ScanID) async throws -> [IssueAggregateSummary] { [] }
    func statistics(_ scanID: ScanID) async throws -> SnapshotStatistics {
        SnapshotStatistics(nodeCount: 0, nameCount: 0, aggregateCount: 0, issueCount: 0)
    }
}

@Suite("Persisting scan runner")
struct PersistingScanRunnerTests {
    private let scanID = ScanID()
    private var request: ScanRequest {
        ScanRequest(root: ScanRoot(fileSystemPath: "/synthetic", displayName: "synthetic"))
    }

    private func metadata() -> ScanMetadata {
        ScanMetadata(
            scanID: scanID,
            request: request,
            startedAt: Date(timeIntervalSince1970: 0),
            rootNodeID: NodeID(1)
        )
    }

    private func summary(_ status: ScanStatus) -> ScanSummary {
        ScanSummary(
            scanID: scanID,
            status: status,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            fileCount: 1,
            directoryCount: 1,
            inaccessibleCount: 0,
            issueCount: 0,
            rootAttributedBytes: 1
        )
    }

    private func batch(revision: UInt64) -> NodeBatch {
        NodeBatch(scanID: scanID, revision: Revision(revision), names: [], nodes: [])
    }

    @Test("Persists started, batch, issue and terminal in order")
    func happyPath() async throws {
        let engine = ScriptedEngine(events: [
            .started(metadata()),
            .batch(batch(revision: 1)),
            .progress(
                ScanProgress(
                    revision: Revision(1), status: .running, fileCount: 0, directoryCount: 0,
                    attributedBytes: 0, pendingDirectories: 0, entriesPerSecond: 0, elapsedSeconds: 0
                )
            ),
            .issue(ScanIssue(scanID: scanID, category: .io, errnoValue: EIO, count: 1)),
            .completed(summary(.completed))
        ])
        let repository = RecordingRepository()
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        let result = try await runner.run(request)
        #expect(result.status == .completed)

        let calls = await repository.calls
        #expect(calls == [.begin(scanID), .write(Revision(1)), .record(.io), .finish(.completed)])
        #expect(await engine.cancelledScanIDs.isEmpty)
    }

    @Test("A store write failure cancels the scan, marks it failed, and rethrows")
    func storeFailureCancels() async throws {
        let engine = ScriptedEngine(events: [
            .started(metadata()),
            .batch(batch(revision: 1)),
            .completed(summary(.completed))
        ])
        let repository = RecordingRepository(failWrites: true)
        let runner = PersistingScanRunner(engine: engine, repository: repository)

        do {
            _ = try await runner.run(request)
            Issue.record("expected a store failure")
        } catch let error as TestError {
            #expect(error == .storeWrite)
        }
        #expect(await engine.cancelledScanIDs == [scanID])
        let calls = await repository.calls
        #expect(calls.contains(.fail(scanID)))
        #expect(!calls.contains(.finish(.completed)))
    }

    @Test("A fatal stream error after started marks the scan failed")
    func streamFatalMarksFailed() async throws {
        let engine = ScriptedEngine(
            events: [.started(metadata()), .batch(batch(revision: 1))],
            terminalError: TestError.streamFatal
        )
        let repository = RecordingRepository()
        let runner = PersistingScanRunner(engine: engine, repository: repository)

        do {
            _ = try await runner.run(request)
            Issue.record("expected a stream failure")
        } catch let error as TestError {
            #expect(error == .streamFatal)
        }
        let calls = await repository.calls
        #expect(calls.contains(.fail(scanID)))
    }

    @Test("A stream with no terminal event fails and cleans up")
    func missingTerminal() async throws {
        let engine = ScriptedEngine(events: [.started(metadata()), .batch(batch(revision: 1))])
        let repository = RecordingRepository()
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        await #expect(throws: PersistingScanRunnerError.streamEndedWithoutTerminal) {
            _ = try await runner.run(request)
        }
        // A normal EOF without a terminal must still cancel and fail the scan.
        #expect(await engine.cancelledScanIDs == [scanID])
        #expect(await repository.calls.contains(.fail(scanID)))
        #expect(await repository.calls.contains(.finish(.completed)) == false)
    }

    @Test("A forced consumer cancellation after an unresponsive engine records cancelled, not failed")
    func forcedConsumerCancellationRecordsCancelled() async throws {
        let engine = HoldingEngine(metadata: metadata())
        let repository = RecordingRepository()
        let recorder = UpdateRecorder()
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        let task = Task {
            try await runner.run(request) { recorder.append($0) }
        }
        // Wait until the header is persisted, then force-cancel the consumer
        // exactly as `AppModel.cancelAndWait` does when a syscall overruns the
        // graceful window.
        while !(await repository.calls.contains(.begin(scanID))) {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        task.cancel()
        let result = try await task.value

        #expect(result.status == .cancelled)
        #expect(result.scanID == scanID)
        #expect(await repository.calls.contains(.finish(.cancelled)))
        #expect(await repository.calls.contains(.fail(scanID)) == false)
        #expect(await engine.cancelledScanIDs == [scanID])
        #expect(recorder.updates.contains(.terminal(result)))
    }

    @Test("A forced cancellation whose cancelled terminal cannot persist throws and publishes nothing")
    func forcedCancellationPersistFailure() async throws {
        let engine = HoldingEngine(metadata: metadata())
        let repository = RecordingRepository(failFinish: true)
        let recorder = UpdateRecorder()
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        let task = Task {
            try await runner.run(request) { recorder.append($0) }
        }
        while !(await repository.calls.contains(.begin(scanID))) {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected the persistence error to be rethrown")
        } catch let error as TestError {
            #expect(error == .storeWrite)
        }

        // No cancelled terminal may be published when its persistence failed.
        let terminalPublished = recorder.updates.contains { update in
            if case .terminal = update { return true }
            return false
        }
        #expect(!terminalPublished)
        // The runner still attempts a best-effort failure marking.
        #expect(await repository.calls.contains(.fail(scanID)))
    }

    @Test("A completed event carrying a cancelled summary fails and cleans up")
    func completedWithCancelledSummary() async throws {
        let engine = ScriptedEngine(events: [.started(metadata()), .completed(summary(.cancelled))])
        let repository = RecordingRepository()
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        await #expect(
            throws: PersistingScanRunnerError.terminalStatusMismatch(expected: .completed, found: .cancelled)
        ) {
            _ = try await runner.run(request)
        }
        #expect(await engine.cancelledScanIDs == [scanID])
        #expect(await repository.calls.contains(.fail(scanID)))
    }

    @Test("A cancelled event carrying a completed summary fails and cleans up")
    func cancelledWithCompletedSummary() async throws {
        let engine = ScriptedEngine(events: [.started(metadata()), .cancelled(summary(.completed))])
        let repository = RecordingRepository()
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        await #expect(
            throws: PersistingScanRunnerError.terminalStatusMismatch(expected: .cancelled, found: .completed)
        ) {
            _ = try await runner.run(request)
        }
        #expect(await engine.cancelledScanIDs == [scanID])
        #expect(await repository.calls.contains(.fail(scanID)))
    }

    @Test("A duplicate started event fails")
    func duplicateStarted() async throws {
        let engine = ScriptedEngine(events: [.started(metadata()), .started(metadata())])
        let repository = RecordingRepository()
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        await #expect(throws: PersistingScanRunnerError.duplicateStarted) {
            _ = try await runner.run(request)
        }
    }

    @Test("A duplicate terminal event fails")
    func duplicateTerminal() async throws {
        let engine = ScriptedEngine(events: [
            .started(metadata()),
            .completed(summary(.completed)),
            .completed(summary(.completed))
        ])
        let repository = RecordingRepository()
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        await #expect(throws: PersistingScanRunnerError.duplicateTerminal) {
            _ = try await runner.run(request)
        }
    }

    @Test("A mismatched scan ID fails")
    func mismatchedScanID() async throws {
        let otherScanID = ScanID()
        let engine = ScriptedEngine(events: [
            .started(metadata()),
            .batch(NodeBatch(scanID: otherScanID, revision: Revision(1), names: [], nodes: []))
        ])
        let repository = RecordingRepository()
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        await #expect(
            throws: PersistingScanRunnerError.scanIDMismatch(expected: scanID, found: otherScanID)
        ) {
            _ = try await runner.run(request)
        }
    }

    @Test("Updates are published only after each successful persistence step")
    func updateOrdering() async throws {
        let engine = ScriptedEngine(events: [
            .started(metadata()),
            .batch(batch(revision: 1)),
            .progress(
                ScanProgress(
                    revision: Revision(1), status: .running, fileCount: 1, directoryCount: 1,
                    attributedBytes: 0, pendingDirectories: 0, entriesPerSecond: 0, elapsedSeconds: 0
                )
            ),
            .issue(ScanIssue(scanID: scanID, category: .permissionDenied, errnoValue: EACCES, count: 2)),
            .completed(summary(.completed))
        ])
        let repository = RecordingRepository()
        let runner = PersistingScanRunner(engine: engine, repository: repository)

        let recorder = UpdateRecorder()
        let result = try await runner.run(request) { update in
            recorder.append(update)
        }
        #expect(result.status == .completed)

        let updates = recorder.updates
        #expect(updates.count == 5)
        #expect(updates.first == .started(metadata()))
        #expect(updates[1] == .committed(scanID: scanID, revision: Revision(1)))
        if case .progress(let recordedScanID, _) = updates[2] {
            #expect(recordedScanID == scanID)
        } else {
            Issue.record("expected a progress update, got \(updates[2])")
        }
        #expect(updates[3] == .issueRecorded(scanID: scanID, totalCount: 2))
        #expect(updates[4] == .terminal(summary(.completed)))
    }

    @Test("A store write failure publishes no fake commit or terminal")
    func writeFailurePublishesNoCommit() async throws {
        let engine = ScriptedEngine(events: [
            .started(metadata()),
            .batch(batch(revision: 1)),
            .completed(summary(.completed))
        ])
        let repository = RecordingRepository(failWrites: true)
        let runner = PersistingScanRunner(engine: engine, repository: repository)

        let recorder = UpdateRecorder()
        do {
            _ = try await runner.run(request) { recorder.append($0) }
            Issue.record("expected a store failure")
        } catch let error as TestError {
            #expect(error == .storeWrite)
        }

        let updates = recorder.updates
        #expect(updates == [.started(metadata())])
        #expect(!updates.contains { if case .committed = $0 { return true } else { return false } })
        #expect(!updates.contains { if case .terminal = $0 { return true } else { return false } })
    }

    @Test("A finish failure publishes no fake terminal")
    func finishFailurePublishesNoTerminal() async throws {
        let engine = ScriptedEngine(events: [
            .started(metadata()),
            .completed(summary(.completed))
        ])
        let repository = RecordingRepository(failFinish: true)
        let runner = PersistingScanRunner(engine: engine, repository: repository)

        let recorder = UpdateRecorder()
        do {
            _ = try await runner.run(request) { recorder.append($0) }
            Issue.record("expected a store failure")
        } catch let error as TestError {
            #expect(error == .storeWrite)
        }
        #expect(recorder.updates == [.started(metadata())])
    }
}

/// Thread-safe collector for observer updates in the runner tests.
private final class UpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PersistingScanUpdate] = []

    func append(_ update: PersistingScanUpdate) {
        lock.lock()
        storage.append(update)
        lock.unlock()
    }

    var updates: [PersistingScanUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
