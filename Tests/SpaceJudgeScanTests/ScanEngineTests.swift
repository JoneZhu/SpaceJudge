import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

/// Injected enumerator that returns scripted directory steps in call order.
private final class ScriptedEnumerator: DirectoryEnumerator, @unchecked Sendable {
    typealias Step = ScriptedCursor.Step

    private let lock = NSLock()
    private var steps: [Step]

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func makeCursor(
        in directory: DirectoryHandle,
        request: EnumerationRequest
    ) throws -> any DirectoryCursor {
        lock.lock()
        let step: Step = steps.isEmpty ? .entries([]) : steps.removeFirst()
        lock.unlock()
        return ScriptedCursor(step)
    }
}

@Suite("Scan engine", .serialized)
struct ScanEngineTests {
    private func request(for path: String) -> ScanRequest {
        ScanRequest(root: ScanRoot(fileSystemPath: path, displayName: path))
    }

    @Test("Missing root fails the stream with a root error")
    func missingRoot() async {
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(workerCount: 1)
        )
        let path = "/spacejudge-does-not-exist-\(UUID().uuidString)"
        do {
            _ = try await collectScan(engine: engine, request: request(for: path))
            Issue.record("expected root failure")
        } catch let error as ScanError {
            #expect(error == .rootOpenFailed(errno: ENOENT))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("Non-directory root is rejected")
    func nonDirectoryRoot() async throws {
        let fixture = try TempFixture()
        let filePath = try fixture.file("plain.txt", contents: "data")
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(workerCount: 1)
        )
        do {
            _ = try await collectScan(engine: engine, request: request(for: filePath))
            Issue.record("expected root failure")
        } catch let error as ScanError {
            #expect(error == .rootOpenFailed(errno: ENOTDIR))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("Child permission failure is recoverable and does not fail the scan")
    func childPermissionFailure() async throws {
        let fixture = try TempFixture()
        try fixture.directory("denied")
        let directoryEntry = RawDirectoryEntry(
            nameBytes: Array("denied".utf8),
            kind: .directory
        )
        let fileEntry = RawDirectoryEntry(
            nameBytes: Array("ok.txt".utf8),
            kind: .regularFile,
            logicalBytes: 10,
            allocatedBytes: 4096,
            deviceID: 1,
            fileID: 5,
            linkCount: 1
        )
        let enumerator = ScriptedEnumerator([
            .entries([fileEntry, directoryEntry]),
            .failure(EACCES)
        ])
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: enumerator,
                workerCount: 1,
                batchNodeLimit: 10
            )
        )
        let collected = try await collectScan(
            engine: engine,
            request: request(for: fixture.url.path)
        )
        #expect(collected.status == .completed)
        #expect(collected.terminalCount == 1)
        #expect(collected.issueCategories[.permissionDenied] == 1)
        #expect(collected.summary?.inaccessibleCount == 1)
        #expect(collected.rootAggregate()?.isComplete == true)
        #expect(collected.rootAggregate()?.attributedBytes == 4096)
        #expect(collected.nodes.values.contains { $0.flags.contains(.inaccessible) })
    }

