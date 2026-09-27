import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeStore

@Suite("SQLite snapshot repository", .serialized)
struct SQLiteSnapshotRepositoryTests {
    private func completedSummary(_ scanID: ScanID, fileCount: UInt64 = 2) -> ScanSummary {
        ScanSummary(
            scanID: scanID,
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_000),
            finishedAt: Date(timeIntervalSince1970: 2_000),
            fileCount: fileCount,
            directoryCount: 1,
            inaccessibleCount: 0,
            issueCount: 0,
            rootAttributedBytes: 12_288
        )
    }

    private func writeTree(_ repository: SQLiteSnapshotRepository, scanID: ScanID) async throws {
        let names = [
            sampleName(1, "root"),
            sampleName(2, "alpha"),
            sampleName(3, "beta"),
            sampleName(4, "child")
        ]
        let nodes = [
            sampleNode(id: 1, parent: nil, name: 1, scanID: scanID, kind: .directory, logical: nil, allocated: nil, attributed: 0),
            sampleNode(id: 2, parent: 1, name: 2, scanID: scanID, attributed: 100),
            sampleNode(id: 3, parent: 1, name: 3, scanID: scanID, attributed: 200),
            sampleNode(id: 4, parent: 2, name: 4, scanID: scanID, attributed: 50)
        ]
        let aggregates = [
            DirectoryAggregateRecord(
                nodeID: NodeID(1),
                logicalBytes: 300,
                allocatedBytes: 300,
                attributedBytes: 300,
                descendantFileCount: 3,
                descendantDirectoryCount: 0,
                inaccessibleDescendantCount: 0,
                isComplete: true
            ),
            DirectoryAggregateRecord(
                nodeID: NodeID(2),
                logicalBytes: 50,
                allocatedBytes: 50,
                attributedBytes: 50,
                descendantFileCount: 1,
                descendantDirectoryCount: 0,
                inaccessibleDescendantCount: 0,
                isComplete: true
            )
        ]
        try await repository.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(1),
                names: names,
                nodes: nodes,
                directoryAggregates: aggregates
            )
        )
    }

    // MARK: Schema

    @Test("Schema version is 1 and survives reopen")
    func schemaVersionAndReopen() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        #expect(try await repository.schemaVersion() == 1)
        try await repository.begin(sampleMetadata(scanID: sampleScanID()))
        await repository.close()

        let reopened = try database.open()
        #expect(try await reopened.schemaVersion() == 1)
        await reopened.close()
    }

    @Test("WAL and foreign keys are enabled, and unsupported versions fail")
    func walAndForeignKeys() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        try await repository.begin(sampleMetadata(scanID: sampleScanID()))
        #expect(try await repository.debugForeignKeysEnabled())
        await repository.close()

        do {
            let raw = try SQLiteDatabase.openReadOnly(path: database.path)
            let mode = try raw.prepare("PRAGMA journal_mode")
            _ = try mode.step()
            let value = mode.columnText(0)?.lowercased()
            mode.finalize()
            raw.close()
            #expect(value == "wal")
        }

        do {
            let raw = try SQLiteDatabase.openReadWrite(path: database.path)
            try raw.execute("PRAGMA user_version = 99")
            raw.close()
        }

        #expect(throws: SnapshotStoreError.unsupportedSchemaVersion(found: 99)) {
            _ = try SQLiteSnapshotRepository(path: database.path)
        }
    }

    @Test("A node referencing an unknown name fails its foreign key")
    func foreignKeyOnName() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        let batch = NodeBatch(
            scanID: scanID,
            revision: Revision(1),
            names: [sampleName(1, "root")],
            nodes: [sampleNode(id: 1, parent: nil, name: 1, scanID: scanID, kind: .directory)]
        )
        try await repository.write(batch)

        let orphan = NodeBatch(
            scanID: scanID,
            revision: Revision(2),
            names: [],
            nodes: [sampleNode(id: 2, parent: 1, name: 999, scanID: scanID)]
        )
        await #expect(throws: (any Error).self) {
            try await repository.write(orphan)
        }
        await repository.close()
    }

    // MARK: State machine

    @Test("begin/write/finish moves running to completed")
    func happyPath() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await writeTree(repository, scanID: scanID)
        #expect(try await repository.scanState(scanID)?.status == .running)
        try await repository.finish(completedSummary(scanID))
        #expect(try await repository.scanState(scanID)?.status == .completed)
        await repository.close()
    }

    @Test("Duplicate begin fails")
    func duplicateBegin() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        await #expect(throws: SnapshotStoreError.scanAlreadyExists(scanID)) {
            try await repository.begin(sampleMetadata(scanID: scanID))
        }
        await repository.close()
    }

    @Test("Writes and finishes after a terminal state fail")
    func terminalTransitions() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await repository.finish(completedSummary(scanID))

        await #expect(throws: SnapshotStoreError.scanNotRunning(scanID: scanID, status: .completed)) {
            try await repository.write(
                NodeBatch(
                    scanID: scanID,
                    revision: Revision(1),
                    names: [],
                    nodes: [sampleNode(id: 1, parent: nil, name: 1, scanID: scanID)]
                )
            )
        }
        await #expect(throws: SnapshotStoreError.scanNotRunning(scanID: scanID, status: .completed)) {
            try await repository.fail(scanID: scanID)
        }
        await #expect(throws: SnapshotStoreError.scanNotRunning(scanID: scanID, status: .completed)) {
            try await repository.finish(completedSummary(scanID))
        }
        await repository.close()
    }

    @Test("fail moves running to failed and only running may fail")
    func failTransition() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await repository.fail(scanID: scanID)
        #expect(try await repository.scanState(scanID)?.status == .failed)
        await #expect(throws: SnapshotStoreError.scanNotRunning(scanID: scanID, status: .failed)) {
            try await repository.fail(scanID: scanID)
        }
        await repository.close()
    }

    @Test("A leftover running scan becomes interrupted on reopen")
    func interruptedOnReopen() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        await repository.close()

        let reopened = try database.open()
        #expect(try await reopened.scanState(scanID)?.status == .interrupted)
        await reopened.close()
    }

    // MARK: Revisions and atomicity

    @Test("Revisions must be contiguous")
    func revisionContiguity() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await repository.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(1),
                names: [sampleName(1, "root")],
                nodes: [sampleNode(id: 1, parent: nil, name: 1, scanID: scanID, kind: .directory)]
            )
        )

        await #expect(throws: SnapshotStoreError.revisionNotContiguous(expected: 1, found: 3)) {
            try await repository.write(
                NodeBatch(scanID: scanID, revision: Revision(3), names: [], nodes: [])
            )
        }
        await #expect(throws: SnapshotStoreError.revisionNotContiguous(expected: 1, found: 1)) {
            try await repository.write(
                NodeBatch(scanID: scanID, revision: Revision(1), names: [], nodes: [])
            )
        }
        await repository.close()
    }

    @Test("A failing batch rolls back entirely, including its names")
    func batchRollback() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await writeTree(repository, scanID: scanID)
        let before = try await repository.statistics(scanID)

        // Duplicate NodeID 1 after a new name 9: the whole batch must roll back.
        let duplicate = NodeBatch(
            scanID: scanID,
            revision: Revision(2),
            names: [sampleName(9, "new-name")],
            nodes: [sampleNode(id: 1, parent: 1, name: 9, scanID: scanID)]
        )
        await #expect(throws: SnapshotStoreError.duplicateNodeID(NodeID(1))) {
            try await repository.write(duplicate)
        }
        let after = try await repository.statistics(scanID)
        #expect(before == after)
        #expect(try await repository.name(id: NameID(9), in: scanID) == nil)
        await repository.close()
    }

    @Test("A node whose ScanID differs from its batch fails the whole batch")
    func nodeScanIDMismatchFails() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        let otherScanID = sampleScanID(2)
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await writeTree(repository, scanID: scanID)
        let before = try await repository.statistics(scanID)

        let badBatch = NodeBatch(
            scanID: scanID,
            revision: Revision(2),
            names: [sampleName(9, "new-name")],
            nodes: [sampleNode(id: 9, parent: 1, name: 9, scanID: otherScanID)]
        )
        await #expect(
            throws: SnapshotStoreError.nodeScanIDMismatch(
                nodeID: NodeID(9),
                expected: scanID,
                found: otherScanID
            )
        ) {
            try await repository.write(badBatch)
        }

        // Name, node and revision must all be untouched by the rolled-back batch.
        #expect(try await repository.name(id: NameID(9), in: scanID) == nil)
        #expect(try await repository.statistics(scanID) == before)
        #expect(try await repository.children(of: NodeID(1), in: scanID).allSatisfy { $0.id != NodeID(9) })

        // Revision was not advanced, so the real revision 2 still applies.
        try await repository.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(2),
                names: [sampleName(9, "new-name")],
                nodes: [sampleNode(id: 9, parent: 1, name: 9, scanID: scanID)]
            )
        )
        #expect(try await repository.name(id: NameID(9), in: scanID) != nil)
        await repository.close()
    }

    @Test("A COMMIT failure rolls back and leaves the connection reusable")
    func commitFailureRollsBack() throws {
        let database = try TempDatabase()
        let raw = try SQLiteDatabase.openReadWrite(path: database.path)
        try raw.execute("PRAGMA foreign_keys=ON")
        try raw.execute("CREATE TABLE parent (id INTEGER PRIMARY KEY)")
        try raw.execute(
            "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)"
        )

        // body succeeds but the deferred foreign key fails at COMMIT.
        #expect(throws: (any Error).self) {
            try raw.withTransaction {
                try raw.execute("INSERT INTO child (id, parent_id) VALUES (1, 999)")
            }
        }
        // The connection must not be stuck inside a transaction.
        #expect(throws: Never.self) {
            try raw.withTransaction {
                try raw.execute("INSERT INTO parent (id) VALUES (999)")
                try raw.execute("INSERT INTO child (id, parent_id) VALUES (1, 999)")
            }
        }

        let count = try raw.prepare("SELECT COUNT(*) FROM parent")
        defer { count.finalize() }
        _ = try count.step()
        #expect(count.columnInt64(0) == 1)
        raw.close()
    }

    @Test("Name ID and name-bytes conflicts fail")
    func nameConflicts() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await repository.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(1),
                names: [sampleName(1, "root")],
                nodes: [sampleNode(id: 1, parent: nil, name: 1, scanID: scanID, kind: .directory)]
            )
        )
        await #expect(throws: SnapshotStoreError.duplicateNameID(NameID(1))) {
            try await repository.write(
                NodeBatch(
                    scanID: scanID,
                    revision: Revision(2),
                    names: [sampleName(1, "different")],
                    nodes: [sampleNode(id: 2, parent: 1, name: 1, scanID: scanID)]
                )
            )
        }
        await #expect(throws: SnapshotStoreError.nameBytesConflict(NameID(1))) {
            try await repository.write(
                NodeBatch(
                    scanID: scanID,
                    revision: Revision(2),
                    names: [sampleName(2, "root")],
                    nodes: [sampleNode(id: 2, parent: 1, name: 2, scanID: scanID)]
                )
            )
        }
        await repository.close()
    }

    // MARK: Aggregates

    @Test("Aggregates may grow but a complete aggregate is frozen")
    func aggregateLifecycle() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await repository.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(1),
                names: [sampleName(1, "root")],
                nodes: [sampleNode(id: 1, parent: nil, name: 1, scanID: scanID, kind: .directory)]
            )
        )

        let partial = DirectoryAggregateRecord(
            nodeID: NodeID(1), logicalBytes: 10, allocatedBytes: 10, attributedBytes: 10,
            descendantFileCount: 1, descendantDirectoryCount: 0,
            inaccessibleDescendantCount: 0, isComplete: false
        )
        try await repository.write(
            NodeBatch(scanID: scanID, revision: Revision(2), names: [], nodes: [], directoryAggregates: [partial])
        )
        let complete = DirectoryAggregateRecord(
            nodeID: NodeID(1), logicalBytes: 20, allocatedBytes: 20, attributedBytes: 20,
            descendantFileCount: 2, descendantDirectoryCount: 0,
            inaccessibleDescendantCount: 0, isComplete: true
        )
        try await repository.write(
            NodeBatch(scanID: scanID, revision: Revision(3), names: [], nodes: [], directoryAggregates: [complete])
        )
        #expect(try await repository.aggregate(of: NodeID(1), in: scanID) == complete)

        // Identical complete upsert is idempotent.
        try await repository.write(
            NodeBatch(scanID: scanID, revision: Revision(4), names: [], nodes: [], directoryAggregates: [complete])
        )

        // Changed complete aggregate fails.
        let changed = DirectoryAggregateRecord(
            nodeID: NodeID(1), logicalBytes: 21, allocatedBytes: 20, attributedBytes: 20,
            descendantFileCount: 2, descendantDirectoryCount: 0,
            inaccessibleDescendantCount: 0, isComplete: true
        )
        await #expect(throws: SnapshotStoreError.completeAggregateChanged(NodeID(1))) {
            try await repository.write(
                NodeBatch(scanID: scanID, revision: Revision(5), names: [], nodes: [], directoryAggregates: [changed])
            )
        }

        // Rolling a complete aggregate back to incomplete also fails.
        let rolledBack = DirectoryAggregateRecord(
            nodeID: NodeID(1), logicalBytes: 20, allocatedBytes: 20, attributedBytes: 20,
            descendantFileCount: 2, descendantDirectoryCount: 0,
            inaccessibleDescendantCount: 0, isComplete: false
        )
        await #expect(throws: SnapshotStoreError.completeAggregateChanged(NodeID(1))) {
            try await repository.write(
                NodeBatch(scanID: scanID, revision: Revision(5), names: [], nodes: [], directoryAggregates: [rolledBack])
            )
        }
        await repository.close()
    }

    @Test("The runtime scan path is never persisted")
    func runtimePathNotPersisted() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        let runtimePath = "/private/tmp/spacejudge-do-not-persist-\(UUID().uuidString)"
        try await repository.begin(
            ScanMetadata(
                scanID: scanID,
                request: ScanRequest(
                    root: ScanRoot(fileSystemPath: runtimePath, displayName: "root")
                ),
                startedAt: Date(timeIntervalSince1970: 1_000),
                rootNodeID: NodeID(1)
            )
        )
        try await repository.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(1),
                names: [sampleName(1, "root")],
                nodes: [sampleNode(id: 1, parent: nil, name: 1, scanID: scanID, kind: .directory)]
            )
        )
        #expect(try await repository.scanSummary(scanID)?.rootDisplayName == "root")
        await repository.close()

        let bytes = try Data(contentsOf: URL(fileURLWithPath: database.path))
        #expect(bytes.range(of: Data(runtimePath.utf8)) == nil, "runtime path leaked into the database")
    }

    // MARK: Queries

    @Test("children returns attributed bytes descending then NodeID ascending")
    func childrenOrdering() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await writeTree(repository, scanID: scanID)
        let children = try await repository.children(of: NodeID(1), in: scanID)
        #expect(children.map(\.id) == [NodeID(3), NodeID(2)])
        await repository.close()
    }

    @Test("Names round-trip raw bytes including invalid UTF-8")
    func rawNameBytes() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        let invalid: [UInt8] = [0x66, 0x80, 0xFF, 0x6F]
        try await repository.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(1),
                names: [sampleName(1, "root"), NameRecord(id: NameID(2), bytes: invalid)],
                nodes: [
                    sampleNode(id: 1, parent: nil, name: 1, scanID: scanID, kind: .directory),
                    sampleNode(id: 2, parent: 1, name: 2, scanID: scanID)
                ]
            )
        )
        let name = try await repository.name(id: NameID(2), in: scanID)
        #expect(name?.bytes == invalid)
        #expect(name?.decodedString == nil)
        await repository.close()
    }

    @Test("Unknown and zero sizes stay distinct")
    func unknownVersusZero() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await repository.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(1),
                names: [sampleName(1, "root"), sampleName(2, "unknown"), sampleName(3, "zero")],
                nodes: [
                    sampleNode(id: 1, parent: nil, name: 1, scanID: scanID, kind: .directory, logical: nil, allocated: nil),
                    sampleNode(id: 2, parent: 1, name: 2, scanID: scanID, logical: nil, allocated: nil, attributed: 0),
                    sampleNode(id: 3, parent: 1, name: 3, scanID: scanID, logical: 0, allocated: 0, attributed: 0)
                ]
            )
        )
        let children = try await repository.children(of: NodeID(1), in: scanID)
        let unknown = children.first { $0.id == NodeID(2) }
        let zero = children.first { $0.id == NodeID(3) }
        #expect(unknown?.allocatedBytes == nil)
        #expect(unknown?.logicalBytes == nil)
        #expect(zero?.allocatedBytes == 0)
        #expect(zero?.logicalBytes == 0)
        await repository.close()
    }

    @Test("ancestors returns root to current and detects missing parents and cycles")
    func ancestors() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await writeTree(repository, scanID: scanID)
        let chain = try await repository.ancestors(of: NodeID(4), in: scanID)
        #expect(chain.map(\.id) == [NodeID(1), NodeID(2), NodeID(4)])

        await #expect(throws: SnapshotStoreError.missingParent(NodeID(77))) {
            _ = try await repository.ancestors(of: NodeID(77), in: scanID)
        }

        // A parent pointer cycle is detectable because parent_id has no FK.
        try await repository.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(2),
                names: [sampleName(5, "a"), sampleName(6, "b")],
                nodes: [
                    sampleNode(id: 5, parent: 6, name: 5, scanID: scanID),
                    sampleNode(id: 6, parent: 5, name: 6, scanID: scanID)
                ]
            )
        )
        await #expect(throws: SnapshotStoreError.ancestorCycle(NodeID(5))) {
            _ = try await repository.ancestors(of: NodeID(5), in: scanID)
        }
        await repository.close()
    }

    @Test("Issues aggregate by category, errno and sample")
    func issueSummary() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await repository.record(
            ScanIssue(scanID: scanID, category: .permissionDenied, errnoValue: EACCES, sampleName: NameID(1), count: 2)
        )
        try await repository.record(
            ScanIssue(scanID: scanID, category: .permissionDenied, errnoValue: EACCES, sampleName: NameID(1), count: 3)
        )
        try await repository.record(
            ScanIssue(scanID: scanID, category: .io, errnoValue: nil, sampleName: nil, count: 1)
        )
        let summary = try await repository.issueSummary(scanID)
        #expect(summary.count == 2)
        let permission = summary.first { $0.category == .permissionDenied }
        #expect(permission?.count == 5)
        #expect(permission?.sampleNameID == NameID(1))
        #expect(try await repository.scanState(scanID)?.issueCount == 6)
        let statistics = try await repository.statistics(scanID)
        #expect(statistics.issueCount == 3)
        await repository.close()
    }

    @Test("The children query uses the nodes_by_parent index")
    func queryPlanUsesIndex() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        try await repository.begin(sampleMetadata(scanID: sampleScanID()))
        await repository.close()

        let raw = try SQLiteDatabase.openReadWrite(path: database.path)
        defer { raw.close() }
        let plan = try raw.prepare(
            "EXPLAIN QUERY PLAN SELECT id FROM nodes WHERE scan_id = ? AND parent_id = ? ORDER BY attributed_bytes DESC, id ASC"
        )
        defer { plan.finalize() }
        var details: [String] = []
        while try plan.step() {
            details.append(plan.columnText(3) ?? "")
        }
        #expect(details.contains { $0.contains("nodes_by_parent") }, "plan was \(details)")
    }

    @Test("Committed batches are visible to a separate read-only connection")
    func readerVisibility() async throws {
        let database = try TempDatabase()
        let writer = try database.open()
        let scanID = sampleScanID()
        try await writer.begin(sampleMetadata(scanID: scanID))
        try await writeTree(writer, scanID: scanID)

        let reader = try SQLiteSnapshotRepository.openReadOnly(path: database.path)
        let children = try await reader.children(of: NodeID(1), in: scanID)
        #expect(children.map(\.id) == [NodeID(3), NodeID(2)])
        let state = try await reader.scanState(scanID)
        #expect(state?.status == .running)
        await reader.close()
        await writer.close()
    }

    @Test("An uncommitted transaction is invisible to readers")
    func uncommittedIsolation() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        await repository.close()

        let scanID = sampleScanID()
        let raw = try SQLiteDatabase.openReadWrite(path: database.path)
        try raw.execute("BEGIN IMMEDIATE")
        let insert = try raw.prepare(
            """
            INSERT INTO scans (id, root_display_name, root_node_id, size_metric, boundary_policy,
              package_policy, symlink_policy, started_at, status, last_revision,
              root_attributed_bytes, file_count, directory_count, inaccessible_count,
              issue_count, schema_version)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        )
        defer { insert.finalize() }
        try insert.bindText(1, scanID.rawValue.uuidString)
        try insert.bindText(2, "root")
        try insert.bindBlob(3, UInt64BlobCodec.encode(1))
        for index in Int32(4)...Int32(9) {
            try insert.bindInt64(index, 0)
        }
        try insert.bindBlob(10, UInt64BlobCodec.encode(0))
        for index in Int32(11)...Int32(15) {
            try insert.bindBlob(index, UInt64BlobCodec.encode(0))
        }
        try insert.bindInt64(16, 1)
        _ = try insert.step()

        let reader = try SQLiteSnapshotRepository.openReadOnly(path: database.path)
        #expect(try await reader.scanState(scanID) == nil)
        await reader.close()

        try raw.execute("ROLLBACK")
        raw.close()

        let afterRollback = try SQLiteSnapshotRepository.openReadOnly(path: database.path)
        #expect(try await afterRollback.scanState(scanID) == nil)
        await afterRollback.close()
    }

    @Test("Repeated open/close returns file descriptors to baseline")
    func descriptorCleanup() async throws {
        let database = try TempDatabase()
        // Warm up the schema once.
        let warm = try database.open()
        await warm.close()

        let baseline = countOpenFileDescriptors()
        for _ in 0..<25 {
            let repository = try database.open()
            _ = try await repository.schemaVersion()
            await repository.close()
        }
        let after = countOpenFileDescriptors()
        #expect(after <= baseline + 4, "baseline=\(baseline) after=\(after)")
    }
}
