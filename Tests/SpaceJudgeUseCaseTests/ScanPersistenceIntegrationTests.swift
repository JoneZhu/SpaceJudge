import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeUseCases

/// Transparent repository decorator that records every successfully persisted
/// batch revision. Used to prove the persisted run is exactly `1...N`.
private actor RevisionRecordingRepository: SnapshotRepository {
    private let inner: any SnapshotRepository
    private var writtenRevisions: [UInt64] = []

    init(wrapping inner: any SnapshotRepository) {
        self.inner = inner
    }

    var revisions: [UInt64] { writtenRevisions }

    func begin(_ metadata: ScanMetadata) async throws { try await inner.begin(metadata) }

    func write(_ batch: NodeBatch) async throws {
        try await inner.write(batch)
        writtenRevisions.append(batch.revision.rawValue)
    }

    func record(_ issue: ScanIssue) async throws { try await inner.record(issue) }
    func finish(_ summary: ScanSummary) async throws { try await inner.finish(summary) }
    func fail(scanID: ScanID) async throws { try await inner.fail(scanID: scanID) }

    func children(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] {
        try await inner.children(of: nodeID, in: scanID)
    }

    func childPage(
        of nodeID: NodeID,
        in scanID: ScanID,
        limit: Int
    ) async throws -> SnapshotChildPage {
        try await inner.childPage(of: nodeID, in: scanID, limit: limit)
    }

    func name(id: NameID, in scanID: ScanID) async throws -> NameRecord? {
        try await inner.name(id: id, in: scanID)
    }

    func aggregate(
        of nodeID: NodeID,
        in scanID: ScanID
    ) async throws -> DirectoryAggregateRecord? {
        try await inner.aggregate(of: nodeID, in: scanID)
    }

    func ancestors(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] {
        try await inner.ancestors(of: nodeID, in: scanID)
    }

    func scanState(_ scanID: ScanID) async throws -> ScanSnapshotState? {
        try await inner.scanState(scanID)
    }

    func scanSummary(_ scanID: ScanID) async throws -> ScanSnapshotSummary? {
        try await inner.scanSummary(scanID)
    }

    func issueSummary(_ scanID: ScanID) async throws -> [IssueAggregateSummary] {
        try await inner.issueSummary(scanID)
    }

    func statistics(_ scanID: ScanID) async throws -> SnapshotStatistics {
        try await inner.statistics(scanID)
    }
}

@Suite("Scan to SQLite integration")
struct ScanPersistenceIntegrationTests {
    private static let directoryCount = 8
    private static let filesPerDirectory = 250
    private static let fileCount = directoryCount * filesPerDirectory

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacejudge-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in 0..<Self.directoryCount {
            let directoryURL = root.appendingPathComponent("d\(directory)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            for file in 0..<Self.filesPerDirectory {
                try Data("x".utf8).write(
                    to: directoryURL.appendingPathComponent("f\(file)")
                )
            }
        }
        return root
    }

    /// Real engine + runner + SQLite under a one-slot stream buffer and four
    /// workers. The SQLite persistence consumer is slow enough relative to the
    /// producers that, with a single buffer slot, workers repeatedly hit the
    /// full buffer and retry a dropped `yield`, exercising the same reentrancy
    /// window that produced `revisionNotContiguous` on real scans.
    @Test(
        "Concurrent backpressure persists a contiguous, reopenable snapshot",
        .timeLimit(.minutes(3))
    )
    func concurrentBackpressurePersistsContiguousSnapshot() async throws {
        let root = try makeFixture()
        let databaseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacejudge-persistdb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )
        let databasePath = databaseDirectory.appendingPathComponent("store.sqlite").path
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: databaseDirectory)
        }

        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 4,
                batchNodeLimit: 30,
                batchTimeMilliseconds: 100_000,
                eventBufferSize: 1
            )
        )
        let store = try SQLiteSnapshotRepository(path: databasePath)
        let repository = RevisionRecordingRepository(wrapping: store)
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        let request = ScanRequest(
            root: ScanRoot(fileSystemPath: root.path, displayName: "fixture")
        )

        let summary = try await runner.run(request)
        #expect(summary.status == .completed)
        #expect(summary.fileCount == UInt64(Self.fileCount))
        #expect(summary.directoryCount == UInt64(Self.directoryCount + 1))

        let revisions = await repository.revisions
        #expect(!revisions.isEmpty)
        #expect(revisions == Array(1...UInt64(revisions.count)))

        await store.close()

        // Reopen the same database read-only and query the persisted root like
        // a fresh CLI/MCP process would.
        let reopened = try SQLiteSnapshotRepository.openReadOnly(path: databasePath)

        let state = try #require(try await reopened.scanState(summary.scanID))
        #expect(state.status == .completed)
        #expect(state.lastRevision.rawValue == UInt64(revisions.count))
        #expect(state.fileCount == UInt64(Self.fileCount))
        #expect(state.directoryCount == UInt64(Self.directoryCount + 1))
        #expect(state.issueCount == 0)

        let rootNodeID = state.rootNodeID
        let aggregate = try #require(
            try await reopened.aggregate(of: rootNodeID, in: summary.scanID)
        )
        #expect(aggregate.isComplete)
        #expect(aggregate.descendantFileCount == UInt64(Self.fileCount))
        #expect(aggregate.descendantDirectoryCount == UInt64(Self.directoryCount))

        let children = try await reopened.children(of: rootNodeID, in: summary.scanID)
        #expect(children.count == Self.directoryCount)

        let statistics = try await reopened.statistics(summary.scanID)
        #expect(statistics.nodeCount == UInt64(Self.fileCount + Self.directoryCount + 1))

        await reopened.close()
    }
}
