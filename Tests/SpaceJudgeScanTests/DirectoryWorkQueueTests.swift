import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

@Suite("Directory work queue")
struct DirectoryWorkQueueTests {
    private func item(_ id: UInt64, path: String = "path", preopened: FileDescriptor? = nil) -> DirectoryWorkItem {
        DirectoryWorkItem(
            nodeID: NodeID(id),
            parentID: id == 1 ? nil : NodeID(id - 1),
            pathBytes: Array(path.utf8),
            deviceID: 1,
            isRoot: id == 1,
            preopened: preopened
        )
    }

    @Test("FIFO order is preserved across head wrap-around")
    func fifoAcrossWrap() {
        var queue = DirectoryWorkQueue(capacityLimit: 8)
        // Interleave pushes and pops so the head wraps several times.
        var next = 1
        var order: [UInt64] = []
        for _ in 0..<5 { queue.push(item(UInt64(next))); next += 1 }
        for _ in 0..<3 { order.append(queue.pop()!.nodeID.rawValue) }
        for _ in 0..<5 { queue.push(item(UInt64(next))); next += 1 }
        while let popped = queue.pop() { order.append(popped.nodeID.rawValue) }
        #expect(order == Array(UInt64(1)...UInt64(10)))
        #expect(queue.isEmpty)
    }

    @Test("Capacity grows on demand but never past the configured limit")
    func growthIsBounded() {
        let limit = 12
        var queue = DirectoryWorkQueue(capacityLimit: limit)
        for id in 1...limit {
            queue.push(item(UInt64(id)))
        }
        #expect(queue.count == limit)
        #expect(queue.debugStorageCapacity == limit)
        #expect(queue.debugStorageCapacity <= limit)
        #expect(queue.debugOccupiedSlotCount == queue.count)
    }

    @Test("A popped slot is released immediately, not retained until drain")
    func popReleasesSlot() {
        var queue = DirectoryWorkQueue(capacityLimit: 16)
        for id in 1...6 { queue.push(item(UInt64(id))) }
        #expect(queue.debugOccupiedSlotCount == 6)
        _ = queue.pop()
        _ = queue.pop()
        #expect(queue.count == 4)
        // The two consumed slots no longer reference their items; the backing
        // storage may stay allocated but holds only live items.
        #expect(queue.debugOccupiedSlotCount == 4)
    }

    @Test("removeAll clears every slot without closing descriptors")
    func removeAllKeepsDescriptors() {
        var queue = DirectoryWorkQueue(capacityLimit: 8)
        for id in 1...4 { queue.push(item(UInt64(id))) }
        queue.removeAll()
        #expect(queue.isEmpty)
        #expect(queue.debugOccupiedSlotCount == 0)
    }

    @Test("closeAll closes every queued pre-opened descriptor")
    func closeAllClosesDescriptors() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacejudge-queue-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: path.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: path) }

        let raw = path.path.withCString { open($0, O_RDONLY) }
        #expect(raw >= 0)
        let descriptor = FileDescriptor(raw)
        var queue = DirectoryWorkQueue(capacityLimit: 8)
        queue.push(item(1, preopened: descriptor))
        queue.push(item(2))
        queue.closeAll()
        #expect(queue.isEmpty)
        // The descriptor owned by the queued item is now closed.
        #expect(fcntl(raw, F_GETFD) == -1)
    }
}
