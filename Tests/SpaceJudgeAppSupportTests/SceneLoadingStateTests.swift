import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeTreemap
import SpaceJudgeUseCases
@testable import SpaceJudgeAppSupport

@MainActor
@Suite("Scene loading and read failure presentation", .serialized)
struct SceneLoadingStateTests {
    private let scanID = appSupportScanID()
    private let rootNodeID = NodeID(1)
    private let fixtureURL = URL(fileURLWithPath: "/private/tmp/spacejudge-loading")

    private func waitUntil(
        timeout: Double = 3,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    private func page(_ parent: NodeID, ids: ClosedRange<UInt64>, revision: UInt64 = 5) -> SnapshotChildPage {
        let items = ids.map { appSupportChildItem(id: $0, name: "item-\($0)", attributed: UInt64(10_000 - $0)) }
        return SnapshotChildPage(
            items: items, totalCount: UInt64(items.count), snapshotRevision: Revision(revision)
        )
    }

    private func makeModel(
        sceneReader: StubSnapshotRepository,
        holdsOpen: Bool = false,
        pageDelay: UInt64 = 0
    ) async -> AppModel {
        let events: [ScanEvent] = holdsOpen
            ? [.started(appSupportMetadata(scanID: scanID, rootNodeID: rootNodeID))]
            : [
                .started(appSupportMetadata(scanID: scanID, rootNodeID: rootNodeID)),
                .batch(NodeBatch(scanID: scanID, revision: Revision(1), nodes: [])),
                .completed(appSupportSummary(scanID: scanID, status: .completed))
            ]
        let engine = ScriptedScanEngine(scanID: scanID, events: events, holdsOpen: holdsOpen)
        if pageDelay > 0 { await sceneReader.setPageDelay(nanoseconds: pageDelay) }
        let model = AppModel(
            engine: engine,
            repository: StubSnapshotRepository(),
            reader: StubSnapshotRepository(),
            directoryAccess: TestDirectoryAccess(
                nextSelection: DirectorySelection(url: fixtureURL, displayName: "fixture")
            ),
            sceneReader: sceneReader,
            shutdown: {}
        )
        return model
    }

    @Test("A first read failure is visible with no retained map")
    func firstReadFailureIsVisible() async {
        let reader = StubSnapshotRepository()
        await reader.setPageFailure(for: rootNodeID)
        let model = await makeModel(sceneReader: reader)
        await model.chooseRoot()
        #expect(await waitUntil { model.sceneError != nil && !model.isSceneLoading })
        #expect(model.treemapScene == nil)
        #expect(model.presentationState == .sceneError)
        #expect(!model.isSceneLoading)
        await model.shutdown()
    }

    @Test("Retrying a still-failing read keeps the error until it actually recovers")
    func retryFailureStaysHonest() async {
        let reader = StubSnapshotRepository()
        await reader.setPageFailure(for: rootNodeID)
        let model = await makeModel(sceneReader: reader)
        await model.chooseRoot()
        #expect(await waitUntil { model.sceneError != nil })

        // Retry while the read still fails: the error must not be cleared
        // before a successful read.
        model.retrySceneLoad()
        #expect(model.isSceneLoading || model.sceneError != nil)
        #expect(await waitUntil { !model.isSceneLoading })
        #expect(model.sceneError != nil)
        #expect(model.presentationState == .sceneError)

        // Now let the read succeed and retry again.
        await reader.clearPageFailure(for: rootNodeID)
        await reader.setPage(page(rootNodeID, ids: 2...5), for: rootNodeID)
        model.retrySceneLoad()
        #expect(await waitUntil { model.treemapScene != nil })
        #expect(model.sceneError == nil)
        #expect(model.presentationState != .sceneError)
        await model.shutdown()
    }

    @Test("A new focus marks the retained old map as loading and stale")
    func focusSwitchMarksLoadingAndStale() async {
        let reader = StubSnapshotRepository()
        await reader.setPage(page(rootNodeID, ids: 2...6), for: rootNodeID)
        await reader.setPage(page(NodeID(2), ids: 20...24), for: NodeID(2))
        let model = await makeModel(sceneReader: reader, pageDelay: 250_000_000)
        await model.chooseRoot()
        #expect(await waitUntil(timeout: 6) { model.treemapScene != nil })

        await model.enter(NodeID(2))
        // The old map is still installed but belongs to the previous focus.
        #expect(model.isSceneStale)
        #expect(model.presentationState == .loading)
        #expect(model.presentationState.explanation != nil)

        #expect(await waitUntil(timeout: 6) { !model.isSceneStale })
        #expect(model.treemapScene?.focusNodeID == NodeID(2))
        await model.shutdown()
    }

    @Test("A read failure after navigation keeps the old map but reports the error")
    func retainedOldMapError() async {
        let reader = StubSnapshotRepository()
        await reader.setPage(page(rootNodeID, ids: 2...6), for: rootNodeID)
        let model = await makeModel(sceneReader: reader)
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene?.focusNodeID == rootNodeID })

