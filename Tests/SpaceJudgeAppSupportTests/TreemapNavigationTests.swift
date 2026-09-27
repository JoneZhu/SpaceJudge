import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeTreemap
import SpaceJudgeUseCases
@testable import SpaceJudgeAppSupport

@MainActor
@Suite("Treemap navigation", .serialized)
struct TreemapNavigationTests {
    private let scanID = appSupportScanID()
    private let rootNodeID = NodeID(1)
    private let fixtureURL = URL(fileURLWithPath: "/private/tmp/spacejudge-nav")

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

    private func directoryPage(
        ids: ClosedRange<UInt64>,
        revision: UInt64 = 11,
        parent: NodeID = NodeID(1)
    ) -> SnapshotChildPage {
        let items = ids.map { id in
            appSupportChildItem(id: id, name: "dir-\(id)", attributed: UInt64(10_000 - id))
        }
        return SnapshotChildPage(
            items: items,
            totalCount: UInt64(items.count),
            snapshotRevision: Revision(revision)
        )
    }

    private func makeModel(
        scenePages: [NodeID: SnapshotChildPage],
        ancestors: [NodeID: [NodeRecord]] = [:],
        names: [NameRecord] = [],
        pageDelay: UInt64 = 0,
        holdsOpen: Bool = false
    ) async -> (AppModel, TestDirectoryAccess, StubSnapshotRepository) {
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID, rootNodeID: rootNodeID)),
                .batch(NodeBatch(scanID: scanID, revision: Revision(1), nodes: [])),
                .completed(appSupportSummary(scanID: scanID, status: .completed))
            ],
            holdsOpen: holdsOpen
        )
        let writer = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let sceneReader = StubSnapshotRepository()
        for (parent, page) in scenePages {
            await sceneReader.setPage(page, for: parent)
        }
        for (node, chain) in ancestors {
            await sceneReader.setAncestors(chain, for: node)
        }
        for name in names {
            await sceneReader.setName(name)
        }
        if pageDelay > 0 {
            await sceneReader.setPageDelay(nanoseconds: pageDelay)
        }
        let access = TestDirectoryAccess(
            nextSelection: DirectorySelection(url: fixtureURL, displayName: "fixture")
        )
        let model = AppModel(
            engine: engine,
            repository: writer,
            reader: reader,
            directoryAccess: access,
            sceneReader: sceneReader,
            shutdown: {}
        )
        return (model, access, sceneReader)
    }

    @Test("Entering a directory pushes history; back and up navigate it")
    func backAndUp() async {
        let rootRecord = NodeRecord(
            id: NodeID(1), scanID: scanID, parentID: nil, name: NameID(1),
            kind: .directory, logicalBytes: nil, allocatedBytes: nil, attributedBytes: 0
        )
        let item2 = appSupportChildItem(id: 2, name: "dir-2", attributed: 9_000)
        let item3 = appSupportChildItem(id: 3, name: "dir-3", attributed: 8_000)
        let (model, _, _) = await makeModel(
            scenePages: [
                NodeID(1): directoryPage(ids: 2...4),
                NodeID(2): directoryPage(ids: 20...22, parent: NodeID(2))
            ],
            ancestors: [
                NodeID(2): [rootRecord, item2.node],
                NodeID(3): [rootRecord, item3.node],
                NodeID(1): [rootRecord]
            ],
            names: [
                NameRecord(id: NameID(1), bytes: Array("fixture".utf8)),
                NameRecord(id: item2.name.id, bytes: Array("dir-2".utf8)),
                NameRecord(id: item3.name.id, bytes: Array("dir-3".utf8))
            ]
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.currentNodeID == self.rootNodeID })
        #expect(model.navigationHistory == [rootNodeID])
        #expect(!model.canGoBack)

        await model.enter(NodeID(2))
        #expect(model.currentNodeID == NodeID(2))
        #expect(model.navigationHistory == [rootNodeID, NodeID(2)])
        #expect(model.canGoBack)

        await model.goBack()
        #expect(model.currentNodeID == rootNodeID)
        #expect(model.navigationHistory.contains(rootNodeID))

        await model.enter(NodeID(2))
        await model.goUp()
        #expect(model.currentNodeID == rootNodeID)
        // Up is a new history entry, so back returns to the child.
        #expect(model.canGoBack)
        await model.goBack()
        #expect(model.currentNodeID == NodeID(2))

        await model.shutdown()
    }

    @Test("A new root resets history, selection and expansion")
    func newRootResets() async {
        let (model, access, _) = await makeModel(
            scenePages: [NodeID(1): directoryPage(ids: 2...9)]
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.currentNodeID == self.rootNodeID })
        model.selectNode(NodeID(2))
        model.expand(NodeID(2))
        #expect(!model.expandedNodeIDs.isEmpty)

        access.setNextSelection(DirectorySelection(url: fixtureURL, displayName: "other"))
        await model.chooseRoot()
        #expect(await waitUntil { model.currentNodeID == self.rootNodeID })
        #expect(model.navigationHistory == [rootNodeID])
        #expect(model.expandedNodeIDs.isEmpty)
        #expect(model.selectedNodeID == nil)
        #expect(!model.canGoBack)
        await model.shutdown()
    }

    @Test("The ninth expansion evicts the earliest non-selected directory")
    func expansionEviction() async {
        let (model, _, _) = await makeModel(
            scenePages: [NodeID(1): directoryPage(ids: 2...20)]
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.currentNodeID == self.rootNodeID })
        #expect(await waitUntil { model.treemapScene != nil })

        // Expand 2...9, then select 3 before expanding 10.
        for id in UInt64(2)...UInt64(9) {
            model.expand(NodeID(id))
        }
        #expect(model.expandedNodeIDs == (UInt64(2)...UInt64(9)).map(NodeID.init))
        model.selectNode(NodeID(3))
        model.expand(NodeID(10))
        #expect(model.expandedNodeIDs.count == 8)
        // 2 was the earliest non-selected and is evicted; 3 is preserved.
        #expect(!model.expandedNodeIDs.contains(NodeID(2)))
        #expect(model.expandedNodeIDs.contains(NodeID(3)))
        #expect(model.expandedNodeIDs.contains(NodeID(10)))
        await model.shutdown()
    }

    @Test("Late scene reads for an old focus are discarded")
    func lateQueryRejected() async {
        let (model, _, _) = await makeModel(
            scenePages: [
                NodeID(1): directoryPage(ids: 2...4),
                NodeID(2): directoryPage(ids: 20...22, parent: NodeID(2)),
                NodeID(3): directoryPage(ids: 30...32, parent: NodeID(3))
            ],
            pageDelay: 150_000_000
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.currentNodeID == self.rootNodeID })

        async let first: Void = model.enter(NodeID(2))
        async let second: Void = model.enter(NodeID(3))
        _ = await (first, second)

        #expect(await waitUntil { model.treemapScene?.focusNodeID == NodeID(3) })
        #expect(model.currentNodeID == NodeID(3))
        await model.shutdown()
    }

    @Test("Terminal refresh converges the scene to the final revision")
    func terminalConvergence() async {
        let (model, _, _) = await makeModel(
            scenePages: [NodeID(1): directoryPage(ids: 2...6, revision: 42)]
        )
        await model.chooseRoot()
        await model.waitForScanToFinish()
        #expect(await waitUntil { model.treemapScene?.isTerminal == true })
        #expect(await waitUntil { model.sceneRevision == Revision(42) })
        await model.shutdown()
    }

    @Test("Revision refresh keeps focus, selection and expansion")
    func revisionPreservesState() async {
        let (model, _, _) = await makeModel(
            scenePages: [NodeID(1): directoryPage(ids: 2...9)]
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.currentNodeID == self.rootNodeID })
        #expect(await waitUntil { model.treemapScene != nil })
        model.selectNode(NodeID(4))
        model.expand(NodeID(5))
        let expansion = model.expandedNodeIDs

        // A second view refresh must not reset navigation state.
        model.setDetailMode(.detail)
        await Task.yield()
        #expect(model.currentNodeID == rootNodeID)
        #expect(model.selectedNodeID == NodeID(4))
        #expect(model.expandedNodeIDs == expansion)
        await model.shutdown()
    }

    @Test("Detail mode is observable and switchable")
    func detailMode() async {
        let (model, _, _) = await makeModel(scenePages: [:])
        #expect(model.detailMode == .overview)
        model.setDetailMode(.detail)
        #expect(model.detailMode == .detail)
        await model.shutdown()
    }

    @Test("Selecting other never fabricates a node and clears with selection")
    func otherSelection() async {
        let (model, _, _) = await makeModel(scenePages: [NodeID(1): directoryPage(ids: 2...5)])
        await model.chooseRoot()
        #expect(await waitUntil { model.currentNodeID == self.rootNodeID })
        model.selectOther(parentID: NodeID(1), collapsedCount: 12, effectiveBytes: 4_096)
        #expect(model.selectedOther?.collapsedCount == 12)
        #expect(model.selectedOther?.effectiveBytes == 4_096)
        #expect(model.selectedNodeID == nil)
        #expect(model.selectedItem == nil)
        #expect(model.selectedRelativePath?.contains("其他") == true)
        model.clearSelection()
        #expect(model.selectedOther == nil)
        await model.shutdown()
    }

    @Test("Selection relative path uses scan-local names only")
    func relativePath() async {
        let nested = SnapshotChildItem(
            node: NodeRecord(
                id: NodeID(20), scanID: scanID, parentID: NodeID(2), name: NameID(20),
                kind: .regularFile, logicalBytes: 5, allocatedBytes: 5, attributedBytes: 5
            ),
            name: NameRecord(id: NameID(20), bytes: Array("file-20".utf8)),
            effectiveAttributedBytes: 5
        )
        let nestedPage = SnapshotChildPage(
            items: [nested], totalCount: 1, snapshotRevision: Revision(11)
        )
        let (model, _, _) = await makeModel(
            scenePages: [
                NodeID(1): directoryPage(ids: 2...5),
                NodeID(2): nestedPage
            ]
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.currentNodeID == self.rootNodeID })
        #expect(await waitUntil { model.treemapScene != nil })

        model.selectNode(NodeID(3))
        #expect(model.selectedRelativePath?.contains("dir-3") == true)

        model.expand(NodeID(2))
        #expect(await waitUntil { model.treemapScene?.expandedPages[NodeID(2)] != nil })
        model.selectNode(NodeID(20))
        let path = model.selectedRelativePath ?? ""
        #expect(path.contains("dir-2"))
        #expect(path.contains("file-20"))
        // Never an absolute path.
        #expect(!path.hasPrefix("/"))
        await model.shutdown()
    }

    @Test("Expansion change during a delayed query is not overwritten")
    func expansionChangeDuringDelayedQuery() async {
        let (model, _, sceneReader) = await makeModel(
            scenePages: [
                NodeID(1): directoryPage(ids: 2...9),
                NodeID(2): directoryPage(ids: 20...22, parent: NodeID(2)),
                NodeID(4): directoryPage(ids: 40...42, parent: NodeID(4))
            ]
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene != nil })

        // Make subsequent scene reads slow, then expand twice in quick
        // succession. The first (one-expansion) result must be discarded.
        await sceneReader.setPageDelay(nanoseconds: 200_000_000)
        model.expand(NodeID(2))
        model.expand(NodeID(4))
        let expectedVersion = model.expansionVersion

        #expect(await waitUntil {
            model.treemapScene?.expansionVersion == expectedVersion
                && model.treemapScene?.expandedPages[NodeID(2)] != nil
                && model.treemapScene?.expandedPages[NodeID(4)] != nil
        })
        #expect(model.treemapScene?.expansionVersion == model.expansionVersion)
        await model.shutdown()
    }

    @Test("Shutdown during a delayed query applies nothing afterwards")
    func shutdownDuringDelayedQuery() async {
        let (model, _, sceneReader) = await makeModel(
            scenePages: [
                NodeID(1): directoryPage(ids: 2...9),
                NodeID(2): directoryPage(ids: 20...22, parent: NodeID(2))
            ]
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene != nil })
        let before = model.treemapScene

        await sceneReader.setPageDelay(nanoseconds: 200_000_000)
        model.expand(NodeID(2))
        await model.shutdown()
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(model.treemapScene == before)
        #expect(model.treemapScene?.expandedPages.isEmpty == true)
    }

    @Test("Toggling detail mode before the first scene arrives converges")
    func modeToggleDuringFirstQuery() async {
        let (model, _, _) = await makeModel(
            scenePages: [NodeID(1): directoryPage(ids: 2...6)],
            pageDelay: 200_000_000
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.currentNodeID == self.rootNodeID })
        // The first query is still in flight when the mode changes.
        model.setDetailMode(.detail)
        #expect(await waitUntil { model.treemapScene != nil })
        #expect(model.detailMode == .detail)
        #expect(model.treemapScene?.detailMode == .detail)
        await model.shutdown()
    }

    @Test("A new scan clears a stale reveal error")
    func revealErrorClearedOnNewScan() async {
        let rootRecord = NodeRecord(
            id: NodeID(1), scanID: scanID, parentID: nil, name: NameID(1),
            kind: .directory, logicalBytes: nil, allocatedBytes: nil, attributedBytes: 0
        )
        let badNode = NodeRecord(
            id: NodeID(2), scanID: scanID, parentID: NodeID(1), name: NameID(2),
            kind: .directory, logicalBytes: nil, allocatedBytes: nil, attributedBytes: 0
        )
        let item = appSupportChildItem(id: 2, name: "dir-2", attributed: 9_000)
        let (model, access, _) = await makeModel(
            scenePages: [
                NodeID(1): SnapshotChildPage(
                    items: [item], totalCount: 1, snapshotRevision: Revision(11)
                )
            ],
            ancestors: [NodeID(2): [rootRecord, badNode]],
            names: [
                NameRecord(id: NameID(1), bytes: Array("fixture".utf8)),
                // An invalid POSIX component makes path resolution fail.
                NameRecord(id: NameID(2), bytes: Array("..".utf8))
            ]
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene != nil })
        model.selectNode(NodeID(2))
        _ = await model.finderURLForSelection()
        #expect(model.revealError != nil)

        access.setNextSelection(DirectorySelection(url: fixtureURL, displayName: "other"))
        await model.chooseRoot()
        #expect(model.revealError == nil)
        await model.shutdown()
    }

    @Test("Unknown omitted count surfaces a compact still-counting message")
    func hiddenOmittedMessage() async {
        let item = appSupportChildItem(id: 2, name: "dir-2", attributed: 9_000)
        let page = SnapshotChildPage(
            items: [item],
            totalCount: 10,
            snapshotRevision: Revision(11)
        )
        let (model, _, _) = await makeModel(scenePages: [NodeID(1): page])
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene != nil })
        #expect(model.treemapScene?.focusPage.omittedCount == 9)
        #expect(model.treemapScene?.focusPage.omittedWeight == nil)
        #expect(model.hiddenOmittedMessage == "还有 9 项正在统计")
        await model.shutdown()
    }
}
