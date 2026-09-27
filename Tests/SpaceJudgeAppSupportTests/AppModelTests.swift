import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeUseCases
@testable import SpaceJudgeAppSupport

@MainActor
@Suite("App model", .serialized)
struct AppModelTests {
    private let scanID = appSupportScanID()
    private let rootNodeID = NodeID(1)
    private let fixtureURL = URL(fileURLWithPath: "/private/tmp/spacejudge-fixture")

    private func makeSelection(name: String = "fixture") -> DirectorySelection {
        DirectorySelection(url: fixtureURL, displayName: name)
    }

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

    private func makeModel(
        engine: any ScanEngine,
        repository: StubSnapshotRepository,
        reader: StubSnapshotRepository,
        access: any DirectoryAccess,
        shutdown: CallCounter,
        sceneReader: StubSnapshotRepository = StubSnapshotRepository()
    ) -> AppModel {
        AppModel(
            engine: engine,
            repository: repository,
            reader: reader,
            directoryAccess: access,
            sceneReader: sceneReader,
            shutdown: { shutdown.increment() }
        )
    }

    @Test("Choosing a root scans, completes and loads a bounded child page")
    func happyPath() async {
        let volume = VolumeFacts(
            totalCapacityBytes: 512_000_000_000,
            availableCapacityBytes: 99_400_000_000,
            capacitySource: .importantUsage
        )
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID, volume: volume)),
                .batch(NodeBatch(scanID: scanID, revision: Revision(1), nodes: [])),
                .progress(
                    ScanProgress(
                        revision: Revision(1), status: .running, fileCount: 10,
                        directoryCount: 2, attributedBytes: 1000, pendingDirectories: 1,
                        entriesPerSecond: 123_456, elapsedSeconds: 0.5
                    )
                ),
                .completed(appSupportSummary(scanID: scanID, status: .completed, volume: volume))
            ]
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        await reader.setPage(
            SnapshotChildPage(
                items: [appSupportChildItem(id: 2, name: "Users", attributed: 312_600_000_000)],
                totalCount: 1
            ),
            for: rootNodeID
        )
        let access = TestDirectoryAccess(nextSelection: makeSelection())
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )

        await model.chooseRoot()
        await model.waitForScanToFinish()
        #expect(await waitUntil { model.childPage != nil })

        #expect(model.phase == .completed)
        #expect(model.scanID == scanID)
        #expect(model.rootNodeID == rootNodeID)
        #expect(model.rootDisplayName == "fixture")
        #expect(model.volume == volume)
        #expect(model.capacityLine.contains("总容量"))
        #expect(model.childPage?.items.count == 1)
        #expect(model.issueCount == 0)
        #expect(!model.permissionLimited)
        #expect(access.started == [fixtureURL])
        let limits = await reader.recordedLimits
        #expect(!limits.isEmpty)
        #expect(limits.allSatisfy { $0 == 100 })
        #expect(await repository.calls.contains(.finish(.completed)))

        await model.shutdown()
        #expect(shutdown.count == 1)
        #expect(access.stopped == [fixtureURL])
        await model.shutdown()
        #expect(shutdown.count == 1)
    }

    @Test("Cancelling the picker keeps the empty state and starts nothing")
    func pickerCancelled() async {
        let engine = ScriptedScanEngine(scanID: scanID, events: [])
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let access = TestDirectoryAccess(nextSelection: nil)
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )

        await model.chooseRoot()
        #expect(model.phase == .idle)
        #expect(model.rootDisplayName == nil)
        #expect(access.started.isEmpty)
        #expect(await repository.calls.isEmpty)
    }

    @Test("Cancelling the picker after a failed root keeps .failed and its error")
    func pickerCancellationAfterFailure() async {
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [],
            finishError: ScanError.rootOpenFailed(errno: ENOENT)
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let access = TestDirectoryAccess(nextSelection: makeSelection())
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )
        await model.chooseRoot()
        await model.waitForScanToFinish()
        #expect(await waitUntil { model.phase == .failed })
        #expect(model.userError == .rootUnavailable)
        #expect(model.rootDisplayName == "fixture")

        let startedBefore = access.started
        access.setNextSelection(nil)
        await model.chooseRoot()

        // The captured stable phase was .failed; cancelling must restore it and
        // must not clear the path-free error or start a new scan/scope.
        #expect(model.phase == .failed)
        #expect(model.userError == .rootUnavailable)
        #expect(!(model.userError?.message.contains("/") ?? true))
        #expect(access.started == startedBefore)
        #expect(access.stopped.isEmpty)
        await model.shutdown()
    }

    @Test("Cancelling the picker after a completed scan keeps .completed")
    func pickerCancellationAfterCompletion() async {
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID)),
                .completed(appSupportSummary(scanID: scanID, status: .completed))
            ]
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let access = TestDirectoryAccess(nextSelection: makeSelection())
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )
        await model.chooseRoot()
        await model.waitForScanToFinish()
        #expect(await waitUntil { model.phase == .completed })

        access.setNextSelection(nil)
        await model.chooseRoot()
        #expect(model.phase == .completed)
        #expect(model.summary?.status == .completed)
        #expect(access.started == [fixtureURL])
        await model.shutdown()
    }

    @Test("A second chooseRoot while the picker is open is a no-op")
    func reentrantPickerIsNoOp() async {
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID)),
                .completed(appSupportSummary(scanID: scanID, status: .completed))
            ]
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let access = SuspendingDirectoryAccess()
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )

        let first = Task { await model.chooseRoot() }
        #expect(await waitUntil { access.pickCallCount == 1 })
        #expect(model.phase == .choosingRoot)

        // Re-entrant call must not launch a second picker or mutate the first
        // call's captured phase.
        await model.chooseRoot()
        #expect(access.pickCallCount == 1)
        #expect(model.phase == .choosingRoot)

        access.resolve(makeSelection())
        await first.value
        #expect(await waitUntil { model.phase == .completed })
        #expect(access.pickCallCount == 1)
        #expect(access.startedURLs == [fixtureURL])
        await model.shutdown()
    }

    @Test("A chosen root auto-starts a scan and starts no scan at launch")
    func noAutoScanAtLaunch() async {
        let engine = ScriptedScanEngine(scanID: scanID, events: [])
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let access = TestDirectoryAccess(nextSelection: nil)
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )
        #expect(model.phase == .idle)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.phase == .idle)
        #expect(await repository.calls.isEmpty)
    }

    @Test("User cancellation preserves the cancelled snapshot and the scope")
    func userCancellation() async {
        let cancelled = appSupportSummary(scanID: scanID, status: .cancelled)
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID)),
                .batch(NodeBatch(scanID: scanID, revision: Revision(1), nodes: []))
            ],
            holdsOpen: true,
            terminalOnCancel: cancelled
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let access = TestDirectoryAccess(nextSelection: makeSelection())
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )

        await model.chooseRoot()
        #expect(await waitUntil { model.phase == .scanning })
        await model.cancelScan()

        #expect(model.phase == .cancelled)
        #expect(model.summary?.status == .cancelled)
        #expect(engine.cancelledScanIDs.contains(scanID))
        #expect(await repository.calls.contains(.finish(.cancelled)))
        // Results stay browsable, so the security scope is intentionally kept.
        #expect(access.stopped.isEmpty)

        await model.shutdown()
        #expect(access.stopped == [fixtureURL])
    }

    @Test("Permission issues surface as permissionLimited, not as failure")
    func permissionLimitedFromIssues() async {
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID)),
                .issue(ScanIssue(scanID: scanID, category: .permissionDenied, errnoValue: EACCES, count: 3)),
                .completed(appSupportSummary(scanID: scanID, status: .completed))
            ]
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        await reader.setIssues([
            IssueAggregateSummary(category: .permissionDenied, errnoValue: EACCES, sampleNameID: nil, count: 3)
        ])
        let access = TestDirectoryAccess(nextSelection: makeSelection())
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )

        await model.chooseRoot()
        await model.waitForScanToFinish()
        #expect(await waitUntil { model.permissionLimited })
        #expect(model.phase == .permissionLimited)
        #expect(model.userError == nil)
        #expect(model.showsPermissionHelp)
        await model.shutdown()
    }

    @Test("A root EACCES failure becomes permissionLimited with a path-free message")
    func rootPermissionError() async {
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [],
            finishError: ScanError.rootOpenFailed(errno: EACCES)
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let access = TestDirectoryAccess(nextSelection: makeSelection(name: "Secret"))
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )

        await model.chooseRoot()
        await model.waitForScanToFinish()
        #expect(await waitUntil { model.phase == .permissionLimited })
        #expect(model.permissionLimited)
        #expect(model.userError == .rootPermissionDenied)
        let message = model.userError?.message ?? ""
        #expect(!message.contains("/"))
        #expect(message.contains("完全磁盘访问权限"))
        await model.shutdown()
    }

    @Test("A non-permission fatal root error becomes failed")
    func rootFatalError() async {
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [],
            finishError: ScanError.rootOpenFailed(errno: ENOENT)
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let access = TestDirectoryAccess(nextSelection: makeSelection())
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )
        await model.chooseRoot()
        await model.waitForScanToFinish()
        #expect(await waitUntil { model.phase == .failed })
        #expect(model.userError == .rootUnavailable)
        #expect(!model.permissionLimited)
        await model.shutdown()
    }

    @Test("Replacing the root stops the old scope before starting the new one")
    func scopePairingAcrossReplacements() async {
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID)),
                .completed(appSupportSummary(scanID: scanID, status: .completed))
            ]
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let first = URL(fileURLWithPath: "/private/tmp/first")
        let second = URL(fileURLWithPath: "/private/tmp/second")
        let access = TestDirectoryAccess(nextSelection: DirectorySelection(url: first, displayName: "first"))
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )

        await model.chooseRoot()
        await model.waitForScanToFinish()
        access.setNextSelection(DirectorySelection(url: second, displayName: "second"))
        await model.chooseRoot()
        await model.waitForScanToFinish()

        #expect(access.started == [first, second])
        #expect(access.stopped == [first])

        await model.shutdown()
        #expect(access.stopped == [first, second])
    }

    @Test("A failed start access is never stopped later")
    func failedStartIsNotStopped() async {
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID)),
                .completed(appSupportSummary(scanID: scanID, status: .completed))
            ]
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let access = TestDirectoryAccess(
            nextSelection: makeSelection(),
            startResult: false
        )
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )
        await model.chooseRoot()
        await model.waitForScanToFinish()
        await model.shutdown()
        #expect(access.stopped.isEmpty)
    }

    @Test("Stale refresh generations are rejected")
    func staleGenerationRejected() async {
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID)),
                .completed(appSupportSummary(scanID: scanID, status: .completed))
            ]
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let access = TestDirectoryAccess(nextSelection: makeSelection())
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )
        await model.chooseRoot()
        await model.waitForScanToFinish()
        let generation = model.refreshGenerationForTesting
        #expect(model.acceptsRefresh(generation: generation))

        access.setNextSelection(makeSelection(name: "again"))
        await model.chooseRoot()
        await model.waitForScanToFinish()
        #expect(!model.acceptsRefresh(generation: generation))
        #expect(model.acceptsRefresh(generation: model.refreshGenerationForTesting))
        await model.shutdown()
    }

    @Test("Shutdown cancels an active scan, releases scope and closes repositories")
    func shutdownCancelsActiveScan() async {
        let cancelled = appSupportSummary(scanID: scanID, status: .cancelled)
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID)),
                .batch(NodeBatch(scanID: scanID, revision: Revision(1), nodes: []))
            ],
            holdsOpen: true,
            terminalOnCancel: cancelled
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let access = TestDirectoryAccess(nextSelection: makeSelection())
        let shutdown = CallCounter()
        let model = makeModel(
            engine: engine, repository: repository, reader: reader,
            access: access, shutdown: shutdown
        )
        await model.chooseRoot()
        #expect(await waitUntil { model.phase == .scanning })

        await model.shutdown()
        #expect(engine.cancelledScanIDs.contains(scanID))
        #expect(!model.isScanning)
        #expect(access.stopped == [fixtureURL])
        #expect(shutdown.count == 1)
    }

    @Test("Byte formatting shows unknown as an em dash, never as zero")
    func byteFormatting() {
        #expect(ByteFormatting.bytes(nil as UInt64?) == "—")
        #expect(ByteFormatting.bytes(UInt64(0)) == "0 B")
        #expect(ByteFormatting.bytes(UInt64(1)) != "—")
        let unknown = ByteFormatting.capacityLine(
            VolumeFacts(totalCapacityBytes: nil, availableCapacityBytes: nil, capacitySource: .unavailable)
        )
        #expect(unknown.contains("—"))
        #expect(!unknown.contains("0 B"))
    }
}
