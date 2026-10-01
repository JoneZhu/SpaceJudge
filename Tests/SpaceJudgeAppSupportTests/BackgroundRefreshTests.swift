import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
@testable import SpaceJudgeAppSupport

private final class RefreshSequenceEngine: ScanEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let first: ScriptedScanEngine
    let second: ScriptedScanEngine
    init(first: ScriptedScanEngine, second: ScriptedScanEngine) {
        self.first = first; self.second = second
    }
    func events(for request: ScanRequest) -> AsyncThrowingStream<ScanEvent, any Error> {
        let engine = lock.withLock { count += 1; return count == 1 ? first : second }
        return engine.events(for: request)
    }
    func cancel(scanID: ScanID) async { await second.cancel(scanID: scanID) }
}

@MainActor
@Suite("Background refresh", .serialized)
struct BackgroundRefreshTests {
    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    private func node(_ id: UInt64, parent: UInt64?, scan: ScanID, name: String) -> SnapshotChildItem {
        SnapshotChildItem(node: NodeRecord(id: NodeID(id), scanID: scan, parentID: parent.map(NodeID.init),
            name: NameID(id), kind: .directory, flags: [], logicalBytes: nil, allocatedBytes: nil, attributedBytes: 4096),
            name: NameRecord(id: NameID(id), bytes: Array(name.utf8)))
    }

    private func harness(second: ScriptedScanEngine, folderExists: Bool = true) async -> AppModel {
        let old = appSupportScanID(91), new = appSupportScanID(92)
        let first = ScriptedScanEngine(scanID: old, events: [
            .started(appSupportMetadata(scanID: old)),
            .batch(NodeBatch(scanID: old, revision: Revision(1), nodes: [])),
            .completed(appSupportSummary(scanID: old, status: .completed))])
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let root = node(1, parent: nil, scan: old, name: "fixture")
        let folder = node(2, parent: 1, scan: old, name: "Docker")
        let replacement = node(102, parent: 101, scan: new, name: "Docker")
        await reader.setName(root.name)
        await reader.setName(folder.name)
        await reader.setName(replacement.name)
        await reader.setAncestors([root.node], for: NodeID(1))
        await reader.setAncestors([root.node, folder.node], for: NodeID(2))
        await reader.setPage(SnapshotChildPage(items: [folder], totalCount: 1), for: NodeID(1))
        await reader.setPage(SnapshotChildPage(items: [], totalCount: 0), for: NodeID(2))
        await reader.setPage(SnapshotChildPage(items: folderExists ? [replacement] : [], totalCount: folderExists ? 1 : 0), for: NodeID(101))
        await reader.setPage(SnapshotChildPage(items: [], totalCount: 0), for: NodeID(102))
        let engine = RefreshSequenceEngine(first: first, second: second)
        let model = AppModel(engine: engine, repository: repository, reader: reader,
            directoryAccess: TestDirectoryAccess(nextSelection: DirectorySelection(url: URL(fileURLWithPath: "/tmp/fixture"))),
            shutdown: {})
        await model.chooseRoot()
        await model.waitForScanToFinish()
        #expect(await waitUntil { model.treemapScene != nil })
        await model.enter(NodeID(2))
        #expect(await waitUntil { model.treemapScene?.focusNodeID == NodeID(2) })
        return model
    }

    @Test("Refresh restores the same path even when scan-local IDs change")
    func restoresPath() async {
        let scan = appSupportScanID(92)
        let second = ScriptedScanEngine(scanID: scan, events: [
            .started(appSupportMetadata(scanID: scan, rootNodeID: NodeID(101))),
            .completed(appSupportSummary(scanID: scan, status: .completed))])
        let model = await harness(second: second)
        await model.rescan()
        await model.waitForScanToFinish()
        #expect(model.scanID == scan)
        #expect(model.currentNodeID == NodeID(102))
        #expect(model.breadcrumbs.map(\.name) == ["fixture", "Docker"])
        #expect(model.treemapScene?.focusNodeID == NodeID(102))
        #expect(!model.isRefreshing)
        await model.shutdown()
    }

    @Test("A deleted focus returns to its closest existing ancestor")
    func deletedFocus() async {
        let scan = appSupportScanID(92)
        let second = ScriptedScanEngine(scanID: scan, events: [
            .started(appSupportMetadata(scanID: scan, rootNodeID: NodeID(101))),
            .completed(appSupportSummary(scanID: scan, status: .completed))])
        let model = await harness(second: second, folderExists: false)
        await model.rescan()
        await model.waitForScanToFinish()
        #expect(model.currentNodeID == NodeID(101))
        #expect(model.refreshMessage?.contains("原目录已不存在") == true)
        await model.shutdown()
    }

    @Test("Cancellation keeps the old map and targets the background scan ID")
    func cancellationKeepsOldMap() async {
        let scan = appSupportScanID(92)
        let second = ScriptedScanEngine(scanID: scan, events: [
            .started(appSupportMetadata(scanID: scan, rootNodeID: NodeID(101)))],
            holdsOpen: true, terminalOnCancel: appSupportSummary(scanID: scan, status: .cancelled))
        let model = await harness(second: second)
        await model.rescan()
        #expect(await waitUntil { model.phase == .scanning })
        #expect(model.isRefreshing)
        #expect(model.scanID == appSupportScanID(91))
        #expect(model.currentNodeID == NodeID(2))
        #expect(model.treemapScene?.focusNodeID == NodeID(2))
        await model.cancelScan()
        #expect(second.cancelledScanIDs == [scan])
        #expect(model.phase == .completed)
        #expect(model.summary?.scanID == appSupportScanID(91))
        #expect(model.treemapScene?.focusNodeID == NodeID(2))
        #expect(model.refreshMessage?.contains("已取消") == true)
        await model.shutdown()
    }

    @Test("A failed refresh preserves the prior snapshot and capacity")
    func failureKeepsOldMap() async {
        let scan = appSupportScanID(92)
        let second = ScriptedScanEngine(scanID: scan, events: [], finishError: ScanError.rootOpenFailed(errno: ENOENT))
        let model = await harness(second: second)
        let oldVolume = model.volume
        await model.rescan()
        await model.waitForScanToFinish()
        #expect(model.scanID == appSupportScanID(91))
        #expect(model.currentNodeID == NodeID(2))
        #expect(model.phase == .completed)
        #expect(model.userError == .rootUnavailable)
        #expect(model.volume == oldVolume)
        #expect(!model.isRefreshing)
        await model.shutdown()
    }

    @Test("Opening starts idle; cancelling a suggested-location picker starts no scan")
    func welcomeDoesNotScanAutomatically() async {
        let engine = ScriptedScanEngine(scanID: appSupportScanID(), events: [])
        let repository = StubSnapshotRepository()
        let access = TestDirectoryAccess()
        let model = AppModel(engine: engine, repository: repository, reader: repository, directoryAccess: access, shutdown: {})
        #expect(model.phase == .idle)
        #expect(engine.recordedRequests.isEmpty)
        await model.chooseRoot(initialURL: URL(fileURLWithPath: "/"))
        #expect(model.phase == .idle)
        #expect(!model.hasRoot)
        #expect(engine.recordedRequests.isEmpty)
        #expect(access.started.isEmpty)
        await model.shutdown()
    }
}
