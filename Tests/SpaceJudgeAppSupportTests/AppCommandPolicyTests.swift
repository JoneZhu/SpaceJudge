import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
@testable import SpaceJudgeAppSupport

@MainActor
@Suite("App command policy")
struct AppCommandPolicyTests {
    @Test("Idle enables choosing only")
    func idle() {
        let policy = AppCommandPolicy(phase: .idle, hasRoot: false, isShutDown: false)
        #expect(policy.canChooseRoot)
        #expect(!policy.canRescan)
        #expect(!policy.canCancel)
    }

    @Test("An open picker disables choosing but keeps it recoverable afterward")
    func choosingRoot() {
        let withRoot = AppCommandPolicy(phase: .choosingRoot, hasRoot: true, isShutDown: false)
        #expect(!withRoot.canChooseRoot)
        #expect(!withRoot.canCancel)
        // A previous root with no active scan is still rescan-able.
        #expect(withRoot.canRescan)

        let withoutRoot = AppCommandPolicy(phase: .choosingRoot, hasRoot: false, isShutDown: false)
        #expect(!withoutRoot.canChooseRoot)
        #expect(!withoutRoot.canRescan)
    }

    @Test("A root with no active scan enables rescan, not cancel")
    func readyWithRoot() {
        for phase in [AppPhase.ready, .completed, .cancelled, .permissionLimited, .failed] {
            let policy = AppCommandPolicy(phase: phase, hasRoot: true, isShutDown: false)
            #expect(policy.canRescan, "phase \(phase)")
            #expect(!policy.canCancel, "phase \(phase)")
            #expect(policy.canChooseRoot, "phase \(phase)")
        }
    }

    @Test("An active scan disables rescan, enables cancel, keeps choosing")
    func activeScan() {
        for phase in [AppPhase.preparing, .scanning, .cancelling] {
            let policy = AppCommandPolicy(phase: phase, hasRoot: true, isShutDown: false)
            #expect(!policy.canRescan, "phase \(phase)")
            #expect(policy.canCancel, "phase \(phase)")
            // Choosing stays available: chooseRoot cancels the live scan itself.
            #expect(policy.canChooseRoot, "phase \(phase)")
        }
    }

    @Test("Rescan needs a root")
    func rescanNeedsRoot() {
        let policy = AppCommandPolicy(phase: .completed, hasRoot: false, isShutDown: false)
        #expect(!policy.canRescan)
    }

    @Test("Shutdown disables everything")
    func shutdown() {
        for phase in AppPhase.allCases {
            let policy = AppCommandPolicy(phase: phase, hasRoot: true, isShutDown: true)
            #expect(!policy.canChooseRoot, "phase \(phase)")
            #expect(!policy.canRescan, "phase \(phase)")
            #expect(!policy.canCancel, "phase \(phase)")
        }
    }

    @Test("The pre-bootstrap policy disables every command")
    func unavailable() {
        #expect(!AppCommandPolicy.unavailable.canChooseRoot)
        #expect(!AppCommandPolicy.unavailable.canRescan)
        #expect(!AppCommandPolicy.unavailable.canCancel)
    }

    @Test("An idle live model enables choosing only")
    func idleModelPolicy() {
        let model = AppModel(
            engine: ScriptedScanEngine(scanID: appSupportScanID(), events: []),
            repository: StubSnapshotRepository(),
            reader: StubSnapshotRepository(),
            directoryAccess: TestDirectoryAccess(nextSelection: nil),
            shutdown: {}
        )
        #expect(model.commandPolicy == .idle)
        #expect(model.canChooseRoot)
        #expect(!model.canRescan)
        #expect(!model.canCancel)
    }

    @Test("The model policy follows root and scan lifecycle transitions")
    func modelTransitions() async {
        let scanID = appSupportScanID()
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID, rootNodeID: NodeID(1)))
            ],
            holdsOpen: true
        )
        let model = AppModel(
            engine: engine,
            repository: StubSnapshotRepository(),
            reader: StubSnapshotRepository(),
            directoryAccess: TestDirectoryAccess(
                nextSelection: DirectorySelection(
                    url: URL(fileURLWithPath: "/private/tmp/spacejudge-policy"),
                    displayName: "fixture"
                )
            ),
            sceneReader: StubSnapshotRepository(),
            shutdown: {}
        )

        #expect(model.commandPolicy == .idle)

        await model.chooseRoot()
        // Root adopted, scan active: rescan disabled, cancel/choose enabled.
        #expect(model.hasRoot)
        #expect(!model.canRescan)
        #expect(model.canCancel)
        #expect(model.canChooseRoot)

        await model.cancelScan()
        #expect(!model.isScanning)
        #expect(model.canRescan)
        #expect(!model.canCancel)
        #expect(model.canChooseRoot)

        await model.shutdown()
        #expect(!model.canChooseRoot)
        #expect(!model.canRescan)
        #expect(!model.canCancel)
    }

    @MainActor
    @Test("Observing a live model republishes policy changes")
    func observationRepublishes() async {
        let scanID = appSupportScanID()
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [.started(appSupportMetadata(scanID: scanID, rootNodeID: NodeID(1)))],
            holdsOpen: true
        )
        let model = AppModel(
            engine: engine,
            repository: StubSnapshotRepository(),
            reader: StubSnapshotRepository(),
            directoryAccess: TestDirectoryAccess(
                nextSelection: DirectorySelection(
                    url: URL(fileURLWithPath: "/private/tmp/spacejudge-observe"),
                    displayName: "fixture"
                )
            ),
            sceneReader: StubSnapshotRepository(),
            shutdown: {}
        )

        let recorder = PolicyRecorder()
        model.observeCommandPolicy { policy in
            recorder.values.append(policy)
        }

        await model.chooseRoot()
        // The observation must deliver the active-scan policy.
        #expect(await waitUntil { recorder.values.contains { $0.canCancel && !$0.canRescan } })

        await model.cancelScan()
        #expect(await waitUntil { recorder.values.contains { $0.canRescan && !$0.canCancel } })

        await model.shutdown()
    }

    @MainActor
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
}

@MainActor
private final class PolicyRecorder {
    var values: [AppCommandPolicy] = []
}
