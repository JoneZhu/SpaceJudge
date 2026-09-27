import Foundation
import Testing
import SpaceJudgeDomain

@Suite("Identifiers")
struct IdentifierTests {
    @Test("NodeID ordering follows raw value")
    func nodeIDOrdering() {
        #expect(NodeID(1) < NodeID(2))
        #expect(NodeID(2) > NodeID(1))
        #expect(NodeID(5) == NodeID(5))
        #expect(NodeID(5) != NodeID(6))
    }

    @Test("Revision advances monotonically")
    func revisionAdvance() {
        let revision = Revision(41)
        #expect(revision.next == Revision(42))
        #expect(Revision(1) < Revision(2))
    }

    @Test("ScanID round-trips through Codable")
    func scanIDCodable() throws {
        let scanID = Fixtures.scanID(7)
        let data = try JSONEncoder().encode(scanID)
        let decoded = try JSONDecoder().decode(ScanID.self, from: data)
        #expect(decoded == scanID)
    }

    @Test("FileIdentity distinguishes device and inode")
    func fileIdentity() {
        let identity = FileIdentity(deviceID: 1, fileID: 99)
        #expect(identity == FileIdentity(deviceID: 1, fileID: 99))
        #expect(identity != FileIdentity(deviceID: 2, fileID: 99))
        #expect(identity != FileIdentity(deviceID: 1, fileID: 100))
    }

    @Test("NodeRecord exposes file identity only when both parts exist")
    func recordFileIdentity() {
        let complete = Fixtures.record(id: 1, parent: 0, attributedBytes: 10, deviceID: 7, fileID: 8)
        #expect(complete.fileIdentity == FileIdentity(deviceID: 7, fileID: 8))

        let partial = Fixtures.record(id: 2, parent: 0, attributedBytes: 10, deviceID: 7)
        #expect(partial.fileIdentity == nil)
    }

    @Test("NameID and NodeID are distinct types with the same value")
    func nameID() {
        #expect(NameID(3) == NameID(3))
        #expect(NameID(3) < NameID(4))
    }
}