        await reader.setPageFailure(for: NodeID(2))
        await model.enter(NodeID(2))
        #expect(await waitUntil { model.sceneError != nil && !model.isSceneLoading })
        // The old root map is retained and clearly marked as a different focus.
        #expect(model.treemapScene?.focusNodeID == rootNodeID)
        #expect(model.isSceneStale)
        #expect(model.presentationState == .sceneError)
        await model.shutdown()
    }

    @Test("A read failure during an active scan is visible")
    func scanningReadFailureIsVisible() async {
        let reader = StubSnapshotRepository()
        await reader.setPageFailure(for: rootNodeID)
        let model = await makeModel(sceneReader: reader, holdsOpen: true)
        await model.chooseRoot()
        #expect(await waitUntil { model.sceneError != nil && !model.isSceneLoading })
        #expect(model.phase == .scanning || model.phase == .preparing)
        #expect(model.presentationState == .sceneError)
        await model.shutdown()
    }

    @Test("A stale old map rejects selection, expansion and Finder")
    func staleMapRejectsActions() async {
        let reader = StubSnapshotRepository()
        await reader.setPage(page(rootNodeID, ids: 2...4), for: rootNodeID)
        await reader.setPage(page(NodeID(2), ids: 20...22), for: NodeID(2))
        let model = await makeModel(sceneReader: reader, pageDelay: 250_000_000)
        await model.chooseRoot()
        #expect(await waitUntil(timeout: 6) { model.treemapScene != nil && !model.isSceneLoading })

        await model.enter(NodeID(2))
        #expect(model.isSceneStale)

        model.selectNode(NodeID(3))
        #expect(model.selectedItem == nil)
        #expect(model.selectedNodeID == nil)
        model.selectOther(parentID: rootNodeID, collapsedCount: 2, effectiveBytes: 100)
        #expect(model.selectedOther == nil)
        model.expand(NodeID(3))
        #expect(model.expandedNodeIDs.isEmpty)
        model.collapse(NodeID(3))
        #expect(model.suppressedPreviewNodeIDs.isEmpty)
        let url = await model.finderURLForSelection()
        #expect(url == nil)
        #expect(model.revealError != nil)

        // Leaving the loading focus must still be allowed.
        #expect(model.canGoBack)
        await model.goBack()
        #expect(model.currentNodeID == rootNodeID)
        await model.shutdown()
    }

    @Test("The focus size comes from the focus aggregate, never the root total")
    func focusSizeUsesFocusAggregate() async {
        let reader = StubSnapshotRepository()
        let rootAggregate = DirectoryAggregateRecord(
            nodeID: rootNodeID, logicalBytes: 10_000, allocatedBytes: 10_000,
            attributedBytes: 10_000, descendantFileCount: 1, descendantDirectoryCount: 1,
            inaccessibleDescendantCount: 0, isComplete: true
        )
        let childAggregate = DirectoryAggregateRecord(
            nodeID: NodeID(2), logicalBytes: 500, allocatedBytes: 500,
            attributedBytes: 500, descendantFileCount: 1, descendantDirectoryCount: 0,
            inaccessibleDescendantCount: 0, isComplete: false
        )
        let rootPage = SnapshotChildPage(
            items: [appSupportChildItem(id: 2, name: "child", attributed: 500)],
            totalCount: 1, snapshotRevision: Revision(5), parentAggregate: rootAggregate
        )
        let childPage = SnapshotChildPage(
            items: [], totalCount: 0, snapshotRevision: Revision(5), parentAggregate: childAggregate
        )
        await reader.setPage(rootPage, for: rootNodeID)
        await reader.setPage(childPage, for: NodeID(2))
        let model = await makeModel(sceneReader: reader)
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene?.focusNodeID == self.rootNodeID })
        #expect(model.focusAttributedBytes == 10_000)

        await model.enter(NodeID(2))
        #expect(await waitUntil { model.treemapScene?.focusNodeID == NodeID(2) })
        #expect(model.focusAttributedBytes == 500)
        #expect(model.focusAggregateIsComplete == false)
        #expect(model.focusSizeLine.contains("未完成"))
        // The focus line must not report the root total.
        #expect(!model.focusSizeLine.contains("10"))
        await model.shutdown()
    }
}
