import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeUseCases

private enum IndependentCheckpointError: Error { case write }

private actor IndependentCheckpointEngine: ScanEngine, CancelledCheckpointProviding {
    nonisolated let metadata: ScanMetadata
    nonisolated let terminalImmediately: Bool
    private var consumed = false

    init(metadata: ScanMetadata, terminalImmediately: Bool = false) {
        self.metadata = metadata
        self.terminalImmediately = terminalImmediately
    }

    nonisolated func events(for request: ScanRequest) -> AsyncThrowingStream<ScanEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started(metadata))
            if terminalImmediately {
                continuation.yield(.cancelled(ScanSummary(
                    scanID: metadata.scanID, status: .cancelled,
                    startedAt: metadata.startedAt, finishedAt: Date(), fileCount: 0,
                    directoryCount: 1, inaccessibleCount: 0, issueCount: 0,
                    rootAttributedBytes: 0
                )))
                continuation.finish()
            }
        }
    }

    func cancel(scanID: ScanID) async {}

    func takeCancelledCheckpoint(scanID: ScanID) async -> CancelledDirectoryCheckpoint? {
        guard scanID == metadata.scanID, !consumed else { return nil }
        consumed = true
        return CancelledDirectoryCheckpoint(
            names: [NameRecord(id: NameID(2), utf8: Data("unfinished".utf8))],
            directories: [NodeRecord(
                id: NodeID(2), scanID: scanID, parentID: metadata.rootNodeID,
                name: NameID(2), kind: .directory, logicalBytes: nil,
                allocatedBytes: nil, attributedBytes: 0
            )]
        )
    }
}

private actor IndependentCheckpointRepository: SnapshotRepository {
    private let gatedWrite: Bool
    private var writeGate: CheckedContinuation<Void, Never>?
    private(set) var began = false
    private(set) var failed = false
    private(set) var finished = false
    private(set) var writeAttempted = false

    init(gatedWrite: Bool = false) { self.gatedWrite = gatedWrite }

    func begin(_ metadata: ScanMetadata) async throws { began = true }
    func write(_ batch: NodeBatch) async throws {
        writeAttempted = true
        if gatedWrite { await withCheckedContinuation { writeGate = $0 } }
        throw IndependentCheckpointError.write
    }
    func releaseWrite() { writeGate?.resume(); writeGate = nil }
    func record(_ issue: ScanIssue) async throws {}
    func finish(_ summary: ScanSummary) async throws { finished = true }
    func fail(scanID: ScanID) async throws { failed = true }
    func children(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] { [] }
    func childPage(of nodeID: NodeID, in scanID: ScanID, limit: Int) async throws -> SnapshotChildPage {
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

@Suite("Cancelled checkpoint independent acceptance")
struct CancelledCheckpointIndependentAcceptanceTests {
    @Test("Forced consumer cancellation fails the snapshot if its checkpoint cannot be stored")
    func forcedCancelCheckpointFailureMarksFailed() async throws {
        let request = ScanRequest(root: ScanRoot(fileSystemPath: "/synthetic", displayName: "synthetic"))
        let metadata = ScanMetadata(
            scanID: ScanID(), request: request, startedAt: Date(), rootNodeID: NodeID(1)
        )
        let repository = IndependentCheckpointRepository()
        let runner = PersistingScanRunner(
            engine: IndependentCheckpointEngine(metadata: metadata), repository: repository
        )
        let task = Task { try await runner.run(request) }
        for _ in 0..<200 where !(await repository.began) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await repository.began)
        task.cancel()
        var didThrow = false
        do { _ = try await task.value } catch { didThrow = true }
        #expect(didThrow)
        #expect(await repository.writeAttempted)
        #expect(await repository.failed)
        #expect(!(await repository.finished))
    }

    @Test("A checkpoint storage error remains a failure when the consumer is cancelled concurrently")
    func concurrentCancelDoesNotMaskCheckpointFailure() async throws {
        let request = ScanRequest(root: ScanRoot(fileSystemPath: "/synthetic", displayName: "synthetic"))
        let metadata = ScanMetadata(
            scanID: ScanID(), request: request, startedAt: Date(), rootNodeID: NodeID(1)
        )
        let repository = IndependentCheckpointRepository(gatedWrite: true)
        let runner = PersistingScanRunner(
            engine: IndependentCheckpointEngine(metadata: metadata, terminalImmediately: true),
            repository: repository
        )
        let task = Task { try await runner.run(request) }
        for _ in 0..<200 where !(await repository.writeAttempted) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await repository.writeAttempted)
        task.cancel()
        await repository.releaseWrite()
        var didThrow = false
        do { _ = try await task.value } catch { didThrow = true }
        #expect(didThrow)
        #expect(await repository.failed)
        #expect(!(await repository.finished))
    }
}
