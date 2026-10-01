import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeUseCases

/// Cursor for the directory-publication tests.
private final class PublicationCursor: DirectoryCursor {
    enum Step {
        case entries([RawDirectoryEntry])
        case failure(Int32)
    }

    private var step: Step?

    init(_ step: Step) {
        self.step = step
    }

    func nextPage() throws -> DirectoryEntryPage {
        if let step {
            self.step = nil
            switch step {
            case .entries(let entries):
                return DirectoryEntryPage(entries: entries, isLast: true)
            case .failure(let code):
                throw ScanError.enumerationFailed(errno: code)
            }
        }
        return DirectoryEntryPage(entries: [], isLast: true)
    }
}

/// Enumerator keyed by the real directory inode (resolved from the fd) so the
/// engine still opens genuine directories while the entries are scripted. One
/// inode can be blocked on a semaphore to inspect the persisted snapshot
/// mid-scan.
private final class PathScriptedEnumerator: DirectoryEnumerator, @unchecked Sendable {
    typealias Step = PublicationCursor.Step

    private let scripts: [UInt64: Step]
    private let blockInode: UInt64?
    private let gate = DispatchSemaphore(value: 0)

    init(scripts: [String: Step], blockPath: String? = nil) {
        var byInode: [UInt64: Step] = [:]
        for (path, step) in scripts {
            if let inode = Self.inode(of: path) {
                byInode[inode] = step
            }
        }
        self.scripts = byInode
        self.blockInode = blockPath.flatMap(Self.inode)
    }

    func makeCursor(
        in directory: DirectoryHandle,
        request: EnumerationRequest
    ) throws -> any DirectoryCursor {
        var info = stat()
        guard fstat(directory.fileDescriptor, &info) == 0 else {
            return PublicationCursor(.entries([]))
        }
        let inode = UInt64(info.st_ino)
        if let blockInode, inode == blockInode {
            gate.wait()
        }
        return PublicationCursor(scripts[inode] ?? .entries([]))
    }

    func release() {
        gate.signal()
    }

    private static func inode(of path: String) -> UInt64? {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        return UInt64(info.st_ino)
    }
}

/// Thread-safe holder for the `started` metadata observed mid-scan.
private final class StartedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var metadata: ScanMetadata?

    func set(_ value: ScanMetadata) {
        lock.lock()
        metadata = value
        lock.unlock()
    }

    var value: ScanMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return metadata
    }
}

private func directoryEntry(_ name: String, fileID: UInt64) -> RawDirectoryEntry {
    RawDirectoryEntry(
        nameBytes: Array(name.utf8),
        kind: .directory,
        deviceID: 1,
        fileID: fileID
    )
}

private func fileEntry(_ name: String, allocated: UInt64, fileID: UInt64) -> RawDirectoryEntry {
    RawDirectoryEntry(
        nameBytes: Array(name.utf8),
        kind: .regularFile,
        logicalBytes: allocated,
        allocatedBytes: allocated,
        deviceID: 1,
        fileID: fileID,
        linkCount: 1
    )
}

@Suite("Directory publication", .serialized)
struct DirectoryPublicationTests {
    /// Small task-owned temporary root directory.
    private struct TempRoot {
        let url: URL

        init(prefix: String) throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            url = base
        }

        var path: String { url.path }

        func directory(_ name: String) throws -> URL {
            let target = url.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            return target
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }
    private func makeStore() throws -> (store: SQLiteSnapshotRepository, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacejudge-publication-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("store.sqlite").path
        return (try SQLiteSnapshotRepository(path: path), directory)
    }

    private func request(for path: String) -> ScanRequest {
        ScanRequest(
            root: ScanRoot(fileSystemPath: path, displayName: "fixture"),
            // Descend regardless of the fake device IDs.
            boundaryPolicy: .selectedTree
        )
    }

