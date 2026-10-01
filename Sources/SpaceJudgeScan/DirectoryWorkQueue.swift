import Foundation

/// Bounded in-memory FIFO for directory work items.
///
/// The previous implementation used `[DirectoryWorkItem]` plus a head index.
/// Popping only advanced the index, so every consumed item — including its
/// `pathBytes` and any pre-opened descriptor — stayed strongly referenced in
/// the backing array until the whole queue drained. On a wide and deep mixed
/// tree that retained path storage grew with the number of directories already
/// processed, which is what the million-node heap profile showed.
///
/// This ring clears each storage slot on `pop`, so a consumed item is released
/// immediately. Capacity grows on demand but never past `capacityLimit`;
/// callers spill to the directory spool when the queue is full, so the ring can
/// never overflow. FIFO order is preserved exactly, and the pre-existing
/// `activeQueuedCount` / `queueHighWater` / cancel and descriptor lifecycle
/// semantics are unchanged.
struct DirectoryWorkQueue {
    /// Hard upper bound on the number of queued items. Equal to the configured
    /// `maximumQueuedDirectories`; callers spool before reaching it.
    let capacityLimit: Int

    private var storage: [DirectoryWorkItem?] = []
    private var head = 0
    private(set) var count = 0

    init(capacityLimit: Int) {
        self.capacityLimit = max(1, capacityLimit)
    }

    var isEmpty: Bool { count == 0 }

    /// Appends one item. The caller must have checked `count < capacityLimit`.
    mutating func push(_ item: DirectoryWorkItem) {
        if count == storage.count {
            grow()
        }
        let index = (head + count) % storage.count
        storage[index] = item
        count += 1
    }

    /// Removes and returns the oldest item, releasing its storage slot.
    mutating func pop() -> DirectoryWorkItem? {
        guard count > 0 else { return nil }
        let item = storage[head]
        storage[head] = nil
        head += 1
        if head == storage.count { head = 0 }
        count -= 1
        return item
    }

    /// Releases every slot without closing descriptors. Used on the terminal
    /// cleanup path where descriptors are already closed by their owners.
    mutating func removeAll() {
        for index in 0..<storage.count { storage[index] = nil }
        head = 0
        count = 0
    }

    /// Closes every queued pre-opened descriptor and releases all storage.
    mutating func closeAll() {
        for index in 0..<storage.count {
            storage[index]?.preopened?.close()
        }
        storage.removeAll(keepingCapacity: false)
        head = 0
        count = 0
    }

    /// Test hook: storage slots that still reference an item. Must equal
    /// `count`; a larger value would mean consumed items are retained.
    var debugOccupiedSlotCount: Int {
        storage.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
    }

    /// Test hook: current backing storage capacity.
    var debugStorageCapacity: Int { storage.count }

    private mutating func grow() {
        let desired = max(count + 1, storage.isEmpty ? 4 : storage.count * 2)
        let newCapacity = min(capacityLimit, max(1, desired))
        var newStorage = [DirectoryWorkItem?](repeating: nil, count: newCapacity)
        for offset in 0..<count {
            newStorage[offset] = storage[(head + offset) % storage.count]
        }
        storage = newStorage
        head = 0
    }
}
