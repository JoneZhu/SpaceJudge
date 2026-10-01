import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeTreemap
import SpaceJudgeUseCases
@testable import SpaceJudgeAppSupport

@MainActor
@Suite("Selected detail refresh", .serialized)
struct SelectedDetailRefreshTests {
    private let scanID = appSupportScanID()
    private let rootNodeID = NodeID(1)
    private let fixtureURL = URL(fileURLWithPath: "/private/tmp/spacejudge-selected")

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

    private func aggregate(
        _ nodeID: NodeID,
        attributed: UInt64,
        complete: Bool
    ) -> DirectoryAggregateRecord {
        DirectoryAggregateRecord(
            nodeID: nodeID,
            logicalBytes: attributed,
            allocatedBytes: attributed,
            attributedBytes: attributed,
            descendantFileCount: 1,
            descendantDirectoryCount: 0,
            inaccessibleDescendantCount: 0,
            isComplete: complete
        )
    }

    private func rootPage(childAttributed: UInt64, childIsDirectory: Bool = true) -> SnapshotChildPage {
        let item: SnapshotChildItem
        if childIsDirectory {
            item = appSupportChildItem(id: 2, name: "dir", attributed: childAttributed)
        } else {
            item = SnapshotChildItem(
                node: NodeRecord(
                    id: NodeID(2), scanID: scanID, parentID: rootNodeID, name: NameID(2),
                    kind: .regularFile, logicalBytes: childAttributed,
                    allocatedBytes: childAttributed, attributedBytes: childAttributed
                ),
                name: NameRecord(id: NameID(2), bytes: Array("file".utf8)),
                effectiveAttributedBytes: childAttributed
            )
        }
        return SnapshotChildPage(
            items: [item], totalCount: 1, snapshotRevision: Revision(5)
        )
    }

    private func makeModel(
        sceneReader: StubSnapshotRepository,
        holdsOpen: Bool = false
    ) async -> AppModel {
        let events: [ScanEvent] = holdsOpen
            ? [.started(appSupportMetadata(scanID: scanID, rootNodeID: rootNodeID))]
            : [
                .started(appSupportMetadata(scanID: scanID, rootNodeID: rootNodeID)),
                .batch(NodeBatch(scanID: scanID, revision: Revision(1), nodes: [])),
                .completed(appSupportSummary(scanID: scanID, status: .completed))
            ]
        let engine = ScriptedScanEngine(scanID: scanID, events: events, holdsOpen: holdsOpen)
        return AppModel(
            engine: engine,
            repository: StubSnapshotRepository(),
            reader: StubSnapshotRepository(),
            directoryAccess: TestDirectoryAccess(
                nextSelection: DirectorySelection(url: fixtureURL, displayName: "fixture")
            ),
            sceneReader: sceneReader,
            shutdown: {}
        )
    }

