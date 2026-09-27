import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
@testable import SpaceJudgeAppSupport

// MARK: - Doubles

/// Facts provider that returns a fixed value, so plan resolution is tested
/// without depending on the real machine's volume topology.
struct StubPlanFactsProvider: VolumePlanFactsProviding {
    let value: VolumePlanFacts

    func facts(for url: URL) -> VolumePlanFacts { value }
}

/// Planner double that records how many times a plan was resolved.
final class CountingVolumeScanPlanner: VolumeScanPlanning, @unchecked Sendable {
    private let lock = NSLock()
    private var planValue: VolumeScanPlan
    private var calls = 0

    init(_ plan: VolumeScanPlan) {
        self.planValue = plan
    }

    func setPlan(_ plan: VolumeScanPlan) {
        lock.lock()
        planValue = plan
        lock.unlock()
    }

    func plan(for selection: DirectorySelection) -> VolumeScanPlan {
        lock.lock()
        calls += 1
        let value = planValue
        lock.unlock()
        // Rebind the session root to the selection; keep the resolved decision.
        return VolumeScanPlan(
            kind: value.kind,
            root: ScanRoot(
                fileSystemPath: selection.fileSystemPath,
                displayName: selection.displayName
            ),
            boundaryPolicy: value.boundaryPolicy,
            evidence: value.evidence
        )
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private func visiblePlan(for selection: DirectorySelection) -> VolumeScanPlan {
    VolumeScanPlan(
        kind: .visibleStartupVolumeGroup,
        root: ScanRoot(
            fileSystemPath: selection.fileSystemPath,
            displayName: selection.displayName
        ),
        boundaryPolicy: .visibleStartupVolumeGroup,
        evidence: VolumeScanPlanEvidence(
            isVolume: true,
            isRootFileSystem: true,
            fileSystemType: "apfs",
            source: .foundationResourceValues
        )
    )
}

private func fallbackPlan(for selection: DirectorySelection) -> VolumeScanPlan {
    VolumeScanPlan(
        kind: .selectedFileSystem,
        root: ScanRoot(
            fileSystemPath: selection.fileSystemPath,
            displayName: selection.displayName
        ),
        boundaryPolicy: .stayOnRootFileSystem,
        evidence: .unknown
    )
}

// MARK: - Plan resolution

@Suite("Volume scan plan resolution")
struct VolumeScanPlanResolutionTests {
    private func resolve(_ facts: VolumePlanFacts) -> VolumeScanPlan {
        VolumeScanPlanResolver.resolve(
            root: ScanRoot(fileSystemPath: "/tmp/secret-path", displayName: "disk"),
            facts: facts
        )
    }

    @Test("APFS volume root of the root file system selects the visible group")
    func visibleGroup() {
        let plan = resolve(
            VolumePlanFacts(
                isVolume: true,
                isRootFileSystem: true,
                fileSystemType: "apfs"
            )
        )
        #expect(plan.kind == .visibleStartupVolumeGroup)
        #expect(plan.boundaryPolicy == .visibleStartupVolumeGroup)
        #expect(plan.evidence.source == .foundationResourceValues)
    }

    @Test("APFS type matching is case-insensitive")
    func caseInsensitiveAPFS() {
        #expect(
            resolve(VolumePlanFacts(isVolume: true, isRootFileSystem: true, fileSystemType: "APFS"))
                .kind == .visibleStartupVolumeGroup
        )
    }

    @Test("An APFS external volume stays on the selected file system")
    func externalVolume() {
        let plan = resolve(
            VolumePlanFacts(isVolume: true, isRootFileSystem: false, fileSystemType: "apfs")
        )
        #expect(plan.kind == .selectedFileSystem)
        #expect(plan.boundaryPolicy == .stayOnRootFileSystem)
    }

    @Test("An APFS ordinary directory stays on the selected file system")
    func ordinaryDirectory() {
        // A directory on the root volume reports the root filesystem but is not
        // itself a volume root.
        let plan = resolve(
            VolumePlanFacts(isVolume: false, isRootFileSystem: true, fileSystemType: "apfs")
        )
        #expect(plan.kind == .selectedFileSystem)
    }

    @Test("A non-APFS volume root stays on the selected file system")
    func nonAPFS() {
        let plan = resolve(
            VolumePlanFacts(isVolume: true, isRootFileSystem: true, fileSystemType: "hfs")
        )
        #expect(plan.kind == .selectedFileSystem)
    }

    @Test("Any unknown fact degrades safely")
    func unknownFacts() {
        for facts in [
            VolumePlanFacts(isVolume: nil, isRootFileSystem: true, fileSystemType: "apfs"),
            VolumePlanFacts(isVolume: true, isRootFileSystem: nil, fileSystemType: "apfs"),
            VolumePlanFacts(isVolume: true, isRootFileSystem: true, fileSystemType: nil)
        ] {
            let plan = resolve(facts)
            #expect(plan.kind == .selectedFileSystem)
            #expect(plan.boundaryPolicy == .stayOnRootFileSystem)
        }
    }

    @Test("A failed query degrades with unavailable evidence")
    func failedQuery() {
        let plan = resolve(
            VolumePlanFacts(
                isVolume: nil,
                isRootFileSystem: nil,
                fileSystemType: nil,
                queryFailed: true
            )
        )
        #expect(plan.kind == .selectedFileSystem)
        #expect(plan.evidence.source == .unavailable)
        #expect(plan.evidence.isVolume == nil)
    }

    @Test("The Foundation planner consults the injected provider")
    func foundationPlannerUsesProvider() {
        let planner = FoundationVolumeScanPlanner(
            factsProvider: StubPlanFactsProvider(
                value: VolumePlanFacts(
                    isVolume: true,
                    isRootFileSystem: true,
                    fileSystemType: "apfs"
                )
            )
        )
        let plan = planner.plan(
            for: DirectorySelection(url: URL(fileURLWithPath: "/anything"))
        )
        #expect(plan.kind == .visibleStartupVolumeGroup)
    }
}

// MARK: - AppModel wiring

@MainActor
@Suite("App model volume plan", .serialized)
struct AppModelVolumePlanTests {
    private let scanID = appSupportScanID()
    private let rootNodeID = NodeID(1)
    private let fixtureURL = URL(fileURLWithPath: "/private/tmp/spacejudge-plan")

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

