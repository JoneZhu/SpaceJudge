import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeUseCases

// MARK: - Test doubles

private func directoryEntry(_ name: String, fileID: UInt64) -> RawDirectoryEntry {
    RawDirectoryEntry(nameBytes: Array(name.utf8), kind: .directory, deviceID: 1, fileID: fileID)
}

private func fileEntry(_ name: String, allocated: UInt64, fileID: UInt64) -> RawDirectoryEntry {
    RawDirectoryEntry(
        nameBytes: Array(name.utf8), kind: .regularFile,
        logicalBytes: allocated, allocatedBytes: allocated,
        deviceID: 1, fileID: fileID, linkCount: 1
    )
}

/// A cursor whose directory never reports `isLast`, so its own enumeration
/// stays unfinished until the scan is cancelled.
private final class WideCursor: DirectoryCursor {
    private let fileCount: Int
    private var emitted = false

    init(fileCount: Int) { self.fileCount = fileCount }

    func nextPage() throws -> DirectoryEntryPage {
        if !emitted {
            emitted = true
            let entries = (0..<fileCount).map { index in
                fileEntry("f\(index)", allocated: 10, fileID: UInt64(1_000 + index))
            }
            return DirectoryEntryPage(entries: entries, isLast: false)
        }
        usleep(5_000)
        return DirectoryEntryPage(entries: [], isLast: false)
    }
}

/// Minimal single-step cursor.
private final class SinglePageCursor: DirectoryCursor {
    private var entries: [RawDirectoryEntry]?

    init(_ entries: [RawDirectoryEntry]) { self.entries = entries }

    func nextPage() throws -> DirectoryEntryPage {
        guard let entries else { return DirectoryEntryPage(entries: [], isLast: true) }
        self.entries = nil
        return DirectoryEntryPage(entries: entries, isLast: true)
    }
}

/// Root has one real `wide` child. First call is root; later calls are the child.
private final class WideEnumerator: DirectoryEnumerator, @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let fileCount: Int
    private let childCompletes: Bool

    init(fileCount: Int, childCompletes: Bool) {
        self.fileCount = fileCount
        self.childCompletes = childCompletes
    }

    func makeCursor(
        in directory: DirectoryHandle,
        request: EnumerationRequest
    ) throws -> any DirectoryCursor {
        let current = lock.withLock { () -> Int in
            let value = index
            index += 1
            return value
        }
        if current == 0 {
            return SinglePageCursor([directoryEntry("wide", fileID: 2)])
        }
        if childCompletes {
            return SinglePageCursor([fileEntry("f0", allocated: 10, fileID: 1_000)])
        }
        return WideCursor(fileCount: fileCount)
    }
}