    private func waitForStarted(_ box: StartedBox, timeout: Double = 5) async -> ScanMetadata? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if let value = box.value { return value }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return box.value
    }

    @Test(
        "A directory is persisted as soon as its own enumeration finishes",
        .timeLimit(.minutes(1))
    )
    func directoryPublishedBeforeSubtreeCompletes() async throws {
        let root = try TempRoot(prefix: "spacejudge-publication")
        defer { root.remove() }
        let child = try root.directory("child")
        let grand = try root.directory("child/grand")

        let database = try makeStore()
        defer { try? FileManager.default.removeItem(at: database.directory) }

        let enumerator = PathScriptedEnumerator(
            scripts: [
                root.path: .entries([directoryEntry("child", fileID: 2)]),
                child.path: .entries([
                    directoryEntry("grand", fileID: 3),
                    fileEntry("f", allocated: 100, fileID: 4)
                ]),
                grand.path: .entries([fileEntry("g", allocated: 200, fileID: 5)])
            ],
            blockPath: grand.path
        )
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: enumerator,
                workerCount: 1,
                batchNodeLimit: 1,
                batchTimeMilliseconds: 1
            )
        )
        let store = database.store
        let runner = PersistingScanRunner(engine: engine, repository: store)

        let started = StartedBox()
        let runTask = Task {
            try await runner.run(request(for: root.path)) { update in
                if case .started(let metadata) = update {
                    started.set(metadata)
                }
            }
        }

        let metadata = try #require(await waitForStarted(started))
        let scanID = metadata.scanID
        let rootNodeID = metadata.rootNodeID

        // Mid-scan: root and child have finished their own enumeration, the
        // grandchild is blocked. The child must already be queryable.
        var childPage: SnapshotChildPage?
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let page = try? await store.childPage(of: rootNodeID, in: scanID, limit: 100),
               !page.items.isEmpty {
                childPage = page
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let page = try #require(childPage)
        #expect(page.totalCount == 1)
        let childItem = try #require(page.items.first)
        #expect(childItem.node.kind == .directory)
        #expect(childItem.name.decodedString == "child")

        // The final root aggregate must NOT exist yet: the subtree is still
        // being scanned, so no area/weight is fabricated early.
        let earlyAggregate = try await store.aggregate(of: rootNodeID, in: scanID)
        #expect(earlyAggregate?.isComplete != true)

        enumerator.release()
        let summary = try await runTask.value
        #expect(summary.status == .completed)
        // root + child + grand = 3 directories; f + g = 2 files.
        #expect(summary.directoryCount == 3)
        #expect(summary.fileCount == 2)

        let rootAggregate = try #require(try await store.aggregate(of: rootNodeID, in: scanID))
        #expect(rootAggregate.isComplete)
        #expect(rootAggregate.attributedBytes == 300)
        #expect(rootAggregate.descendantFileCount == 2)
        #expect(rootAggregate.descendantDirectoryCount == 2)

        let children = try await store.children(of: rootNodeID, in: scanID)
        #expect(children.count == 1)
        #expect(children.first?.id == childItem.node.id)
        await store.close()
    }

    @Test(
        "A failed directory keeps its inaccessible flag and is persisted once",
        .timeLimit(.minutes(1))
    )
    func failedDirectoryFlagsPreserved() async throws {
        let root = try TempRoot(prefix: "spacejudge-publication-fail")
        defer { root.remove() }
        let bad = try root.directory("bad")

        let database = try makeStore()
        defer { try? FileManager.default.removeItem(at: database.directory) }

        let enumerator = PathScriptedEnumerator(scripts: [
            root.path: .entries([directoryEntry("bad", fileID: 2)]),
            bad.path: .failure(EACCES)
        ])
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: enumerator,
                workerCount: 1,
                batchNodeLimit: 1,
                batchTimeMilliseconds: 1
            )
        )
        let store = database.store
        let runner = PersistingScanRunner(engine: engine, repository: store)
        let summary = try await runner.run(request(for: root.path))
        #expect(summary.status == .completed)

        let rootNodeID = try #require(try await store.scanState(summary.scanID)?.rootNodeID)
        let children = try await store.children(of: rootNodeID, in: summary.scanID)
        let badRecord = try #require(children.first { $0.kind == .directory })
        #expect(badRecord.flags.contains(.inaccessible))
        #expect(children.filter { $0.id == badRecord.id }.count == 1)

        let badAggregate = try #require(try await store.aggregate(of: badRecord.id, in: summary.scanID))
        #expect(!badAggregate.isComplete)
        #expect(badAggregate.inaccessibleDescendantCount == 1)

        let rootAggregate = try #require(try await store.aggregate(of: rootNodeID, in: summary.scanID))
        #expect(rootAggregate.inaccessibleDescendantCount == 1)
        await store.close()
    }

    @Test("GUI live weights appear early and survive completion or cancellation", .timeLimit(.minutes(1)), arguments: [false, true])
    func progressiveWeightsBeforeCompletion(cancel: Bool) async throws {
        let root = try TempRoot(prefix: "spacejudge-live")
        defer { root.remove() }
        let child = try root.directory("child")
        let grand = try root.directory("child/grand")
        let database = try makeStore()
        defer { try? FileManager.default.removeItem(at: database.directory) }
        let enumerator = PathScriptedEnumerator(scripts: [
            root.path: .entries([directoryEntry("child", fileID: 2)]),
            child.path: .entries([directoryEntry("grand", fileID: 3), fileEntry("f", allocated: 100, fileID: 4)]),
            grand.path: .entries([fileEntry("g", allocated: 200, fileID: 5)])
        ], blockPath: grand.path)
        defer { enumerator.release() }
        let engine = FileSystemScanEngine(configuration: ScanConfiguration(
            enumerator: enumerator, workerCount: 1, batchNodeLimit: 1,
            batchTimeMilliseconds: 1, progressiveDirectoryLimit: 512))
        let store = database.store
        let runner = PersistingScanRunner(engine: engine, repository: store)
        let started = StartedBox()
        let runTask = Task {
            try await runner.run(request(for: root.path)) { update in
                if case .started(let metadata) = update { started.set(metadata) }
            }
        }
        let metadata = try #require(await waitForStarted(started))
        var liveChild: SnapshotChildItem?
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let page = try? await store.childPage(of: metadata.rootNodeID, in: metadata.scanID, limit: 100),
               let child = page.items.first, child.effectiveAttributedBytes == 100 {
                liveChild = child; break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let childItem = try #require(liveChild)
        let early = try #require(try await store.aggregate(of: childItem.node.id, in: metadata.scanID))
        #expect(!early.isComplete)
        #expect(early.attributedBytes == 100)
        let rootEarly = try #require(try await store.aggregate(of: metadata.rootNodeID, in: metadata.scanID))
        #expect(!rootEarly.isComplete)
        #expect(rootEarly.attributedBytes == 100)
        if cancel { await engine.cancel(scanID: metadata.scanID) }
        enumerator.release()
        let summary = try await runTask.value
        #expect(summary.status == (cancel ? .cancelled : .completed))
        #expect(summary.rootAttributedBytes == (cancel ? 100 : 300))
        let final = try #require(try await store.aggregate(of: childItem.node.id, in: metadata.scanID))
        #expect(final.isComplete == !cancel)
        #expect(final.attributedBytes == (cancel ? 100 : 300))
        await store.close()
    }
}