    private func makeEngine() -> ScriptedScanEngine {
        ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID)),
                .completed(appSupportSummary(scanID: scanID, status: .completed))
            ]
        )
    }

    private func makeModel(
        engine: ScriptedScanEngine,
        planner: CountingVolumeScanPlanner,
        access: TestDirectoryAccess,
        shutdown: CallCounter = CallCounter()
    ) -> AppModel {
        AppModel(
            engine: engine,
            repository: StubSnapshotRepository(),
            reader: StubSnapshotRepository(),
            directoryAccess: access,
            planner: planner,
            sceneReader: StubSnapshotRepository(),
            shutdown: { shutdown.increment() }
        )
    }

    @Test("The plan boundary policy reaches the scan request")
    func planPolicyReachesRequest() async {
        let engine = makeEngine()
        let planner = CountingVolumeScanPlanner(visiblePlan(for: makeSelection()))
        let access = TestDirectoryAccess(nextSelection: makeSelection())
        let model = makeModel(engine: engine, planner: planner, access: access)

        await model.chooseRoot()
        await model.waitForScanToFinish()

        #expect(model.volumePlan?.kind == .visibleStartupVolumeGroup)
        #expect(engine.recordedRequests.first?.boundaryPolicy == .visibleStartupVolumeGroup)
        #expect(planner.callCount == 1)
        await model.shutdown()
    }

    @Test("A rescan reuses the resolved plan without re-querying")
    func rescanReusesPlan() async {
        let engine = makeEngine()
        let planner = CountingVolumeScanPlanner(visiblePlan(for: makeSelection()))
        let access = TestDirectoryAccess(nextSelection: makeSelection())
        let model = makeModel(engine: engine, planner: planner, access: access)

        await model.chooseRoot()
        await model.waitForScanToFinish()
        await model.rescan()
        await model.waitForScanToFinish()

        #expect(planner.callCount == 1)
        #expect(engine.recordedRequests.count == 2)
        #expect(engine.recordedRequests.allSatisfy {
            $0.boundaryPolicy == .visibleStartupVolumeGroup
        })
        await model.shutdown()
    }

    @Test("A new selection overrides the previous plan")
    func newSelectionOverridesPlan() async {
        let engine = makeEngine()
        let planner = CountingVolumeScanPlanner(visiblePlan(for: makeSelection()))
        let access = TestDirectoryAccess(nextSelection: makeSelection())
        let model = makeModel(engine: engine, planner: planner, access: access)

        await model.chooseRoot()
        await model.waitForScanToFinish()
        #expect(model.volumePlan?.kind == .visibleStartupVolumeGroup)

        planner.setPlan(fallbackPlan(for: makeSelection()))
        let second = URL(fileURLWithPath: "/private/tmp/spacejudge-plan-2")
        access.setNextSelection(DirectorySelection(url: second, displayName: "second"))
        await model.chooseRoot()
        await model.waitForScanToFinish()

        #expect(planner.callCount == 2)
        #expect(model.volumePlan?.kind == .selectedFileSystem)
        #expect(
            engine.recordedRequests.last?.boundaryPolicy == .stayOnRootFileSystem
        )
        await model.shutdown()
    }

    @Test("Cancelling the picker preserves the previous plan")
    func pickerCancelPreservesPlan() async {
        let engine = makeEngine()
        let planner = CountingVolumeScanPlanner(visiblePlan(for: makeSelection()))
        let access = TestDirectoryAccess(nextSelection: makeSelection())
        let model = makeModel(engine: engine, planner: planner, access: access)

        await model.chooseRoot()
        await model.waitForScanToFinish()
        let before = model.volumePlan

        access.setNextSelection(nil)
        await model.chooseRoot()

        #expect(model.volumePlan == before)
        #expect(planner.callCount == 1)
        await model.shutdown()
    }

    @Test("Shutdown clears the plan")
    func shutdownClearsPlan() async {
        let engine = makeEngine()
        let planner = CountingVolumeScanPlanner(visiblePlan(for: makeSelection()))
        let access = TestDirectoryAccess(nextSelection: makeSelection())
        let model = makeModel(engine: engine, planner: planner, access: access)

        await model.chooseRoot()
        await model.waitForScanToFinish()
        #expect(model.volumePlan != nil)

        await model.shutdown()
        #expect(model.volumePlan == nil)
    }
}
