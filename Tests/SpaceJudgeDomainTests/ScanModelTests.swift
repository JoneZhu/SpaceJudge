import Foundation
import Testing
import SpaceJudgeDomain

@Suite("Scan model")
struct ScanModelTests {
    @Test("Volume used is total minus available")
    func volumeUsed() {
        let volume = VolumeFacts(
            totalCapacityBytes: 1000,
            availableCapacityBytes: 250,
            capacitySource: .importantUsage
        )
        #expect(volume.usedBytes == 750)

        let unknown = VolumeFacts(totalCapacityBytes: 1000, availableCapacityBytes: nil, capacitySource: .unavailable)
        #expect(unknown.usedBytes == nil)

        let inconsistent = VolumeFacts(totalCapacityBytes: 100, availableCapacityBytes: 500, capacitySource: .standardAvailable)
        #expect(inconsistent.usedBytes == nil)
    }

    @Test("Summary reconciles attributed and volume used")
    func summaryReconciliation() {
        let volume = VolumeFacts(totalCapacityBytes: 1000, availableCapacityBytes: 400, capacitySource: .importantUsage)
        let summary = ScanSummary(
            scanID: Fixtures.scanID(),
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 10),
            fileCount: 3,
            directoryCount: 1,
            inaccessibleCount: 0,
            issueCount: 0,
            rootAttributedBytes: 300,
            volume: volume
        )
        #expect(summary.unattributedBytes == 300)
        #expect(summary.overAttributedBytes == 0)

        let over = ScanSummary(
            scanID: Fixtures.scanID(),
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 0),
            fileCount: 3,
            directoryCount: 1,
            inaccessibleCount: 0,
            issueCount: 0,
            rootAttributedBytes: 900,
            volume: volume
        )
        #expect(over.unattributedBytes == 0)
        #expect(over.overAttributedBytes == 300)
    }

    @Test("Unattributed is nil without volume facts")
    func summaryWithoutVolume() {
        let summary = ScanSummary(
            scanID: Fixtures.scanID(),
            status: .cancelled,
            startedAt: Date(timeIntervalSince1970: 0),
            fileCount: 0,
            directoryCount: 0,
            inaccessibleCount: 0,
            issueCount: 0,
            rootAttributedBytes: 0
        )
        #expect(summary.unattributedBytes == nil)
    }

    @Test("ScanRoot keeps runtime path and display name separate")
    func scanRootFields() throws {
        let root = ScanRoot(
            fileSystemPath: "/Users/example/Library/Caches",
            displayName: "Caches",
            fileSystemID: 42
        )
        #expect(root.fileSystemPath != root.displayName)
        #expect(root.fileSystemPath == "/Users/example/Library/Caches")
        #expect(root.displayName == "Caches")
        #expect(root.fileSystemID == 42)

        let data = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(ScanRoot.self, from: data)
        #expect(decoded == root)
        #expect(decoded.fileSystemPath == root.fileSystemPath)
        #expect(decoded.displayName == root.displayName)

        let withoutFileSystem = ScanRoot(fileSystemPath: "/tmp/x", displayName: "/tmp/x")
        #expect(withoutFileSystem.fileSystemID == nil)
        #expect(withoutFileSystem.fileSystemPath == withoutFileSystem.displayName)
    }

    @Test("Node flags compose and stay independent")
    func nodeFlags() {
        let flags: NodeFlags = [.package, .duplicateHardLink]
        #expect(flags.contains(.package))
        #expect(flags.contains(.duplicateHardLink))
        #expect(!flags.contains(.symlinkLoop))
        #expect(NodeFlags.package.rawValue != NodeFlags.duplicateHardLink.rawValue)

        let combined = NodeFlags.package.union(.sparse)
        #expect(combined == [NodeFlags.package, NodeFlags.sparse])
    }

    @Test("Only directory-like kinds own children")
    func nodeKind() {
        #expect(NodeKind.directory.isDirectoryLike)
        #expect(NodeKind.mountPoint.isDirectoryLike)
        #expect(!NodeKind.regularFile.isDirectoryLike)
        #expect(!NodeKind.symbolicLink.isDirectoryLike)
    }

    @Test("ScanEvent is value-comparable")
    func scanEvents() {
        let batch = NodeBatch(
            scanID: Fixtures.scanID(),
            revision: Revision(3),
            nodes: [Fixtures.record(id: 1, parent: 0, attributedBytes: 5)]
        )
        #expect(ScanEvent.batch(batch) == ScanEvent.batch(batch))
        #expect(ScanEvent.started(metadata()) != ScanEvent.batch(batch))
    }

    private func metadata() -> ScanMetadata {
        ScanMetadata(
            scanID: Fixtures.scanID(),
            request: ScanRequest(root: ScanRoot(fileSystemPath: "/tmp/spacejudge", displayName: "spacejudge")),
            startedAt: Date(timeIntervalSince1970: 0),
            rootNodeID: NodeID(1)
        )
    }
}