    @Test("A scene update refreshes the selected item and aggregate without re-selecting")
    func sceneUpdateRefreshesSelection() async {
        let reader = StubSnapshotRepository()
        await reader.setPage(rootPage(childAttributed: 0), for: rootNodeID)
        let model = await makeModel(sceneReader: reader)
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene != nil })

        model.selectNode(NodeID(2))
        #expect(await waitUntil { model.selectedNodeID == NodeID(2) })
        // No aggregate yet: a directory with a zero scene weight is unknown.
        #expect(model.selectedAggregate == nil)
        #expect(model.selectedEffectiveBytes == nil)

        // The aggregate becomes complete and the scene page weight updates.
        await reader.setAggregate(aggregate(NodeID(2), attributed: 123, complete: true))
        await reader.setPage(rootPage(childAttributed: 123), for: rootNodeID)
        model.reloadSceneForTesting()

        #expect(await waitUntil {
            model.selectedAggregate?.attributedBytes == 123
                && model.selectedItem?.effectiveBytes == 123
        })
        #expect(model.selectedItem?.effectiveBytes == 123)
        #expect(model.selectedAggregate?.isComplete == true)
        #expect(model.selectedEffectiveBytes == 123)
        await model.shutdown()
    }

    @Test("A slow stale aggregate query cannot overwrite a newer complete aggregate")
    func staleAggregateQueryIsRejected() async {
        let reader = StubSnapshotRepository()
        await reader.setPage(rootPage(childAttributed: 5), for: rootNodeID)
        await reader.setPage(
            SnapshotChildPage(
                items: [], totalCount: 0, snapshotRevision: Revision(5),
                parentAggregate: aggregate(NodeID(2), attributed: 123, complete: true)
            ),
            for: NodeID(2)
        )
        await reader.setAggregate(aggregate(NodeID(2), attributed: 5, complete: false))
        await reader.setAggregateDelay(nanoseconds: 300_000_000)

        let model = await makeModel(sceneReader: reader)
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene != nil })

        // Starts a slow query that will capture the old 5-byte aggregate.
        model.selectNode(NodeID(2))
        // Expanding loads node 2's own page, whose aggregate is the complete 123.
        model.expand(NodeID(2))
        #expect(await waitUntil { model.selectedAggregate?.attributedBytes == 123 })
        #expect(model.selectedAggregate?.isComplete == true)

        // Let the stale query finish; it must not overwrite the newer value.
        try? await Task.sleep(nanoseconds: 450_000_000)
        #expect(model.selectedAggregate?.attributedBytes == 123)
        #expect(model.selectedAggregate?.isComplete == true)
        await model.shutdown()
    }

    @Test("Clearing the selection invalidates an in-flight aggregate query")
    func clearInvalidatesAggregateQuery() async {
        let reader = StubSnapshotRepository()
        await reader.setPage(rootPage(childAttributed: 5), for: rootNodeID)
        await reader.setAggregate(aggregate(NodeID(2), attributed: 5, complete: true))
        await reader.setAggregateDelay(nanoseconds: 200_000_000)

        let model = await makeModel(sceneReader: reader)
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene != nil })

        model.selectNode(NodeID(2))
        model.clearSelection()
        try? await Task.sleep(nanoseconds: 350_000_000)
        #expect(model.selectedNodeID == nil)
        #expect(model.selectedAggregate == nil)
        #expect(model.selectedItem == nil)
        await model.shutdown()
    }

    @Test("Navigation clears the selection and its aggregate")
    func navigationClearsSelection() async {
        let reader = StubSnapshotRepository()
        await reader.setPage(rootPage(childAttributed: 5), for: rootNodeID)
        await reader.setPage(
            SnapshotChildPage(items: [], totalCount: 0, snapshotRevision: Revision(5)),
            for: NodeID(2)
        )
        await reader.setAggregate(aggregate(NodeID(2), attributed: 5, complete: true))

        let model = await makeModel(sceneReader: reader)
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene != nil })
        model.selectNode(NodeID(2))
        #expect(await waitUntil { model.selectedAggregate != nil })

        await model.enter(NodeID(2))
        #expect(model.selectedNodeID == nil)
        #expect(model.selectedAggregate == nil)
        await model.shutdown()
    }

    @Test("A completed zero-aggregate directory still reports a real zero")
    func completedZeroDirectoryIsZero() async {
        let reader = StubSnapshotRepository()
        await reader.setPage(rootPage(childAttributed: 0), for: rootNodeID)
        await reader.setAggregate(aggregate(NodeID(2), attributed: 0, complete: true))

        let model = await makeModel(sceneReader: reader)
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene != nil })

        model.selectNode(NodeID(2))
        #expect(await waitUntil { model.selectedAggregate != nil })
        #expect(model.selectedEffectiveBytes == 0)
        #expect(model.selectedAggregate?.isComplete == true)
        await model.shutdown()
    }

    @Test("After a cancel an unknown aggregate is terminal, never still-counting")
    func cancelledUnknownIsTerminal() async {
        let reader = StubSnapshotRepository()
        await reader.setPage(rootPage(childAttributed: 0), for: rootNodeID)
        let model = await makeModel(sceneReader: reader, holdsOpen: true)
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene != nil })

        model.selectNode(NodeID(2))
        #expect(await waitUntil { model.selectedNodeID == NodeID(2) })
        await model.cancelScan()
        #expect(model.phase == .cancelled)
        #expect(!model.progressWording.isActive)
        #expect(model.progressWording.pendingAggregateLabel == "未完成")
        #expect(model.selectedEffectiveBytes == nil)
        await model.shutdown()
    }

    @Test("An unknown directory in the bounded list is not reported as a certain zero")
    func listUnknownDirectoryIsNotZero() async {
        let reader = StubSnapshotRepository()
        await reader.setPage(
            SnapshotChildPage(
                items: [
                    appSupportChildItem(id: 2, name: "dir", attributed: 0),
                    SnapshotChildItem(
                        node: NodeRecord(
                            id: NodeID(3), scanID: scanID, parentID: rootNodeID, name: NameID(3),
                            kind: .regularFile, logicalBytes: 0, allocatedBytes: 0, attributedBytes: 0
                        ),
                        name: NameRecord(id: NameID(3), bytes: Array("empty".utf8)),
                        effectiveAttributedBytes: 0
                    )
                ],
                totalCount: 2, snapshotRevision: Revision(5)
            ),
            for: rootNodeID
        )
        await reader.setPage(
            SnapshotChildPage(
                items: [], totalCount: 0, snapshotRevision: Revision(5),
                parentAggregate: aggregate(NodeID(2), attributed: 0, complete: true)
            ),
            for: NodeID(2)
        )

        let model = await makeModel(sceneReader: reader)
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene?.focusPage.items.count == 2 })
        let directory = model.treemapScene!.focusPage.items.first { $0.nodeID == NodeID(2) }!
        let file = model.treemapScene!.focusPage.items.first { $0.nodeID == NodeID(3) }!

        // Unknown directory aggregate: not a certain zero.
        #expect(model.listEffectiveBytes(for: directory) == nil)
        // A file's zero is a real, known zero.
        #expect(model.listEffectiveBytes(for: file) == 0)

        // Once the directory's own page is loaded, its complete zero is known.
        model.expand(NodeID(2))
        #expect(await waitUntil { model.treemapScene?.expandedPages[NodeID(2)] != nil })
        #expect(model.listEffectiveBytes(for: directory) == 0)
        await model.shutdown()
    }

    private func twoChildPage() -> SnapshotChildPage {
        SnapshotChildPage(
            items: [
                appSupportChildItem(id: 2, name: "two", attributed: 0),
                appSupportChildItem(id: 3, name: "three", attributed: 0)
            ],
            totalCount: 2, snapshotRevision: Revision(5)
        )
    }

    private func waitUntilAsync(
        timeout: Double = 3,
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    @Test("A stale query that ignores cancellation never disturbs the new task or pending")
    func staleQueryDoesNotDisturbNewTask() async {
        let reader = StubSnapshotRepository()
        await reader.setPage(twoChildPage(), for: rootNodeID)
        await reader.setPage(
            SnapshotChildPage(items: [], totalCount: 0, snapshotRevision: Revision(5)),
            for: NodeID(2)
        )
        await reader.setPage(
            SnapshotChildPage(items: [], totalCount: 0, snapshotRevision: Revision(5)),
            for: NodeID(3)
        )
        await reader.setAggregate(aggregate(NodeID(2), attributed: 100, complete: true))
        await reader.setAggregate(aggregate(NodeID(3), attributed: 300, complete: true))
        let gate2 = DispatchSemaphore(value: 0)
        let gate3 = DispatchSemaphore(value: 0)
        await reader.setAggregateGate(gate2, for: NodeID(2))
        await reader.setAggregateGate(gate3, for: NodeID(3))

        let model = await makeModel(sceneReader: reader)
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene?.focusPage.items.count == 2 })

        // A starts for node 2 and blocks (a loader that ignores cancellation).
        model.selectNode(NodeID(2))
        #expect(await waitUntilAsync { await reader.aggregateCallsMade >= 1 })

        // Invalidate and select a different directory: B starts for node 3.
        model.clearSelection()
        model.selectNode(NodeID(3))
        #expect(await waitUntilAsync { await reader.aggregateCallsMade >= 2 })
        #expect(await reader.aggregatePeakConcurrency == 2)

        // Scene refreshes while B is in flight coalesce into one pending request.
        for _ in 0..<5 { model.reloadSceneForTesting() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Release stale A. It must not wipe B's handle or consume B's pending, so
        // exactly one query (B) stays in flight and no third query spawns.
        gate2.signal()
        #expect(await waitUntilAsync { await reader.aggregateActiveCalls == 1 })
        for _ in 0..<3 { model.reloadSceneForTesting() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(await reader.aggregateActiveCalls == 1)
        #expect(await reader.aggregatePeakConcurrency == 2)

        // Release B: its coalesced follow-up runs once, then the final value is B's.
        gate3.signal()
        try? await Task.sleep(nanoseconds: 150_000_000)
        gate3.signal()
        #expect(await waitUntil { model.selectedAggregate?.attributedBytes == 300 })
        #expect(await reader.aggregatePeakConcurrency == 2)
        await model.shutdown()
    }

    @Test("A completed parent establishes a real zero for an unexpanded child")
    func completedParentEstablishesZero() async {
        let reader = StubSnapshotRepository()
        await reader.setPage(
            SnapshotChildPage(
                items: [appSupportChildItem(id: 2, name: "empty", attributed: 0)],
                totalCount: 1, snapshotRevision: Revision(5),
                parentAggregate: aggregate(rootNodeID, attributed: 0, complete: true)
            ),
            for: rootNodeID
        )
        let model = await makeModel(sceneReader: reader)
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene?.focusPage.items.count == 1 })
        let child = model.treemapScene!.focusPage.items[0]
        #expect(model.treemapScene?.expandedPages[NodeID(2)] == nil)
        // The containing parent is complete, so the zero is final, not unknown.
        #expect(model.listEffectiveBytes(for: child) == 0)
        await model.shutdown()
    }

    @Test("An incomplete parent does not turn a zero child into a certain zero")
    func incompleteParentKeepsZeroUnknown() async {
        let reader = StubSnapshotRepository()
        await reader.setPage(
            SnapshotChildPage(
                items: [appSupportChildItem(id: 2, name: "empty", attributed: 0)],
                totalCount: 1, snapshotRevision: Revision(5),
                parentAggregate: aggregate(rootNodeID, attributed: 0, complete: false)
            ),
            for: rootNodeID
        )
        let model = await makeModel(sceneReader: reader)
        await model.chooseRoot()
        #expect(await waitUntil { model.treemapScene?.focusPage.items.count == 1 })
        let child = model.treemapScene!.focusPage.items[0]
        #expect(model.listEffectiveBytes(for: child) == nil)
        await model.shutdown()
    }
}