    @Test("Entry-level errors are counted and skipped")
    func entryErrorSkipped() async throws {
        let fixture = try TempFixture()
        let badEntry = RawDirectoryEntry(
            nameBytes: Array("broken".utf8),
            kind: .unknown,
            entryError: EIO
        )
        let goodEntry = RawDirectoryEntry(
            nameBytes: Array("good.txt".utf8),
            kind: .regularFile,
            logicalBytes: 4,
            allocatedBytes: 4096,
            deviceID: 1,
            fileID: 9,
            linkCount: 1
        )
        let enumerator = ScriptedEnumerator([.entries([badEntry, goodEntry])])
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(enumerator: enumerator, workerCount: 1)
        )
        let collected = try await collectScan(
            engine: engine,
            request: request(for: fixture.url.path)
        )
        #expect(collected.status == .completed)
        #expect(collected.issueCategories[.io] == 1)
        #expect(collected.nodes.values.contains { $0.kind == .regularFile })
        #expect(!collected.nodes.values.contains { $0.kind == .unknown })
    }

    @Test("Every scan emits exactly one terminal event")
    func singleTerminal() async throws {
        let fixture = try TempFixture()
        try fixture.directory("a/b/c")
        try fixture.file("a/f1")
        try fixture.file("a/b/f2")
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1
            )
        )
        let collected = try await collectScan(
            engine: engine,
            request: request(for: fixture.url.path)
        )
        #expect(collected.terminalCount == 1)
        #expect(collected.status == .completed)
        #expect(collected.batchesAfterTerminal == 0)
    }

    @Test("Cancel with thousands of entries emits one cancelled terminal")
    func cancelLargeScan() async throws {
        let fixture = try TempFixture()
        for index in 0..<3000 {
            try fixture.file("f\(index)", contents: "x")
        }
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1,
                batchNodeLimit: 20,
                eventBufferSize: 4
            )
        )
        let collected = try await collectScan(
            engine: engine,
            request: request(for: fixture.url.path),
            cancelAfterFirstBatch: true
        )
        #expect(collected.status == .cancelled)
        #expect(collected.terminalCount == 1)
        #expect(collected.batchesAfterTerminal == 0)
    }

    @Test("Repeated scans return file descriptors to baseline")
    func fileDescriptorBaseline() async throws {
        let fixture = try TempFixture()
        try fixture.directory("a/b")
        for index in 0..<64 {
            try fixture.file("a/f\(index)", contents: "x")
        }
        try fixture.symlink("a/link", to: "f0")
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: DarwinBulkEnumerator(),
                workerCount: 2
            )
        )
        _ = try await collectScan(engine: engine, request: request(for: fixture.url.path))
        let before = openFileDescriptorCount()
        for _ in 0..<3 {
            _ = try await collectScan(engine: engine, request: request(for: fixture.url.path))
        }
        let after = openFileDescriptorCount()
        // Tolerance covers transient descriptors from other parallel suites;
        // a leak would grow by more than the number of scans.
        #expect(after <= before + 8, "fd before=\(before) after=\(after)")
    }

    @Test("Coordinator registry rejects duplicate scan IDs")
    func duplicateRegistry() async {
        let registry = CoordinatorRegistry()
        let scanID = ScanID()
        let request = request(for: "/tmp")
        let configuration = ScanConfiguration(workerCount: 1)
        let first = ScanCoordinator(scanID: scanID, request: request, configuration: configuration)
        let second = ScanCoordinator(scanID: scanID, request: request, configuration: configuration)
        #expect(registry.insert(first, for: scanID))
        #expect(!registry.insert(second, for: scanID))
        registry.remove(scanID)
        #expect(registry.insert(second, for: scanID))
    }

    @Test("A directory that vanishes mid-scan is recoverable")
    func vanishedDirectory() async throws {
        let fixture = try TempFixture()
        let vanished = RawDirectoryEntry(
            nameBytes: Array("vanished".utf8),
            kind: .directory
        )
        let enumerator = ScriptedEnumerator([.entries([vanished])])
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(enumerator: enumerator, workerCount: 1)
        )
        let collected = try await collectScan(
            engine: engine,
            request: request(for: fixture.url.path)
        )
        #expect(collected.status == .completed)
        #expect(collected.summary?.issueCount == 1)
        #expect(collected.summary?.inaccessibleCount == 1)
        // changedDuringScan is counted, not surfaced as a per-item issue event.
        #expect(collected.issueCategories.isEmpty)
        #expect(collected.nodes.values.contains { $0.flags.contains(.changedDuringScan) })
        #expect(collected.rootAggregate()?.isComplete == true)
    }

    @Test("Names are emitted no later than the nodes that reference them")
    func nameEmissionOrder() async throws {
        let fixture = try TempFixture()
        try fixture.directory("a/b")
        for index in 0..<40 {
            try fixture.file("a/b/file-\(index)", contents: "x")
        }
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1,
                batchNodeLimit: 3
            )
        )
        var knownNames: Set<NameID> = []
        var violations = 0
        var completedAggregates: Set<NodeID> = []
        var aggregateAfterCompletion = 0
        for try await event in engine.events(for: request(for: fixture.url.path)) {
            guard case .batch(let batch) = event else { continue }
            for name in batch.names {
                knownNames.insert(name.id)
            }
            for node in batch.nodes where !knownNames.contains(node.name) {
                violations += 1
            }
            for aggregate in batch.directoryAggregates {
                if aggregate.isComplete, completedAggregates.contains(aggregate.nodeID) {
                    aggregateAfterCompletion += 1
                }
                completedAggregates.insert(aggregate.nodeID)
            }
        }
        #expect(violations == 0)
        #expect(aggregateAfterCompletion == 0)
        #expect(knownNames.count >= 42)
    }
}
