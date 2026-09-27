import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

@Suite("Directory spool")
struct DirectorySpoolTests {
    private func item(_ id: UInt64, path: String) -> DirectoryWorkItem {
        DirectoryWorkItem(
            nodeID: NodeID(id),
            parentID: NodeID(1),
            pathBytes: Array(path.utf8),
            deviceID: 7,
            isRoot: false,
            preopened: nil
        )
    }

    @Test("Round-trips work items through the spool")
    func roundTrip() throws {
        let spool = DirectorySpool()
        try spool.append(item(2, path: "/tmp/a"))
        try spool.append(item(3, path: "/tmp/b"))
        #expect(spool.count == 2)

        let first = try #require(try spool.pop())
        #expect(first.nodeID == NodeID(2))
        #expect(first.parentID == NodeID(1))
        #expect(first.deviceID == 7)
        #expect(first.pathBytes == Array("/tmp/a".utf8))
        #expect(first.preopened == nil)
        #expect(!first.enteredThroughFirmlink)

        let second = try #require(try spool.pop())
        #expect(second.nodeID == NodeID(3))
        #expect(try spool.pop() == nil)
        spool.dispose()
    }

    @Test("Preserves the firmlink authorization through the spool")
    func firmlinkFlagRoundTrip() throws {
        let spool = DirectorySpool()
        try spool.append(
            DirectoryWorkItem(
                nodeID: NodeID(2),
                parentID: NodeID(1),
                pathBytes: Array("/tmp/projected".utf8),
                deviceID: 7,
                isRoot: false,
                enteredThroughFirmlink: true,
                preopened: nil
            )
        )
        let restored = try #require(try spool.pop())
        #expect(restored.enteredThroughFirmlink)
        #expect(restored.deviceID == 7)
        spool.dispose()
    }

    @Test("Refuses to spool a work item with a descriptor")
    func preopenedRefused() throws {
        let spool = DirectorySpool()
        let descriptorItem = DirectoryWorkItem(
            nodeID: NodeID(2),
            parentID: nil,
            pathBytes: [UInt8(ascii: "/")],
            deviceID: nil,
            isRoot: false,
            preopened: FileDescriptor(-1)
        )
        #expect(throws: ScanError.self) {
            try spool.append(descriptorItem)
        }
        spool.dispose()
    }

    @Test("A truncated spool file surfaces an explicit error")
    func truncatedReadFails() throws {
        let spool = DirectorySpool()
        try spool.append(item(2, path: "/tmp/a"))
        guard let url = spool.debugFileURL else {
            Issue.record("spool did not create a backing file")
            return
        }
        _ = url.path.withCString { truncate($0, 0) }
        #expect(throws: ScanError.self) {
            _ = try spool.pop()
        }
        spool.dispose()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
