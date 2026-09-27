import Testing
import SpaceJudgeDomain

@Suite("Byte aggregation")
struct ByteAggregationTests {
    @Test("Safe add returns exact sum")
    func safeAdd() throws {
        #expect(try SafeByteAggregation.add(2, 3) == 5)
        #expect(try SafeByteAggregation.add(0, 0) == 0)
    }

    @Test("Safe add reports overflow with node context")
    func safeAddOverflow() {
        #expect(throws: ByteAggregationError.overflow(nodeID: NodeID(9), context: "unit")) {
            try SafeByteAggregation.add(UInt64.max, 1, nodeID: NodeID(9), context: "unit")
        }
    }

    @Test("Safe sum detects overflow mid-sequence")
    func safeSumOverflow() throws {
        #expect(throws: ByteAggregationError.self) {
            try SafeByteAggregation.sum([UInt64.max, 1, 0])
        }
        #expect(try SafeByteAggregation.sum([1, 2, 3]) == 6)
    }

    @Test("Hard link attributor counts first occurrence only")
    func hardLinkAttributor() {
        let identity = FileIdentity(deviceID: 1, fileID: 2)
        var attributor = HardLinkAttributor()

        #expect(attributor.claim(identity) == .first)
        #expect(attributor.claim(identity) == .duplicate)
        #expect(attributor.claim(FileIdentity(deviceID: 1, fileID: 3)) == .first)
        #expect(attributor.claimedCount == 2)
        #expect(attributor.hasSeen(identity))
    }

    @Test("Attribute applies zero to duplicate hard links")
    func attributeHardLinks() {
        let identity = FileIdentity(deviceID: 1, fileID: 2)
        var attributor = HardLinkAttributor()

        #expect(attributor.attribute(identity: identity, allocatedBytes: 4096) == 4096)
        #expect(attributor.attribute(identity: identity, allocatedBytes: 4096) == 0)
        #expect(attributor.attribute(identity: nil, allocatedBytes: 512) == 512)
        #expect(attributor.attribute(identity: nil, allocatedBytes: 512) == 512)
    }

    @Test("Unknown bytes stay distinct from a real zero")
    func unknownVersusZero() {
        let unknown = Fixtures.record(id: 1, parent: 0, allocatedBytes: nil, attributedBytes: 0)
        let zero = Fixtures.record(id: 2, parent: 0, allocatedBytes: 0, attributedBytes: 0)

        #expect(unknown.allocatedBytes == nil)
        #expect(zero.allocatedBytes == 0)
        #expect(unknown.allocatedBytes != zero.allocatedBytes)
        #expect(unknown.allocatedBytes != 0)
    }
}
