import Foundation
import Testing
import SpaceJudgeDomain

@Suite("Snapshot child page contract")
struct SnapshotChildPageContractTests {
    private func item(_ id: UInt64, _ name: String, _ bytes: UInt64) -> SnapshotChildItem {
        SnapshotChildItem(
            node: NodeRecord(
                id: NodeID(id),
                scanID: ScanID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!),
                parentID: NodeID(1),
                name: NameID(id),
                kind: .directory,
                logicalBytes: nil,
                allocatedBytes: nil,
                attributedBytes: 0
            ),
            name: NameRecord(id: NameID(id), bytes: Array(name.utf8)),
            effectiveAttributedBytes: bytes
        )
    }

    private func aggregate(_ id: UInt64, _ bytes: UInt64, complete: Bool = true) -> DirectoryAggregateRecord {
        DirectoryAggregateRecord(
            nodeID: NodeID(id),
            logicalBytes: bytes,
            allocatedBytes: bytes,
            attributedBytes: bytes,
            descendantFileCount: 1,
            descendantDirectoryCount: 0,
            inaccessibleDescendantCount: 0,
            isComplete: complete
        )
    }

    @Test("Revision and parent aggregate round-trip through Codable")
    func codableRoundTrip() throws {
        let page = SnapshotChildPage(
            items: [item(2, "a", 100), item(3, "b", 50)],
            totalCount: 9,
            snapshotRevision: Revision(7),
            parentAggregate: aggregate(1, 1_000, complete: false)
        )
        let data = try JSONEncoder().encode(page)
        let decoded = try JSONDecoder().decode(SnapshotChildPage.self, from: data)
        #expect(decoded == page)
        #expect(decoded.snapshotRevision == Revision(7))
        #expect(decoded.parentAggregate?.isComplete == false)
    }

    @Test("The legacy initializer stays source compatible with defaults")
    func legacyInitializer() {
        let page = SnapshotChildPage(items: [item(2, "a", 100)], totalCount: 1)
        #expect(page.snapshotRevision == Revision(0))
        #expect(page.parentAggregate == nil)
    }

    @Test("effectiveAttributedBytes falls back to the node value")
    func effectiveFallback() {
        let explicit = SnapshotChildItem(
            node: NodeRecord(
                id: NodeID(2),
                scanID: ScanID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!),
                parentID: NodeID(1),
                name: NameID(2),
                kind: .regularFile,
                logicalBytes: 10,
                allocatedBytes: 10,
                attributedBytes: 10
            ),
            name: NameRecord(id: NameID(2), bytes: Array("f".utf8))
        )
        #expect(explicit.effectiveAttributedBytes == 10)
    }
}
