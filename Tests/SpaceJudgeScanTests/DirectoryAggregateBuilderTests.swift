import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

@Suite("Directory aggregate builder")
struct DirectoryAggregateBuilderTests {
    @Test("Live descendants contribute early without double counting at completion")
    func progressiveConservation() throws {
        var builder = DirectoryAggregateBuilder()
        try builder.registerDirectory(NodeID(2), parent: NodeID(1))
        try builder.registerDirectory(NodeID(3), parent: NodeID(2))
        try builder.addFile(parent: NodeID(1), logical: 10, allocated: 10, attributed: 10)
        try builder.addFile(parent: NodeID(2), logical: 20, allocated: 20, attributed: 20)
        try builder.addFile(parent: NodeID(3), logical: 30, allocated: 30, attributed: 30)
        let live = try builder.progressiveTotals(root: NodeID(1))
        #expect(live[NodeID(1)]?.attributed == 60)
        #expect(live[NodeID(1)]?.fileCount == 3)
        #expect(live[NodeID(1)]?.directoryCount == 2)
        #expect(live[NodeID(2)]?.attributed == 50)
        #expect(try builder.currentTotals(of: NodeID(1)).attributed == 10)
        _ = try builder.complete(NodeID(3), isComplete: true)
        #expect(try builder.progressiveTotals(root: NodeID(1))[NodeID(1)] == live[NodeID(1)])
        builder.retire(NodeID(3))
        #expect(try builder.progressiveTotals(root: NodeID(1))[NodeID(1)] == live[NodeID(1)])
        _ = try builder.complete(NodeID(2), isComplete: true)
        builder.retire(NodeID(2))
        let final = try builder.complete(NodeID(1), isComplete: true)
        #expect(final.attributedBytes == 60)
        #expect(final.descendantDirectoryCount == 2)
    }

    @Test("A very deep live tree uses an iterative traversal")
    func progressiveDeepTree() throws {
        var builder = DirectoryAggregateBuilder()
        for id in 2...10_000 { try builder.registerDirectory(NodeID(UInt64(id)), parent: NodeID(UInt64(id - 1))) }
        try builder.addFile(parent: NodeID(10_000), logical: 100, allocated: 100, attributed: 100)
        let totals = try builder.progressiveTotals(root: NodeID(1))
        #expect(totals[NodeID(1)]?.attributed == 100)
        #expect(totals[NodeID(1)]?.directoryCount == 9_999)
    }
    @Test("Descendant directory counts exclude self but not the whole subtree")
    func descendantCounts() throws {
        var builder = DirectoryAggregateBuilder()

        try builder.registerDirectory(NodeID(2), parent: NodeID(1))
        try builder.registerDirectory(NodeID(3), parent: NodeID(2))
        try builder.addFile(parent: NodeID(1), logical: 10, allocated: 10, attributed: 5)
        try builder.addFile(parent: NodeID(1), logical: 10, allocated: 10, attributed: 7)
        try builder.addFile(parent: NodeID(2), logical: 10, allocated: 10, attributed: 3)
        try builder.addFile(parent: NodeID(3), logical: 10, allocated: 10, attributed: 2)

        let grandchild = try builder.complete(NodeID(3), isComplete: true)
        #expect(grandchild.attributedBytes == 2)
        #expect(grandchild.descendantFileCount == 1)
        #expect(grandchild.descendantDirectoryCount == 0)

        let child = try builder.complete(NodeID(2), isComplete: true)
        #expect(child.attributedBytes == 5)
        #expect(child.descendantFileCount == 2)
        #expect(child.descendantDirectoryCount == 1)

        let root = try builder.complete(NodeID(1), isComplete: true)
        #expect(root.attributedBytes == 17)
        #expect(root.descendantFileCount == 4)
        #expect(root.descendantDirectoryCount == 2)
        #expect(root.isComplete)
    }

    @Test("A failed directory contributes one inaccessible descendant")
    func failedDirectory() throws {
        var builder = DirectoryAggregateBuilder()
        try builder.registerDirectory(NodeID(2), parent: NodeID(1))
        let failed = try builder.complete(NodeID(2), isComplete: false, extraInaccessible: 1)
        #expect(failed.inaccessibleDescendantCount == 1)
        #expect(!failed.isComplete)
        let root = try builder.complete(NodeID(1), isComplete: true)
        #expect(root.inaccessibleDescendantCount == 1)
    }

    @Test("Retiring completed directories does not change parent or root totals")
    func retireKeepsTotals() throws {
        func run(retire: Bool) throws -> (child: DirectoryAggregateRecord, root: DirectoryAggregateRecord) {
            var builder = DirectoryAggregateBuilder()
            try builder.registerDirectory(NodeID(2), parent: NodeID(1))
            try builder.registerDirectory(NodeID(3), parent: NodeID(2))
            try builder.addFile(parent: NodeID(1), logical: 10, allocated: 10, attributed: 1)
            try builder.addFile(parent: NodeID(2), logical: 10, allocated: 10, attributed: 2)
            try builder.addFile(parent: NodeID(3), logical: 10, allocated: 10, attributed: 4)
            let grandchild = try builder.complete(NodeID(3), isComplete: true)
            #expect(grandchild.attributedBytes == 4)
            if retire { builder.retire(NodeID(3)) }
            let child = try builder.complete(NodeID(2), isComplete: true)
            if retire { builder.retire(NodeID(2)) }
            let root = try builder.complete(NodeID(1), isComplete: true)
            return (child, root)
        }

        let withRetire = try run(retire: true)
        let without = try run(retire: false)
        #expect(withRetire.child == without.child)
        #expect(withRetire.root == without.root)
        #expect(withRetire.child.attributedBytes == 6)
        #expect(withRetire.child.descendantFileCount == 2)
        #expect(withRetire.root.attributedBytes == 7)
        #expect(withRetire.root.descendantFileCount == 3)
        #expect(withRetire.root.descendantDirectoryCount == 2)
    }

    @Test("Retire keeps the lightweight completed guard but drops the parent link")
    func retireKeepsCompletedGuard() throws {
        var builder = DirectoryAggregateBuilder()
        try builder.registerDirectory(NodeID(2), parent: NodeID(1))
        _ = try builder.complete(NodeID(2), isComplete: true)
        builder.retire(NodeID(2))
        #expect(builder.isCompleted(NodeID(2)))
        #expect(builder.parent(of: NodeID(2)) == nil)
    }
}
