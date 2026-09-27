import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeAppSupport

@Suite("Runtime path resolver")
struct RuntimePathResolverTests {
    private let rootNode = NodeID(1)

    private func node(_ id: UInt64, parent: UInt64?, name: UInt64) -> NodeRecord {
        NodeRecord(
            id: NodeID(id),
            scanID: ScanID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!),
            parentID: parent.map(NodeID.init),
            name: NameID(name),
            kind: .directory,
            logicalBytes: nil,
            allocatedBytes: nil,
            attributedBytes: 0
        )
    }

    private func record(_ id: UInt64, _ bytes: [UInt8]) -> NameRecord {
        NameRecord(id: NameID(id), bytes: bytes)
    }

    @Test("A valid chain resolves inside the root")
    func validChain() throws {
        let resolver = RuntimePathResolver(rootPath: "/tmp/root", rootNodeID: rootNode)
        let nodes = [node(1, parent: nil, name: 1), node(2, parent: 1, name: 2), node(3, parent: 2, name: 3)]
        let names = [record(1, Array("root".utf8)), record(2, Array("a".utf8)), record(3, Array("b".utf8))]
        let url = try resolver.url(ancestorNodes: nodes, names: names)
        #expect(url.path == "/tmp/root/a/b")
    }

    @Test("The root's own name is never appended twice")
    func rootNameNotDuplicated() throws {
        let resolver = RuntimePathResolver(rootPath: "/tmp/root", rootNodeID: rootNode)
        let nodes = [node(1, parent: nil, name: 1)]
        let names = [record(1, Array("root".utf8))]
        let url = try resolver.url(ancestorNodes: nodes, names: names)
        #expect(url.path == "/tmp/root")
    }

    @Test("Root mismatch, empty chain and empty root are rejected")
    func structuralErrors() {
        let resolver = RuntimePathResolver(rootPath: "/tmp/root", rootNodeID: rootNode)
        #expect(throws: RuntimePathResolverError.self) {
            _ = try resolver.url(
                ancestorNodes: [node(9, parent: nil, name: 9)],
                names: [record(9, Array("x".utf8))]
            )
        }
        #expect(throws: RuntimePathResolverError.self) {
            _ = try resolver.url(ancestorNodes: [], names: [])
        }
        let empty = RuntimePathResolver(rootPath: "", rootNodeID: rootNode)
        #expect(throws: RuntimePathResolverError.self) {
            _ = try empty.url(
                ancestorNodes: [node(1, parent: nil, name: 1)],
                names: [record(1, Array("x".utf8))]
            )
        }
    }

    @Test("Invalid components are rejected")
    func invalidComponents() {
        let resolver = RuntimePathResolver(rootPath: "/tmp/root", rootNodeID: rootNode)
        let nodes = [node(1, parent: nil, name: 1), node(2, parent: 1, name: 2)]
        let bad: [[UInt8]] = [
            [],
            Array(".".utf8),
            Array("..".utf8),
            Array("a/b".utf8),
            [0x00],
            [0xFF, 0xFE]
        ]
        for bytes in bad {
            #expect(throws: RuntimePathResolverError.self) {
                _ = try resolver.url(
                    ancestorNodes: nodes,
                    names: [record(1, Array("root".utf8)), record(2, bytes)]
                )
            }
        }
    }

    @Test("Unicode components resolve correctly")
    func unicodeComponent() throws {
        let resolver = RuntimePathResolver(rootPath: "/tmp/root", rootNodeID: rootNode)
        let nodes = [node(1, parent: nil, name: 1), node(2, parent: 1, name: 2)]
        let names = [record(1, Array("root".utf8)), record(2, Array("文档 é".utf8))]
        let url = try resolver.url(ancestorNodes: nodes, names: names)
        #expect(url.path == "/tmp/root/文档 é")
    }

    @Test("A crafted escape chain cannot leave the root")
    func outsideRoot() {
        let resolver = RuntimePathResolver(rootPath: "/tmp/root", rootNodeID: rootNode)
        // ".." is rejected before standardization.
        let nodes = [node(1, parent: nil, name: 1), node(2, parent: 1, name: 2)]
        #expect(throws: RuntimePathResolverError.self) {
            _ = try resolver.url(
                ancestorNodes: nodes,
                names: [record(1, Array("root".utf8)), record(2, Array("..".utf8))]
            )
        }
    }
}
