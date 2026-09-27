import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeStore

@Suite("Bounded snapshot child pages", .serialized)
struct SnapshotChildPageTests {
    private func metadata(_ scanID: ScanID, displayName: String = "root") -> ScanMetadata {
        sampleMetadata(scanID: scanID, displayName: displayName)
    }

    private func seed(
        _ repository: SQLiteSnapshotRepository,
        scanID: ScanID,
        childCount: Int
    ) async throws {
        try await repository.begin(metadata(scanID))
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
                    id: UInt64(index + 2),
                    parent: 1,
                    name: nameID,
                    scanID: scanID,
                    attributed: UInt64((index % 5) * 100)
                )
            )
        }
        try await repository.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(1),
                names: names,
                nodes: nodes
            )
        )
    }

    @Test("childPage respects the limit and returns the direct-child total")
    func limitAndTotal() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await seed(repository, scanID: scanID, childCount: 12)

        let page = try await repository.childPage(of: NodeID(1), in: scanID, limit: 5)
        #expect(page.items.count == 5)
        #expect(page.totalCount == 12)

        let full = try await repository.childPage(of: NodeID(1), in: scanID, limit: 500)
        #expect(full.items.count == 12)
        #expect(full.totalCount == 12)
        await repository.close()
    }

    @Test("childPage orders by attributed bytes descending then NodeID ascending")
    func ordering() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await seed(repository, scanID: scanID, childCount: 12)

        let page = try await repository.childPage(of: NodeID(1), in: scanID, limit: 500)
        let attributed = page.items.map(\.effectiveAttributedBytes)
        #expect(attributed == attributed.sorted(by: >))

        // Ties keep NodeID ascending.
        let high = page.items.filter { $0.effectiveAttributedBytes == 400 }.map(\.node.id.rawValue)
        #expect(high == high.sorted())
        await repository.close()
    }

    @Test("childPage joins scan-local names, preserves invalid UTF-8, and keeps one scan")
    func scanLocalNamesAndInvalidUTF8() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanA = sampleScanID(1)
        let scanB = sampleScanID(2)
        let rawA = Data([0xFF, 0xFE, 0x41])
        let rawB = Data(Array("bravo".utf8))

        func write(_ scanID: ScanID, raw: Data) async throws {
            try await repository.begin(metadata(scanID, displayName: "scan"))
            try await repository.write(
                NodeBatch(
                    scanID: scanID,
                    revision: Revision(1),
                    names: [
                        sampleName(1, "root"),
                        NameRecord(id: NameID(7), utf8: raw)
                    ],
                    nodes: [
                        sampleNode(
                            id: 1, parent: nil, name: 1, scanID: scanID,
                            kind: .directory, logical: nil, allocated: nil, attributed: 0
                        ),
                        sampleNode(id: 2, parent: 1, name: 7, scanID: scanID, attributed: 42)
                    ]
                )
            )
        }

        try await write(scanA, raw: rawA)
        let pageA = try await repository.childPage(of: NodeID(1), in: scanA, limit: 10)
        #expect(pageA.items.first?.name.utf8 == rawA)
        #expect(pageA.items.first?.name.decodedString == nil)

        // The next begin replaces the previous scan; the old snapshot is gone.
        try await write(scanB, raw: rawB)
        #expect(try await repository.scanState(scanA) == nil)
        let stalePage = try await repository.childPage(of: NodeID(1), in: scanA, limit: 10)
        #expect(stalePage.items.isEmpty)

        let pageB = try await repository.childPage(of: NodeID(1), in: scanB, limit: 10)
        #expect(pageB.items.first?.name.utf8 == rawB)
        #expect(pageB.items.first?.name.decodedString == "bravo")
        await repository.close()
    }

    @Test("childPage rejects limits outside 1...500")
    func invalidLimits() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await seed(repository, scanID: scanID, childCount: 1)

        await #expect(throws: SnapshotQueryError.invalidChildPageLimit(0)) {
            _ = try await repository.childPage(of: NodeID(1), in: scanID, limit: 0)
        }
        await #expect(throws: SnapshotQueryError.invalidChildPageLimit(501)) {
            _ = try await repository.childPage(of: NodeID(1), in: scanID, limit: 501)
        }
        await #expect(throws: SnapshotQueryError.invalidChildPageLimit(-3)) {
            _ = try await repository.childPage(of: NodeID(1), in: scanID, limit: -3)
        }
        await repository.close()
    }

    @Test("Directory children rank by aggregate weight without changing the node")
    func directoryAggregateWeight() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(metadata(scanID))

        let names = [
            sampleName(1, "root"),
            sampleName(2, "Developer"),
            sampleName(3, "Downloads"),
            sampleName(4, "Photos"),
            sampleName(5, "plain.bin"),
            sampleName(6, "empty-dir")
        ]
        // Directory nodes own no bytes directly: attributed 0. Their subtree
        // weight lives only in directory_aggregates.
        let nodes = [
            sampleNode(id: 1, parent: nil, name: 1, scanID: scanID, kind: .directory, logical: nil, allocated: nil, attributed: 0),
            sampleNode(id: 2, parent: 1, name: 2, scanID: scanID, kind: .directory, logical: nil, allocated: nil, attributed: 0),
            sampleNode(id: 3, parent: 1, name: 3, scanID: scanID, kind: .directory, logical: nil, allocated: nil, attributed: 0),
            sampleNode(id: 4, parent: 1, name: 4, scanID: scanID, kind: .directory, logical: nil, allocated: nil, attributed: 0),
            sampleNode(id: 5, parent: 1, name: 5, scanID: scanID, kind: .regularFile, attributed: 0x400000),
            sampleNode(id: 6, parent: 1, name: 6, scanID: scanID, kind: .directory, logical: nil, allocated: nil, attributed: 0)
        ]
        func aggregate(_ id: UInt64, _ bytes: UInt64, complete: Bool = true) -> DirectoryAggregateRecord {
            DirectoryAggregateRecord(
                nodeID: NodeID(id), logicalBytes: bytes, allocatedBytes: bytes,
                attributedBytes: bytes, descendantFileCount: 1, descendantDirectoryCount: 0,
                inaccessibleDescendantCount: 0, isComplete: complete
            )
        }
        let aggregates = [
            aggregate(2, 0x300000), // Developer: 3 MiB
            aggregate(3, 0x200000, complete: false), // Downloads: partial 2 MiB
            aggregate(4, 0x100000) // Photos: 1 MiB
            // id 6 has no aggregate: null node weight, no aggregate row.
        ]
        try await repository.write(
            NodeBatch(
                scanID: scanID, revision: Revision(1), names: names, nodes: nodes,
                directoryAggregates: aggregates
            )
        )

        let page = try await repository.childPage(of: NodeID(1), in: scanID, limit: 100)
        #expect(page.totalCount == 5)
        #expect(page.items.map(\.node.id.rawValue) == [5, 2, 3, 4, 6])
        #expect(page.items.map(\.effectiveAttributedBytes) == [0x400000, 0x300000, 0x200000, 0x100000, 0])
        // The immutable node weight is untouched for directories.
        for item in page.items where item.node.kind.isDirectoryLike {
            #expect(item.node.attributedBytes == 0)
        }
        #expect(page.items[0].node.attributedBytes == 0x400000)
        await repository.close()
    }

    @Test("childPage query uses the nodes_by_parent index")
    func queryPlan() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await seed(repository, scanID: scanID, childCount: 3)
        await repository.close()

        let raw = try SQLiteDatabase.openReadOnly(path: database.path)
        let statement = try raw.prepare(
            """
            EXPLAIN QUERY PLAN
            SELECT n.id, m.utf8,
                   COALESCE(a.attributed_bytes, n.attributed_bytes) AS effective
            FROM nodes AS n INDEXED BY nodes_by_parent
            JOIN names AS m ON m.scan_id = n.scan_id AND m.id = n.name_id
            LEFT JOIN directory_aggregates AS a
                   ON a.scan_id = n.scan_id AND a.node_id = n.id
            WHERE n.scan_id = ? AND n.parent_id = ?
            ORDER BY effective DESC, n.id ASC
            LIMIT ?
            """
        )
        var plan: [String] = []
        while try statement.step() {
            if let text = statement.columnText(3) { plan.append(text) }
        }
        statement.finalize()
        raw.close()

        let joined = plan.joined(separator: "\n")
        #expect(joined.contains("nodes_by_parent"), "plan was:\n\(joined)")
    }

    @Test("childPage works through the read-only UI connection")
    func readOnlyChildPage() async throws {
        let database = try TempDatabase()
        let writer = try database.open()
        let scanID = sampleScanID()
        try await seed(writer, scanID: scanID, childCount: 4)
        await writer.close()

        let reader = try SQLiteSnapshotRepository.openReadOnly(path: database.path)
        let page = try await reader.childPage(of: NodeID(1), in: scanID, limit: 100)
        #expect(page.items.count == 4)
        #expect(page.totalCount == 4)
        await reader.close()
    }

    @Test("Volume facts survive a close and read-only reopen")
    func volumeSurvivesReopen() async throws {
        let database = try TempDatabase()
        let volume = VolumeFacts(
            totalCapacityBytes: 512_000_000_000,
            availableCapacityBytes: 99_400_000_000,
            capacitySource: .importantUsage
        )
        let scanID = sampleScanID()
        let writer = try database.open()
        try await writer.begin(sampleMetadata(scanID: scanID, volume: volume))
        try await writer.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(1),
                names: [sampleName(1, "root")],
                nodes: [
                    sampleNode(
                        id: 1, parent: nil, name: 1, scanID: scanID,
                        kind: .directory, logical: nil, allocated: nil, attributed: 0
                    )
                ]
            )
        )
        try await writer.finish(
            ScanSummary(
                scanID: scanID,
                status: .completed,
                startedAt: Date(timeIntervalSince1970: 1_000),
                finishedAt: Date(timeIntervalSince1970: 2_000),
                fileCount: 0,
                directoryCount: 1,
                inaccessibleCount: 0,
                issueCount: 0,
                rootAttributedBytes: 0,
                volume: volume
            )
        )
        await writer.close()

        let reader = try SQLiteSnapshotRepository.openReadOnly(path: database.path)
        let summary = try await reader.scanSummary(scanID)
        #expect(summary?.volume == volume)
        #expect(summary?.volume?.capacitySource == .importantUsage)
        await reader.close()
    }
}
