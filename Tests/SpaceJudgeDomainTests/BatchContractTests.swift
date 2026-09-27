import Foundation
import Testing
import SpaceJudgeDomain

@Suite("Phase 1 batch contract")
struct BatchContractTests {
    @Test("NameRecord preserves raw bytes and decodes strict UTF-8")
    func nameRecord() {
        let valid = NameRecord(id: NameID(1), bytes: Array("文件".utf8))
        #expect(valid.bytes == Array("文件".utf8))
        #expect(valid.decodedString == "文件")

        let invalid = NameRecord(id: NameID(2), utf8: Data([0xFF, 0xFE]))
        #expect(invalid.decodedString == nil)
        #expect(invalid.bytes == [0xFF, 0xFE])
    }

    @Test("DirectoryAggregateRecord round-trips and compares by value")
    func directoryAggregate() throws {
        let record = DirectoryAggregateRecord(
            nodeID: NodeID(3),
            logicalBytes: 10,
            allocatedBytes: 8,
            attributedBytes: 8,
            descendantFileCount: 2,
            descendantDirectoryCount: 1,
            inaccessibleDescendantCount: 0,
            isComplete: true
        )
        let copy = record
        #expect(record == copy)

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(DirectoryAggregateRecord.self, from: data)
        #expect(decoded == record)
    }

    @Test("NodeBatch defaults names and aggregates to empty arrays")
    func nodeBatchDefaults() {
        let batch = NodeBatch(
            scanID: Fixtures.scanID(),
            revision: Revision(1),
            nodes: [Fixtures.record(id: 1, parent: 0, attributedBytes: 5)]
        )
        #expect(batch.names.isEmpty)
        #expect(batch.directoryAggregates.isEmpty)

        let full = NodeBatch(
            scanID: Fixtures.scanID(),
            revision: Revision(2),
            names: [NameRecord(id: NameID(1), bytes: [0x61])],
            nodes: [],
            directoryAggregates: [
                DirectoryAggregateRecord(
                    nodeID: NodeID(1),
                    logicalBytes: 0,
                    allocatedBytes: 0,
                    attributedBytes: 0,
                    descendantFileCount: 0,
                    descendantDirectoryCount: 0,
                    inaccessibleDescendantCount: 0,
                    isComplete: true
                )
            ]
        )
        #expect(full.names.count == 1)
        #expect(full.directoryAggregates.count == 1)
    }
}
