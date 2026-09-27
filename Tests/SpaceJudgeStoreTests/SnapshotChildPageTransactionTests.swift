import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeStore

/// Phase 4 child-page contract: revision, parent aggregate, total count and
/// items must come from one read-only snapshot, and a failed read must leave
/// the reader usable.
@Suite("Snapshot child page transaction", .serialized)
struct SnapshotChildPageTransactionTests {
    private func seed(
        _ repository: SQLiteSnapshotRepository,
        scanID: ScanID,
        childCount: Int,
        complete: Bool = true
    ) async throws {
        try await repository.begin(sampleMetadata(scanID: scanID))
        var names: [NameRecord] = [sampleName(1, "root")]
        var nodes: [NodeRecord] = [
            sampleNode(
                id: 1, parent: nil, name: 1, scanID: scanID,
                kind: .directory, logical: nil, allocated: nil, attributed: 0
            )
        ]
        for index in 0..<childCount {
            let nameID = UInt64(index + 2)
            names.append(NameRecord(id: NameID(nameID), bytes: Array("item-\(index)".utf8)))
            nodes.append(
                sampleNode(
                    id: UInt64(index + 2), parent: 1, name: nameID, scanID: scanID,
                    kind: .regularFile, attributed: UInt64((index + 1) * 100)
                )
            )
        }
        try await repository.write(
            NodeBatch(scanID: scanID, revision: Revision(1), names: names, nodes: nodes)
        )
        // Advance the scan revision with an extra append-only batch, then add
        // the parent aggregate in a third revision.
        try await repository.write(
            NodeBatch(scanID: scanID, revision: Revision(2), nodes: [])
        )
        let total: UInt64 = childCount == 0
            ? 0
            : UInt64((1...childCount).reduce(0) { $0 + $1 * 100 })
        try await repository.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(3),
                nodes: [],
                directoryAggregates: [
                    DirectoryAggregateRecord(
                        nodeID: NodeID(1),
                        logicalBytes: total,
                        allocatedBytes: total,
                        attributedBytes: total,
                        descendantFileCount: UInt64(childCount),
                        descendantDirectoryCount: 0,
                        inaccessibleDescendantCount: 0,
                        isComplete: complete
                    )
                ]
            )
        )
    }

    @Test("Revision, aggregate, count and items describe one snapshot")
    func consistency() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await seed(repository, scanID: scanID, childCount: 4)

        let page = try await repository.childPage(of: NodeID(1), in: scanID, limit: 500)
        #expect(page.totalCount == 4)
        #expect(page.items.count == 4)
        #expect(page.snapshotRevision == Revision(3))
        #expect(page.parentAggregate != nil)
        #expect(page.parentAggregate?.isComplete == true)
        await repository.close()
    }

    @Test("An empty page still reports the revision and parent aggregate")
    func emptyPage() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await seed(repository, scanID: scanID, childCount: 0)

        let page = try await repository.childPage(of: NodeID(1), in: scanID, limit: 10)
        #expect(page.items.isEmpty)
        #expect(page.totalCount == 0)
        #expect(page.snapshotRevision == Revision(3))
        #expect(page.parentAggregate != nil)
        await repository.close()
    }

    @Test("A partial parent aggregate is carried as best-known")
    func partialAggregate() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await seed(repository, scanID: scanID, childCount: 3, complete: false)

        let page = try await repository.childPage(of: NodeID(1), in: scanID, limit: 2)
        #expect(page.items.count == 2)
        #expect(page.totalCount == 3)
        #expect(page.parentAggregate?.isComplete == false)
        await repository.close()
    }

    @Test("A failed query leaves the read transaction usable")
    func failureRecovery() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await seed(repository, scanID: scanID, childCount: 3)

        await #expect(throws: SnapshotQueryError.invalidChildPageLimit(0)) {
            _ = try await repository.childPage(of: NodeID(1), in: scanID, limit: 0)
        }
        // The reader must not be stuck inside a transaction.
        let page = try await repository.childPage(of: NodeID(1), in: scanID, limit: 2)
        #expect(page.items.count == 2)
        #expect(page.parentAggregate != nil)

        // A second connection can still write while the reader is idle.
        try await repository.write(
            NodeBatch(scanID: scanID, revision: Revision(4), nodes: [])
        )
        let second = try await repository.childPage(of: NodeID(1), in: scanID, limit: 2)
        #expect(second.snapshotRevision == Revision(4))
        await repository.close()
    }

    @Test("A throw inside withReadTransaction leaves the connection usable")
    func readTransactionFailureRecovery() async throws {
        let database = try TempDatabase()
        let handle = try SQLiteDatabase.openReadWrite(path: database.path)
        enum Injected: Error { case boom }

        // The body throws after BEGIN; the primitive must roll back and leave
        // the connection able to start a fresh transaction.
        #expect(throws: Injected.self) {
            try handle.withReadTransaction { () -> Void in throw Injected.boom }
        }
        let value = try handle.withReadTransaction { 42 }
        #expect(value == 42)

        // A repository on the same file still works end to end.
        let repository = try database.open()
        let scanID = sampleScanID()
        try await seed(repository, scanID: scanID, childCount: 3)
        let page = try await repository.childPage(of: NodeID(1), in: scanID, limit: 2)
        #expect(page.items.count == 2)
        #expect(page.parentAggregate != nil)
        await repository.close()
        handle.close()
    }

    @Test("Read-only connection exposes the same revision and aggregate")
    func readOnlyConsistency() async throws {
        let database = try TempDatabase()
        let writer = try database.open()
        let scanID = sampleScanID()
        try await seed(writer, scanID: scanID, childCount: 5)
        await writer.close()

        let reader = try SQLiteSnapshotRepository.openReadOnly(path: database.path)
        let page = try await reader.childPage(of: NodeID(1), in: scanID, limit: 2)
        #expect(page.totalCount == 5)
        #expect(page.snapshotRevision == Revision(3))
        #expect(page.parentAggregate?.attributedBytes ?? 0 > 0)
        await reader.close()
    }
}