/// A minimal in-memory `ScanEngine` used to prove the protocol is
/// implementable with Sendable value types and no UI/platform leakage.
private struct StubScanEngine: ScanEngine {
    func events(for request: ScanRequest) -> AsyncThrowingStream<ScanEvent, any Error> {
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func cancel(scanID: ScanID) async {}
}

private actor StubRepository: SnapshotRepository {
    private var scans: [ScanID: ScanMetadata] = [:]
    private var nodes: [ScanID: [NodeRecord]] = [:]
    private var names: [ScanID: [NameID: NameRecord]] = [:]

    func begin(_ metadata: ScanMetadata) async throws {
        scans[metadata.scanID] = metadata
    }

    func write(_ batch: NodeBatch) async throws {
        for name in batch.names {
            names[batch.scanID, default: [:]][name.id] = name
        }
        nodes[batch.scanID, default: []].append(contentsOf: batch.nodes)
    }

    func record(_ issue: ScanIssue) async throws {}

    func finish(_ summary: ScanSummary) async throws {}

    func fail(scanID: ScanID) async throws {}

    func children(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] {
        (nodes[scanID] ?? []).filter { $0.parentID == nodeID }
    }

    func childPage(
        of nodeID: NodeID,
        in scanID: ScanID,
        limit: Int
    ) async throws -> SnapshotChildPage {
        let ordered = (nodes[scanID] ?? [])
            .filter { $0.parentID == nodeID }
            .sorted {
                if $0.attributedBytes != $1.attributedBytes {
                    return $0.attributedBytes > $1.attributedBytes
                }
                return $0.id.rawValue < $1.id.rawValue
            }
        let items = ordered.prefix(limit).compactMap { node -> SnapshotChildItem? in
            guard let name = names[scanID]?[node.name] else { return nil }
            return SnapshotChildItem(node: node, name: name)
        }
        return SnapshotChildPage(items: Array(items), totalCount: UInt64(ordered.count))
    }

    func name(id: NameID, in scanID: ScanID) async throws -> NameRecord? {
        names[scanID]?[id]
    }

    func aggregate(of nodeID: NodeID, in scanID: ScanID) async throws -> DirectoryAggregateRecord? {
        nil
    }

    func ancestors(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] {
        []
    }

    func scanState(_ scanID: ScanID) async throws -> ScanSnapshotState? { nil }

    func scanSummary(_ scanID: ScanID) async throws -> ScanSnapshotSummary? { nil }

    func issueSummary(_ scanID: ScanID) async throws -> [IssueAggregateSummary] { [] }

    func statistics(_ scanID: ScanID) async throws -> SnapshotStatistics {
        SnapshotStatistics(nodeCount: 0, nameCount: 0, aggregateCount: 0, issueCount: 0)
    }
}

@Suite("Protocols")
struct ProtocolTests {
    @Test("ScanEngine stub emits a terminal stream")
    func scanEngineStub() async throws {
        let engine = StubScanEngine()
        var count = 0
        for try await _ in engine.events(for: ScanRequest(root: ScanRoot(fileSystemPath: "/tmp", displayName: "tmp"))) {
            count += 1
        }
        #expect(count == 0)
        await engine.cancel(scanID: Fixtures.scanID())
    }

    @Test("SnapshotRepository stores and queries children")
    func repositoryStub() async throws {
        let repository = StubRepository()
        let scanID = Fixtures.scanID(3)
        let metadata = ScanMetadata(
            scanID: scanID,
            request: ScanRequest(root: ScanRoot(fileSystemPath: "/tmp", displayName: "tmp")),
            startedAt: Date(timeIntervalSince1970: 0),
            rootNodeID: NodeID(1)
        )
        try await repository.begin(metadata)
        let batch = NodeBatch(
            scanID: scanID,
            revision: Revision(1),
            nodes: [
                Fixtures.record(id: 2, parent: 1, attributedBytes: 4, scanID: scanID),
                Fixtures.record(id: 3, parent: 1, attributedBytes: 6, scanID: scanID),
                Fixtures.record(id: 4, parent: 2, attributedBytes: 1, scanID: scanID)
            ]
        )
        try await repository.write(batch)
        let children = try await repository.children(of: NodeID(1), in: scanID)
        #expect(children.map(\.id) == [NodeID(2), NodeID(3)])
    }
}
