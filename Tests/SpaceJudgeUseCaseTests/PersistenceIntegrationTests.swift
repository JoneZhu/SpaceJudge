import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeUseCases

/// Minimal temporary fixture shared by integration tests.
private final class IntegrationFixture {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacejudge-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ relative: String) -> String { url.appendingPathComponent(relative).path }

    func directory(_ relative: String) throws {
        try FileManager.default.createDirectory(
            atPath: path(relative),
            withIntermediateDirectories: true
        )
    }

    func file(_ relative: String, contents: String = "x") throws {
        let target = path(relative)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: target).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: URL(fileURLWithPath: target))
    }

    func symlink(_ relative: String, to target: String) throws {
        let linkPath = path(relative)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: linkPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
    }

    func hardLink(_ relative: String, to existing: String) throws {
        guard link(path(existing), path(relative)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func sparseFile(_ relative: String, logicalSize: Int) throws {
        let target = path(relative)
        try Data().write(to: URL(fileURLWithPath: target))
        guard target.withCString({ truncate($0, off_t(logicalSize)) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private struct CanonicalRow: Equatable {
    var kind: NodeKind
    var logical: UInt64?
    var allocated: UInt64?
    var attributed: UInt64
    var deviceID: UInt64?
    var fileID: UInt64?

    init(_ record: NodeRecord) {
        kind = record.kind
        logical = record.logicalBytes
        allocated = record.allocatedBytes
        attributed = record.attributedBytes
        deviceID = record.deviceID
        fileID = record.fileID
    }
}

private func canonicalTree(
    repository: SQLiteSnapshotRepository,
    scanID: ScanID,
    rootNodeID: NodeID
) async throws -> [String: CanonicalRow] {
    var rows: [String: CanonicalRow] = ["": CanonicalRow(try await rootRecord(repository, scanID, rootNodeID))]
    var stack: [(NodeID, String)] = [(rootNodeID, "")]
    while let (nodeID, prefix) = stack.popLast() {
        let children = try await repository.children(of: nodeID, in: scanID)
        for child in children {
            let name = try await repository.name(id: child.name, in: scanID)?.bytes ?? []
            let component = String(decoding: name, as: UTF8.self)
            let path = prefix.isEmpty ? component : prefix + "/" + component
            rows[path] = CanonicalRow(child)
            if child.kind.isDirectoryLike {
                stack.append((child.id, path))
            }
        }
    }
    return rows
}

private func rootRecord(
    _ repository: SQLiteSnapshotRepository,
    _ scanID: ScanID,
    _ rootNodeID: NodeID
) async throws -> NodeRecord {
    let chain = try await repository.ancestors(of: rootNodeID, in: scanID)
    guard let root = chain.first else {
        throw SnapshotStoreError.scanNotFound(scanID)
    }
    return root
}

@Suite("Persistence integration", .serialized)
struct PersistenceIntegrationTests {
    private func makeFixture() throws -> IntegrationFixture {
        let fixture = try IntegrationFixture()
        try fixture.directory("nested/deep")
        try fixture.directory("empty")
        try fixture.file(".hidden", contents: "hidden")
        try fixture.file("文件夹/资料-📁.txt", contents: "unicode")
        try fixture.file("nested/deep/leaf.txt", contents: "leaf")
        try fixture.file("nested/a.txt", contents: "alpha")
        try fixture.file("nested/b.txt", contents: "beta")
        try fixture.file("hard1", contents: "hardlink-data")
        try fixture.hardLink("hard2", to: "hard1")
        try fixture.sparseFile("sparse.bin", logicalSize: 1_048_576)
        try fixture.symlink("nested/loop", to: "loop")
        return fixture
    }

    private func databaseURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("spacejudge-integration-\(name)-\(UUID().uuidString).sqlite")
    }

    private func cleanup(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    @Test("Reference and bulk persist an identical canonical tree", .timeLimit(.minutes(2)))
    func enginesPersistIdenticalTrees() async throws {
        let fixture = try makeFixture()
        let referenceDB = databaseURL("reference")
        let bulkDB = databaseURL("bulk")
        defer { cleanup(referenceDB); cleanup(bulkDB) }

        let request = ScanRequest(
            root: ScanRoot(fileSystemPath: fixture.url.path, displayName: "fixture")
        )

        let referenceStore = try SQLiteSnapshotRepository(path: referenceDB.path)
        let referenceEngine = FileSystemScanEngine(
            configuration: ScanConfiguration(enumerator: ReferenceEnumerator(), workerCount: 1)
        )
        let referenceSummary = try await PersistingScanRunner(
            engine: referenceEngine,
            repository: referenceStore
        ).run(request)

        let bulkStore = try SQLiteSnapshotRepository(path: bulkDB.path)
        let bulkEngine = FileSystemScanEngine(
            configuration: ScanConfiguration(enumerator: DarwinBulkEnumerator(), workerCount: 2)
        )
        let bulkSummary = try await PersistingScanRunner(
            engine: bulkEngine,
            repository: bulkStore
        ).run(request)

        #expect(referenceSummary.status == .completed)
        #expect(bulkSummary.status == .completed)
        #expect(referenceSummary.fileCount == bulkSummary.fileCount)
        #expect(referenceSummary.directoryCount == bulkSummary.directoryCount)
        #expect(referenceSummary.rootAttributedBytes == bulkSummary.rootAttributedBytes)

        let referenceState = try #require(await referenceStore.scanState(referenceSummary.scanID))
        let bulkState = try #require(await bulkStore.scanState(bulkSummary.scanID))
        let referenceTree = try await canonicalTree(
            repository: referenceStore,
            scanID: referenceSummary.scanID,
            rootNodeID: referenceState.rootNodeID
        )
        let bulkTree = try await canonicalTree(
            repository: bulkStore,
            scanID: bulkSummary.scanID,
            rootNodeID: bulkState.rootNodeID
        )
        #expect(referenceTree.keys.sorted() == bulkTree.keys.sorted())
        for key in referenceTree.keys {
            #expect(referenceTree[key] == bulkTree[key], "row mismatch for \(key)")
        }

        // Aggregates persist identically and stay complete.
        let referenceAggregate = try await referenceStore.aggregate(
            of: referenceState.rootNodeID,
            in: referenceSummary.scanID
        )
        let bulkAggregate = try await bulkStore.aggregate(
            of: bulkState.rootNodeID,
            in: bulkSummary.scanID
        )
        #expect(referenceAggregate?.isComplete == true)
        #expect(bulkAggregate?.isComplete == true)
        #expect(referenceAggregate?.attributedBytes == bulkAggregate?.attributedBytes)
        #expect(referenceAggregate?.descendantFileCount == bulkAggregate?.descendantFileCount)
        #expect(referenceAggregate?.descendantDirectoryCount == bulkAggregate?.descendantDirectoryCount)

        // The runtime path is never persisted.
        #expect(try await referenceStore.scanSummary(referenceSummary.scanID)?.rootDisplayName == "fixture")

        await referenceStore.close()
        await bulkStore.close()
    }

    @Test("A cancelled scan is persisted as cancelled")
    func cancelledSnapshot() async throws {
        let database = databaseURL("cancelled")
        defer { cleanup(database) }
        let store = try SQLiteSnapshotRepository(path: database.path)
        let scanID = ScanID()
        let request = ScanRequest(root: ScanRoot(fileSystemPath: "/synthetic", displayName: "synthetic"))
        let metadata = ScanMetadata(
            scanID: scanID,
            request: request,
            startedAt: Date(timeIntervalSince1970: 0),
            rootNodeID: NodeID(1)
        )
        let summary = ScanSummary(
            scanID: scanID,
            status: .cancelled,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            fileCount: 3,
            directoryCount: 1,
            inaccessibleCount: 0,
            issueCount: 0,
            rootAttributedBytes: 12_288
        )
        let engine = StaticEngine(events: [
            .started(metadata),
            .cancelled(summary)
        ])
        let runner = PersistingScanRunner(engine: engine, repository: store)
        let result = try await runner.run(request)
        #expect(result.status == .cancelled)
        #expect(try await store.scanState(scanID)?.status == .cancelled)
        await store.close()
    }
}

/// Engine used for terminal-state persistence checks.
private actor StaticEngine: ScanEngine {
    private nonisolated let events: [ScanEvent]

    init(events: [ScanEvent]) {
        self.events = events
    }

    nonisolated func events(for request: ScanRequest) -> AsyncThrowingStream<ScanEvent, any Error> {
        let events = self.events
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func cancel(scanID: ScanID) async {}
}