/// Fails the first all-directory batch (the cancelled checkpoint).
private actor CheckpointFailingRepository: SnapshotRepository {
    private let inner: any SnapshotRepository
    private(set) var didFailCheckpoint = false

    init(wrapping inner: any SnapshotRepository) { self.inner = inner }

    private func isCheckpointBatch(_ batch: NodeBatch) -> Bool {
        !batch.nodes.isEmpty && batch.directoryAggregates.isEmpty
            && batch.nodes.allSatisfy { $0.kind.isDirectoryLike }
    }

    func begin(_ metadata: ScanMetadata) async throws { try await inner.begin(metadata) }

    func write(_ batch: NodeBatch) async throws {
        if isCheckpointBatch(batch) {
            didFailCheckpoint = true
            throw SnapshotStoreError.invalidArgument("checkpoint write rejected")
        }
        try await inner.write(batch)
    }

    func record(_ issue: ScanIssue) async throws { try await inner.record(issue) }
    func finish(_ summary: ScanSummary) async throws { try await inner.finish(summary) }
    func fail(scanID: ScanID) async throws { try await inner.fail(scanID: scanID) }
    func children(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] {
        try await inner.children(of: nodeID, in: scanID)
    }
    func childPage(of nodeID: NodeID, in scanID: ScanID, limit: Int) async throws -> SnapshotChildPage {
        try await inner.childPage(of: nodeID, in: scanID, limit: limit)
    }
    func name(id: NameID, in scanID: ScanID) async throws -> NameRecord? {
        try await inner.name(id: id, in: scanID)
    }
    func aggregate(of nodeID: NodeID, in scanID: ScanID) async throws -> DirectoryAggregateRecord? {
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

/// Blocks the very first `write` until the test releases a semaphore, so the
/// stream buffer can fill and the engine suppresses a later flush batch.
private actor BlockingWriteRepository: SnapshotRepository {
    private let inner: any SnapshotRepository
    private let gate: DispatchSemaphore
    private var didBlock = false
    private(set) var batchKinds: [String] = []

    init(wrapping inner: any SnapshotRepository, gate: DispatchSemaphore) {
        self.inner = inner
        self.gate = gate
    }

    func begin(_ metadata: ScanMetadata) async throws { try await inner.begin(metadata) }

    func write(_ batch: NodeBatch) async throws {
        batchKinds.append(batch.nodes.map { node in
            node.kind.isDirectoryLike ? "d\(node.id.rawValue)" : "f\(node.id.rawValue)"
        }.joined(separator: ","))
        // Block on the first batch that actually carries nodes, so the buffer
        // holds a later real batch (a name-only flush must not be the blocker).
        if !didBlock, !batch.nodes.isEmpty {
            didBlock = true
            let gate = self.gate
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    gate.wait()
                    continuation.resume()
                }
            }
        }
        try await inner.write(batch)
    }

    func record(_ issue: ScanIssue) async throws { try await inner.record(issue) }
    func finish(_ summary: ScanSummary) async throws { try await inner.finish(summary) }
    func fail(scanID: ScanID) async throws { try await inner.fail(scanID: scanID) }
    func children(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] {
        try await inner.children(of: nodeID, in: scanID)
    }
    func childPage(of nodeID: NodeID, in scanID: ScanID, limit: Int) async throws -> SnapshotChildPage {
        try await inner.childPage(of: nodeID, in: scanID, limit: limit)
    }
    func name(id: NameID, in scanID: ScanID) async throws -> NameRecord? {
        try await inner.name(id: id, in: scanID)
    }
    func aggregate(of nodeID: NodeID, in scanID: ScanID) async throws -> DirectoryAggregateRecord? {
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

/// Root returns `[b, slow]`; `b` finishes with one file; `slow` never finishes.
private final class SuppressedFlushEnumerator: DirectoryEnumerator, @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    func makeCursor(
        in directory: DirectoryHandle,
        request: EnumerationRequest
    ) throws -> any DirectoryCursor {
        let current = lock.withLock { () -> Int in
            let value = index
            index += 1
            return value
        }
        switch current {
        case 0:
            return SinglePageCursor([
                directoryEntry("b", fileID: 2),
                directoryEntry("slow", fileID: 3)
            ])
        case 1:
            return SinglePageCursor([fileEntry("bf", allocated: 10, fileID: 1_000)])
        default:
            return WideCursor(fileCount: 0)
        }
    }
}

private final class StartedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var metadata: ScanMetadata?
    func set(_ value: ScanMetadata) { lock.withLock { metadata = value } }
    var value: ScanMetadata? { lock.withLock { metadata } }
}

/// Thread-safe recorder for the update type sequence.
private final class UpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var types: [String] = []
    func append(_ value: String) { lock.withLock { types.append(value) } }
    var snapshot: [String] { lock.withLock { types } }
}

// MARK: - Tests

@Suite("Cancelled directory checkpoint", .serialized)
struct CancelledCheckpointTests {
    private struct TempRoot {
        let url: URL
        init(prefix: String) throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            url = base
        }
        var path: String { url.path }
        func directory(_ name: String) throws {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    private func makeStore() throws -> (store: SQLiteSnapshotRepository, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacejudge-checkpoint-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("store.sqlite").path
        return (
            try SQLiteSnapshotRepository(
                path: path,
                capacityProvider: FixedStorageCapacityProvider(bytes: 1 << 40)
            ),
            directory
        )
    }

    private func request(for path: String) -> ScanRequest {
        ScanRequest(
            root: ScanRoot(fileSystemPath: path, displayName: "root"),
            boundaryPolicy: .selectedTree
        )
    }

    private func waitForStarted(_ box: StartedBox) async -> ScanMetadata? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let value = box.value { return value }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return box.value
    }

    private func waitUntil(_ predicate: @escaping () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    @Test("A cancelled scan keeps committed leaves reachable through their directory chain")
    func cancelledCheckpointRestoresDirectoryChain() async throws {
        let root = try TempRoot(prefix: "spacejudge-checkpoint")
        defer { root.remove() }
        try root.directory("wide")

        let database = try makeStore()
        defer { try? FileManager.default.removeItem(at: database.directory) }
        let store = database.store
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: WideEnumerator(fileCount: 50, childCompletes: false),
                workerCount: 1,
                batchNodeLimit: 10,
                batchTimeMilliseconds: 1
            )
        )
        let runner = PersistingScanRunner(engine: engine, repository: store)

