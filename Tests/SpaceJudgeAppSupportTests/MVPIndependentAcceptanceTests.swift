import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeTreemap
@testable import SpaceJudgeAppSupport

/// Codex-owned independent acceptance: user-visible regressions, not Pi's self-test.
@MainActor
@Suite("MVP independent acceptance", .serialized)
struct MVPIndependentAcceptanceTests {
    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    private func emptyScene() -> TreemapSceneData {
        let page = TreemapScenePage(
            parentID: NodeID(2), items: [], totalCount: 0,
            snapshotRevision: Revision(3), omittedCount: 0,
            omittedWeight: nil, aggregate: nil
        )
        return TreemapSceneData(
            scanID: appSupportScanID(), scanGeneration: 1, revision: Revision(3),
            focusNodeID: NodeID(2), focusName: "empty child", focusKind: .directory,
            focusAggregate: nil, focusPage: page, expandedPages: [:],
            expansionOrder: [], expansionVersion: 0, detailMode: .overview,
            isTerminal: true, rootDisplayName: "nonempty root"
        )
    }

    @Test("An empty child remains empty even when the full scan has bytes")
    func emptyChildOfNonemptyRoot() {
        #expect(AppPresentationState.resolve(
            phase: .completed, progress: nil, scene: emptyScene(),
            sceneError: false, attribution: 10_000
        ) == .emptyScope)
    }

    @Test("A failed first snapshot read is visible without a retained scene")
    func firstReadFailure() {
        let presentation = AppPresentationState.resolve(
            phase: .completed, progress: nil, scene: nil,
            sceneError: true, attribution: 10_000
        )
        #expect(presentation == .sceneError)
        #expect(presentation.explanation?.contains("上一版") != true)
    }

    @Test("Explicit expansion followed by collapse does not auto-reopen")
    func manualCollapseStaysClosed() async throws {
        let scanID = appSupportScanID()
        let engine = ScriptedScanEngine(scanID: scanID, events: [
            .started(appSupportMetadata(scanID: scanID, rootNodeID: NodeID(1))),
            .batch(NodeBatch(scanID: scanID, revision: Revision(1), nodes: [])),
            .completed(appSupportSummary(scanID: scanID, status: .completed))
        ])
        let reader = StubSnapshotRepository()
        await reader.setPage(SnapshotChildPage(
            items: [appSupportChildItem(id: 2, name: "directory", attributed: 1000)],
            totalCount: 1, snapshotRevision: Revision(1)
        ), for: NodeID(1))
        await reader.setPage(SnapshotChildPage(
            items: [appSupportChildItem(id: 3, name: "child", attributed: 1000)],
            totalCount: 1, snapshotRevision: Revision(1)
        ), for: NodeID(2))
        let model = AppModel(
            engine: engine, repository: StubSnapshotRepository(), reader: reader,
            directoryAccess: TestDirectoryAccess(nextSelection: DirectorySelection(
                url: URL(fileURLWithPath: "/private/tmp/spacejudge-independent-fixture"),
                displayName: "fixture"
            )), sceneReader: reader, shutdown: {}
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene?.expandedPages[NodeID(2)] != nil })
        model.expand(NodeID(2))
        let expandedVersion = model.expansionVersion
        #expect(await waitUntil { model.treemapScene?.expansionVersion == expandedVersion })
        model.collapse(NodeID(2))
        let collapsedVersion = model.expansionVersion
        #expect(await waitUntil { model.treemapScene?.expansionVersion == collapsedVersion })
        #expect(model.treemapScene?.expandedPages[NodeID(2)] == nil)
        #expect(!model.isExpanded(NodeID(2)))
        await model.shutdown()
    }

    @Test("A retained old-focus map cannot create a new selection while loading")
    func staleMapCannotSelect() async {
        let scanID = appSupportScanID()
        let engine = ScriptedScanEngine(scanID: scanID, events: [
            .started(appSupportMetadata(scanID: scanID, rootNodeID: NodeID(1))),
            .batch(NodeBatch(scanID: scanID, revision: Revision(1), nodes: [])),
            .completed(appSupportSummary(scanID: scanID, status: .completed))
        ])
        let reader = StubSnapshotRepository()
        await reader.setPage(SnapshotChildPage(
            items: [appSupportChildItem(id: 2, name: "next focus", attributed: 1000),
                    appSupportChildItem(id: 3, name: "old focus item", attributed: 800)],
            totalCount: 2, snapshotRevision: Revision(1)
        ), for: NodeID(1))
        let model = AppModel(
            engine: engine, repository: StubSnapshotRepository(), reader: reader,
            directoryAccess: TestDirectoryAccess(nextSelection: DirectorySelection(
                url: URL(fileURLWithPath: "/private/tmp/spacejudge-independent-fixture"),
                displayName: "fixture"
            )), sceneReader: reader, shutdown: {}
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene?.isTerminal == true && !model.isSceneLoading })
        await reader.setPageDelay(nanoseconds: 300_000_000)
        await model.enter(NodeID(2))
        #expect(model.isSceneStale)
        model.selectNode(NodeID(3))
        #expect(model.selectedItem == nil)
        #expect(model.selectedNodeID == nil)
        model.expand(NodeID(3))
        #expect(model.expandedNodeIDs.isEmpty)
        await model.shutdown()
    }
}
