import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
@testable import SpaceJudgeAppSupport

/// Codex-owned regression for the stale real-App selection observed while a
/// newly published directory was waiting for its subtree aggregate.
@MainActor
@Suite("Selection independent acceptance", .serialized)
struct SelectionIndependentAcceptanceTests {
    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @Test("An already selected directory adopts new scene bytes and aggregate without reselecting")
    func liveSelectionRefreshes() async {
        let scanID = appSupportScanID()
        let engine = ScriptedScanEngine(scanID: scanID, events: [
            .started(appSupportMetadata(scanID: scanID)),
            .batch(NodeBatch(scanID: scanID, revision: Revision(1), nodes: [])),
            .completed(appSupportSummary(scanID: scanID, status: .completed))
        ])
        let reader = StubSnapshotRepository()
        await reader.setPage(SnapshotChildPage(
            items: [appSupportChildItem(id: 2, name: "early directory", attributed: 0)],
            totalCount: 1, snapshotRevision: Revision(1)
        ), for: NodeID(1))
        let model = AppModel(
            engine: engine, repository: StubSnapshotRepository(), reader: reader,
            directoryAccess: TestDirectoryAccess(nextSelection: DirectorySelection(
                url: URL(fileURLWithPath: "/private/tmp/spacejudge-independent-selection"),
                displayName: "fixture"
            )), sceneReader: reader, shutdown: {}
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene?.isTerminal == true && !model.isSceneLoading })
        model.selectNode(NodeID(2))
        #expect(model.selectedItem?.effectiveBytes == 0)
        let aggregate = DirectoryAggregateRecord(
            nodeID: NodeID(2), logicalBytes: 123, allocatedBytes: 123,
            attributedBytes: 123, descendantFileCount: 1,
            descendantDirectoryCount: 0, inaccessibleDescendantCount: 0,
            isComplete: true
        )
        await reader.setAggregate(aggregate)
        await reader.setPage(SnapshotChildPage(
            items: [appSupportChildItem(id: 2, name: "early directory", attributed: 123)],
            totalCount: 1, snapshotRevision: Revision(2)
        ), for: NodeID(1))
        model.retrySceneLoad()
        #expect(await waitUntil { model.treemapScene?.revision == Revision(2) && !model.isSceneLoading })
        #expect(await waitUntil {
            model.selectedItem?.effectiveBytes == 123 && model.selectedAggregate?.isComplete == true
        })
        #expect(model.selectedNodeID == NodeID(2))
        #expect(model.selectedAggregate?.attributedBytes == 123)
        model.clearSelection()
        model.retrySceneLoad()
        #expect(await waitUntil { !model.isSceneLoading })
        #expect(model.selectedItem == nil && model.selectedAggregate == nil)
        await model.shutdown()
    }

    @Test("A zero directory under a completed parent is known zero without expanding its page")
    func completedParentEstablishesZero() async {
        let scanID = appSupportScanID()
        let engine = ScriptedScanEngine(scanID: scanID, events: [
            .started(appSupportMetadata(scanID: scanID)),
            .batch(NodeBatch(scanID: scanID, revision: Revision(1), nodes: [])),
            .completed(appSupportSummary(scanID: scanID, status: .completed))
        ])
        let reader = StubSnapshotRepository()
        let completeParent = DirectoryAggregateRecord(
            nodeID: NodeID(1), logicalBytes: 0, allocatedBytes: 0,
            attributedBytes: 0, descendantFileCount: 0,
            descendantDirectoryCount: 1, inaccessibleDescendantCount: 0,
            isComplete: true
        )
        await reader.setPage(SnapshotChildPage(
            items: [appSupportChildItem(id: 2, name: "actually empty", attributed: 0)],
            totalCount: 1, snapshotRevision: Revision(1), parentAggregate: completeParent
        ), for: NodeID(1))
        let model = AppModel(
            engine: engine, repository: StubSnapshotRepository(), reader: reader,
            directoryAccess: TestDirectoryAccess(nextSelection: DirectorySelection(
                url: URL(fileURLWithPath: "/private/tmp/spacejudge-independent-selection"),
                displayName: "fixture"
            )), sceneReader: reader, shutdown: {}
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene?.isTerminal == true && !model.isSceneLoading })
        if let child = model.treemapScene?.item(NodeID(2)) {
            #expect(model.treemapScene?.expandedPages[NodeID(2)] == nil)
            #expect(model.listEffectiveBytes(for: child) == 0)
        } else {
            Issue.record("Completed zero-weight directory must remain in the bounded list")
        }
        await model.shutdown()
    }

    @Test("Entering an early zero-weight directory during an active scan keeps focus after cancellation")
    func activeScanNavigationKeepsFocus() async {
        let scanID = appSupportScanID()
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [.started(appSupportMetadata(scanID: scanID))],
            holdsOpen: true,
            terminalOnCancel: appSupportSummary(scanID: scanID, status: .cancelled)
        )
        let reader = StubSnapshotRepository()
        await reader.setPage(SnapshotChildPage(
            items: [appSupportChildItem(id: 2, name: "early directory", attributed: 0)],
            totalCount: 1, snapshotRevision: Revision(1)
        ), for: NodeID(1))
        await reader.setPage(SnapshotChildPage(
            items: [], totalCount: 0, snapshotRevision: Revision(1)
        ), for: NodeID(2))
        let model = AppModel(
            engine: engine, repository: StubSnapshotRepository(), reader: reader,
            directoryAccess: TestDirectoryAccess(nextSelection: DirectorySelection(
                url: URL(fileURLWithPath: "/private/tmp/spacejudge-independent-navigation"),
                displayName: "fixture"
            )), sceneReader: reader, shutdown: {}
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene?.item(NodeID(2)) != nil })
        #expect(model.isScanning)
        model.selectNode(NodeID(2))
        await model.enter(NodeID(2))
        #expect(await waitUntil { model.treemapScene?.focusNodeID == NodeID(2) && !model.isSceneLoading })
        #expect(model.isScanning)
        #expect(model.treemapScene?.isTerminal == false)
        await model.cancelScan()
        #expect(await waitUntil { model.treemapScene?.isTerminal == true && !model.isSceneLoading })
        #expect(model.phase == .cancelled)
        #expect(model.currentNodeID == NodeID(2))
        #expect(model.treemapScene?.focusNodeID == NodeID(2))
        await model.shutdown()
    }
}