        let started = StartedBox()
        let recorder = UpdateRecorder()
        let runTask = Task {
            try await runner.run(request(for: root.path)) { update in
                switch update {
                case .started(let metadata): started.set(metadata); recorder.append("started")
                case .committed: recorder.append("committed")
                case .terminal: recorder.append("terminal")
                case .progress, .issueRecorded: break
                }
            }
        }

        let metadata = try #require(await waitForStarted(started))
        let scanID = metadata.scanID
        #expect(await waitUntil {
            let stats = try? await store.statistics(scanID)
            return (stats?.nodeCount ?? 0) > 1
        })
        let cancelStart = ContinuousClock.now
        await engine.cancel(scanID: scanID)
        let summary = try await runTask.value
        let cancelLatency = cancelStart.duration(to: ContinuousClock.now)

        #expect(summary.status == .cancelled)
        #expect(recorder.snapshot.last == "terminal")
        #expect(cancelLatency < .seconds(2))

        let rootChildren = try await store.children(of: metadata.rootNodeID, in: scanID)
        let wide = try #require(rootChildren.first { $0.kind == .directory })
        #expect(rootChildren.filter { $0.id == wide.id }.count == 1)

        let page = try await store.childPage(of: wide.id, in: scanID, limit: 500)
        let file = try #require(page.items.first { $0.node.kind == .regularFile })

        let ancestors = try await store.ancestors(of: file.node.id, in: scanID)
        #expect(ancestors.map(\.id) == [metadata.rootNodeID, wide.id, file.node.id])
        var names: [String?] = []
        for record in ancestors {
            names.append(try await store.name(id: record.name, in: scanID)?.decodedString)
        }
        // The root's persisted name is its directory basename.
        let rootName = URL(fileURLWithPath: root.path).lastPathComponent
        #expect(names == [rootName, "wide", "f0"])

        // Unknown aggregate, not a fabricated zero.
        #expect(try await store.aggregate(of: wide.id, in: scanID) == nil)
        #expect(!engine.debugHasCancelledCheckpoint())
        await store.close()
    }

    @Test("A checkpoint write failure fails the scan instead of publishing cancelled")
    func checkpointWriteFailureFailsScan() async throws {
        let root = try TempRoot(prefix: "spacejudge-checkpoint-fail")
        defer { root.remove() }
        try root.directory("wide")

        let database = try makeStore()
        defer { try? FileManager.default.removeItem(at: database.directory) }
        let store = database.store
        let failing = CheckpointFailingRepository(wrapping: store)
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: WideEnumerator(fileCount: 50, childCompletes: false),
                workerCount: 1,
                batchNodeLimit: 10,
                batchTimeMilliseconds: 1
            )
        )
        let runner = PersistingScanRunner(engine: engine, repository: failing)
        let started = StartedBox()
        let runTask = Task {
            try await runner.run(request(for: root.path)) { update in
                if case .started(let metadata) = update { started.set(metadata) }
            }
        }
        let metadata = try #require(await waitForStarted(started))
        #expect(await waitUntil {
            let stats = try? await store.statistics(metadata.scanID)
            return (stats?.nodeCount ?? 0) > 1
        })
        await engine.cancel(scanID: metadata.scanID)

        var didThrow = false
        do { _ = try await runTask.value } catch { didThrow = true }
        #expect(didThrow)
        #expect(await failing.didFailCheckpoint)
        #expect(try await store.scanState(metadata.scanID)?.status == .failed)
        await store.close()
    }

    @Test("A completed scan retains no checkpoint and a cancelling scan takes it once")
    func checkpointLifecycle() async throws {
        let root = try TempRoot(prefix: "spacejudge-checkpoint-lifecycle")
        defer { root.remove() }
        try root.directory("wide")

        let database = try makeStore()
        defer { try? FileManager.default.removeItem(at: database.directory) }
        let store = database.store
        let completing = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: WideEnumerator(fileCount: 1, childCompletes: true),
                workerCount: 1,
                batchNodeLimit: 10,
                batchTimeMilliseconds: 1
            )
        )
        let runner = PersistingScanRunner(engine: completing, repository: store)
        let summary = try await runner.run(request(for: root.path))
        #expect(summary.status == .completed)
        #expect(!completing.debugHasCancelledCheckpoint())

        // One cancelled scan stores a checkpoint; it is consumed exactly once.
        let cancelling = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: WideEnumerator(fileCount: 50, childCompletes: false),
                workerCount: 1,
                batchNodeLimit: 10,
                batchTimeMilliseconds: 1
            )
        )
        let cancellingRunner = PersistingScanRunner(engine: cancelling, repository: store)
        let started = StartedBox()
        let runTask = Task {
            try await cancellingRunner.run(request(for: root.path)) { update in
                if case .started(let metadata) = update { started.set(metadata) }
            }
        }
        let metadata = try #require(await waitForStarted(started))
        #expect(await waitUntil {
            let stats = try? await store.statistics(metadata.scanID)
            return (stats?.nodeCount ?? 0) > 1
        })
        await cancelling.cancel(scanID: metadata.scanID)
        _ = try await runTask.value
        #expect(!cancelling.debugHasCancelledCheckpoint())
        await store.close()
    }

    @Test("A suppressed in-flight flush still keeps its committed descendants reachable")
    func suppressedFlushKeepsDirectory() async throws {
        let root = try TempRoot(prefix: "spacejudge-checkpoint-suppressed")
        defer { root.remove() }
        try root.directory("b")
        try root.directory("slow")

        let database = try makeStore()
        defer { try? FileManager.default.removeItem(at: database.directory) }
        let store = database.store
        let gate = DispatchSemaphore(value: 0)
        let blocking = BlockingWriteRepository(wrapping: store, gate: gate)
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: SuppressedFlushEnumerator(),
                workerCount: 1,
                batchNodeLimit: 1,
                batchTimeMilliseconds: 1,
                eventBufferSize: 1
            )
        )
        let runner = PersistingScanRunner(engine: engine, repository: blocking)
        let started = StartedBox()
        let runTask = Task {
            try await runner.run(request(for: root.path)) { update in
                if case .started(let metadata) = update { started.set(metadata) }
            }
        }
        let metadata = try #require(await waitForStarted(started))
        // Let the engine produce enough batches that a later flush is dropped on
        // the one-slot buffer while the consumer is blocked on the first write.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let cancelStart = ContinuousClock.now
        await engine.cancel(scanID: metadata.scanID)
        gate.signal()
        let summary = try await runTask.value
        #expect(summary.status == .cancelled)
        #expect(cancelStart.duration(to: ContinuousClock.now) < .seconds(2))

        // `b`'s own directory batch was suppressed, so its node can only have
        // been persisted by the cancelled checkpoint.
        let batches = await blocking.batchKinds
        #expect(!batches.dropLast().contains { $0.contains("d2") })
        #expect(batches.last?.contains("d2") == true)

        let rootChildren = try await store.children(of: metadata.rootNodeID, in: metadata.scanID)
        let b = try #require(rootChildren.first { $0.id.rawValue == 2 && $0.kind == .directory })
        #expect(rootChildren.contains { $0.id.rawValue == 3 })
        // The suppressed file batch was not committed, so nothing is fabricated
        // under `b`; its aggregate stays unknown.
        let page = try await store.childPage(of: b.id, in: metadata.scanID, limit: 500)
        #expect(page.items.isEmpty)
        #expect(try await store.aggregate(of: b.id, in: metadata.scanID) == nil)
        await store.close()
    }

    @Test("Consumer termination stores a bounded checkpoint that a new scan clears")
    func consumerTerminationIsBounded() async throws {
        let root = try TempRoot(prefix: "spacejudge-checkpoint-consumer")
        defer { root.remove() }
        try root.directory("wide")

        let database = try makeStore()
        defer { try? FileManager.default.removeItem(at: database.directory) }
        let store = database.store
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: WideEnumerator(fileCount: 50, childCompletes: false),
                workerCount: 1,
                batchNodeLimit: 10,
                batchTimeMilliseconds: 1
            )
        )
        let scanID = ScanID()
        var stream: AsyncThrowingStream<ScanEvent, any Error>? =
            engine.events(for: request(for: root.path), scanID: scanID)
        // Drop the consumer: its termination cancels the coordinator, which
        // still stores a bounded checkpoint.
        stream = nil
        #expect(await waitUntil { engine.debugHasCancelledCheckpoint() })

        // A new scan clears the slot before producing anything.
        let next = ScanID()
        _ = engine.events(for: request(for: root.path), scanID: next)
        #expect(!engine.debugHasCancelledCheckpoint())
        await engine.cancel(scanID: scanID)
        await engine.cancel(scanID: next)
        await store.close()
    }
}
