import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeUseCases
@testable import SpaceJudgeAppSupport

@Suite("Phase 5C app errors and request wiring", .serialized)
@MainActor
struct Phase5CAppTests {
    private let fixtureURL = URL(fileURLWithPath: "/private/tmp/spacejudge-fixture")

    private func waitUntil(
        timeout: Double = 3,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
    }

    @Test("Insufficient storage maps to a path-free message")
    func insufficientStorageMessage() {
        let classified = AppUserError.classify(
            SnapshotStoreError.insufficientStorage(requiredBytes: 512, availableBytes: 1)
        )
        #expect(classified == .insufficientStorage)
        #expect(classified.message == "可用空间过少，SpaceJudge 已停止写入扫描缓存。请先释放少量磁盘空间后重试。")
        #expect(!classified.message.contains("/"))
    }

    @Test("A selected workspace root maps to a path-free message")
    func workspaceRootMessage() {
        let classified = AppUserError.classify(ScanError.scanRootInsideSnapshotWorkspace)
        #expect(classified == .scanRootInsideSnapshotWorkspace)
        #expect(classified.message == "不能扫描 SpaceJudge 自己的工作缓存，请选择其他位置。")
        #expect(!classified.message.contains("/"))
    }

    @Test("Unknown capacity maps to the insufficient-storage message")
    func unknownCapacityMessage() {
        #expect(
            AppUserError.classify(SnapshotStoreError.storageCapacityUnavailable)
                == .insufficientStorage
        )
        #expect(
            AppUserError.classify(
                SnapshotStoreError.sqlite(code: 13, message: "disk full")
            ) == .insufficientStorage
        )
    }

    @Test("The model carries workspace exclusions into the scan request")
    func requestCarriesExclusions() async {
        let scanID = appSupportScanID()
        let fixtureURL = URL(fileURLWithPath: "/private/tmp/spacejudge-fixture")
        let exclusion = SnapshotWorkspaceExclusion(
            path: "/private/tmp/spacejudge-workspace",
            deviceID: 3,
            fileID: 4
        )
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
            nextSelection: DirectorySelection(url: fixtureURL, displayName: "fixture")
        )
        let model = AppModel(
            engine: engine,
            repository: repository,
            reader: reader,
            directoryAccess: access,
            workspaceExclusions: [exclusion],
            shutdown: {}
        )

        await model.chooseRoot()
        await model.waitForScanToFinish()

        #expect(engine.recordedRequests.first?.workspaceExclusions == [exclusion])
        await model.shutdown()
    }

    @Test("A forced cancel after an unresponsive engine stays cancelled with no error")
    func forcedCancelStaysCancelled() async {
        let scanID = appSupportScanID()
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID)),
                .batch(NodeBatch(scanID: scanID, revision: Revision(1), nodes: []))
            ],
            holdsOpen: true,
            terminalOnCancel: nil
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let access = TestDirectoryAccess(
            nextSelection: DirectorySelection(url: fixtureURL, displayName: "fixture")
        )
        let model = AppModel(
            engine: engine,
            repository: repository,
            reader: reader,
            directoryAccess: access,
            cancelGracePeriod: 0.15,
            shutdown: {}
        )

        await model.chooseRoot()
        #expect(await waitUntil { model.phase == .scanning })
        await model.cancelScan()

        #expect(model.phase == .cancelled)
        #expect(model.summary?.status == .cancelled)
        #expect(model.userError == nil)
        #expect(await repository.calls.contains(.finish(.cancelled)))
        let recordedFailure = await repository.calls.contains { call in
            if case .fail = call { return true }
            return false
        }
        #expect(!recordedFailure)
        await model.shutdown()
    }

    @Test("A storage failure still surfaces a path-free scan error")
    func storageFailureSurfacesScanError() async {
        let scanID = appSupportScanID()
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [.started(appSupportMetadata(scanID: scanID))],
            finishError: SnapshotStoreError.insufficientStorage(
                requiredBytes: 512,
                availableBytes: 1
            )
        )
        let repository = StubSnapshotRepository()
        let reader = StubSnapshotRepository()
        let access = TestDirectoryAccess(
            nextSelection: DirectorySelection(url: fixtureURL, displayName: "fixture")
        )
        let model = AppModel(
            engine: engine,
            repository: repository,
            reader: reader,
            directoryAccess: access,
            cancelGracePeriod: 0.15,
            shutdown: {}
        )

        await model.chooseRoot()
        await model.waitForScanToFinish()

        #expect(model.phase == .failed)
        #expect(model.userError == .insufficientStorage)
        #expect(model.userError?.message.contains("/") == false)
        await model.shutdown()
    }
}
