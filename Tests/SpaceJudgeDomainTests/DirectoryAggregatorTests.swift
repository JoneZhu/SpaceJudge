import Testing
import SpaceJudgeDomain

@Suite("Directory aggregation")
struct DirectoryAggregatorTests {
    @Test("Completed directory equals direct files plus completed children")
    func completionInvariant() throws {
        var aggregator = DirectoryAggregator()

        // root = 10, a = 100 + 200, b = 300
        try aggregator.addDirectFile(Fixtures.record(id: 11, parent: 1, attributedBytes: 10))
        try aggregator.addDirectFile(Fixtures.record(id: 12, parent: 2, attributedBytes: 100))
        try aggregator.addDirectFile(Fixtures.record(id: 13, parent: 2, attributedBytes: 200))
        try aggregator.addDirectFile(Fixtures.record(id: 14, parent: 3, attributedBytes: 300))

        let aTotal = try aggregator.completeDirectory(NodeID(2), parentID: NodeID(1))
        let bTotal = try aggregator.completeDirectory(NodeID(3), parentID: NodeID(1))
        let rootTotal = try aggregator.completeDirectory(NodeID(1), parentID: nil)

        #expect(aTotal == 300)
        #expect(bTotal == 300)
        #expect(rootTotal == 610)
        #expect(aggregator.directBytes(of: NodeID(1)) == 10)
        #expect(aggregator.completedChildBytes(of: NodeID(1)) == 600)
        #expect(try aggregator.attributedBytes(of: NodeID(1)) == 610)
        #expect(aggregator.completedChildCount(of: NodeID(1)) == 2)
    }

    @Test("Arbitrary completion order yields the same final value")
    func orderIndependence() throws {
        func run(interleaved: Bool) throws -> UInt64 {
            var aggregator = DirectoryAggregator()
            let direct: [NodeRecord] = [
                Fixtures.record(id: 11, parent: 1, attributedBytes: 5),
                Fixtures.record(id: 12, parent: 2, attributedBytes: 10),
                Fixtures.record(id: 13, parent: 2, attributedBytes: 20),
                Fixtures.record(id: 14, parent: 3, attributedBytes: 30)
            ]
            if interleaved {
                try aggregator.addDirectFile(direct[0])
                try aggregator.addDirectFile(direct[1])
                try aggregator.addDirectFile(direct[2])
                _ = try aggregator.completeDirectory(NodeID(2), parentID: NodeID(1))
                try aggregator.addDirectFile(direct[3])
                _ = try aggregator.completeDirectory(NodeID(3), parentID: NodeID(1))
                return try aggregator.completeDirectory(NodeID(1), parentID: nil)
            } else {
                for record in direct { try aggregator.addDirectFile(record) }
                _ = try aggregator.completeDirectory(NodeID(3), parentID: NodeID(1))
                _ = try aggregator.completeDirectory(NodeID(2), parentID: NodeID(1))
                return try aggregator.completeDirectory(NodeID(1), parentID: nil)
            }
        }

        let interleavedTotal = try run(interleaved: true)
        let sequentialTotal = try run(interleaved: false)
        #expect(interleavedTotal == 65)
        #expect(sequentialTotal == 65)
        #expect(interleavedTotal == sequentialTotal)
    }

    @Test("Directory with no direct files aggregates only children")
    func childrenOnly() throws {
        var aggregator = DirectoryAggregator()
        try aggregator.addDirectFile(Fixtures.record(id: 11, parent: 2, attributedBytes: 7))
        let child = try aggregator.completeDirectory(NodeID(2), parentID: NodeID(1))
        let root = try aggregator.completeDirectory(NodeID(1), parentID: nil)
        #expect(child == 7)
        #expect(root == 7)
    }

    @Test("Overflow surfaces as an explicit error")
    func overflow() throws {
        var aggregator = DirectoryAggregator()
        try aggregator.addDirectFile(Fixtures.record(id: 11, parent: 1, attributedBytes: UInt64.max))
        #expect(throws: ByteAggregationError.self) {
            try aggregator.addDirectFile(Fixtures.record(id: 12, parent: 1, attributedBytes: 1))
        }
    }

    @Test("A rootless file record is rejected")
    func missingParent() {
        var aggregator = DirectoryAggregator()
        #expect(throws: ByteAggregationError.missingParent(nodeID: NodeID(5))) {
            try aggregator.addDirectFile(Fixtures.record(id: 5, parent: nil, attributedBytes: 1))
        }
    }

    @Test("Completing the same directory twice is rejected")
    func duplicateCompletion() throws {
        var aggregator = DirectoryAggregator()
        _ = try aggregator.completeDirectory(NodeID(2), parentID: NodeID(1))
        #expect(aggregator.isCompleted(NodeID(2)))
        #expect(throws: ByteAggregationError.duplicateCompletion(nodeID: NodeID(2))) {
            _ = try aggregator.completeDirectory(NodeID(2), parentID: NodeID(1))
        }
    }

    @Test("Adding direct bytes after completion is rejected")
    func addAfterCompletion() throws {
        var aggregator = DirectoryAggregator()
        _ = try aggregator.completeDirectory(NodeID(2), parentID: NodeID(1))
        #expect(throws: ByteAggregationError.directoryAlreadyCompleted(nodeID: NodeID(2))) {
            try aggregator.addDirectBytes(1, to: NodeID(2))
        }
    }

    @Test("Completing a child into a completed parent is rejected")
    func childAfterParentCompletion() throws {
        var aggregator = DirectoryAggregator()
        _ = try aggregator.completeDirectory(NodeID(1), parentID: nil)
        #expect(throws: ByteAggregationError.directoryAlreadyCompleted(nodeID: NodeID(1))) {
            _ = try aggregator.completeDirectory(NodeID(2), parentID: NodeID(1))
        }
    }

    @Test("Querying an unrepresentable total throws instead of clamping")
    func queryOverflow() throws {
        var aggregator = DirectoryAggregator()
        try aggregator.addDirectBytes(UInt64.max, to: NodeID(1))
        try aggregator.addDirectBytes(UInt64.max, to: NodeID(2))
        _ = try aggregator.completeDirectory(NodeID(2), parentID: NodeID(1))
        #expect(throws: ByteAggregationError.self) {
            _ = try aggregator.attributedBytes(of: NodeID(1))
        }
    }
}
