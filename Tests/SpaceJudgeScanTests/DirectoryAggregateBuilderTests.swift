import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

@Suite("Directory aggregate builder")
struct DirectoryAggregateBuilderTests {
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
}
