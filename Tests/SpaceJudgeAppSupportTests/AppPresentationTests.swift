import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeTreemap
@testable import SpaceJudgeAppSupport

@Suite("App presentation state")
struct AppPresentationTests {
    private let scanID = ScanID(
        rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    )

    private func scene(items: [TreemapSceneItem], omitted: UInt64 = 0) -> TreemapSceneData {
        let page = TreemapScenePage(
            parentID: NodeID(1),
            items: items,
            totalCount: UInt64(items.count),
            snapshotRevision: Revision(3),
            omittedCount: omitted,
            omittedWeight: omitted > 0 ? 0 : nil,
            aggregate: nil
        )
        return TreemapSceneData(
            scanID: scanID,
            scanGeneration: 1,
            revision: Revision(3),
            focusNodeID: NodeID(1),
            focusName: "root",
            focusKind: .directory,
            focusAggregate: nil,
            focusPage: page,
            expandedPages: [:],
            expansionOrder: [],
            expansionVersion: 0,
            detailMode: .overview,
            isTerminal: true,
            rootDisplayName: "root"
        )
    }

    private func item(id: UInt64, bytes: UInt64) -> TreemapSceneItem {
        TreemapSceneItem(
            nodeID: NodeID(id),
            name: "n\(id)",
            kind: .directory,
            flags: [],
            effectiveBytes: bytes,
            modifiedAt: nil,
            logicalBytes: nil,
            allocatedBytes: nil
        )
    }

    private func resolve(
        _ phase: AppPhase,
        progress: ScanProgress? = nil,
        scene: TreemapSceneData? = nil,
        sceneError: Bool = false,
        attribution: UInt64 = 0
    ) -> AppPresentationState {
        AppPresentationState.resolve(
            phase: phase,
            progress: progress,
            scene: scene,
            sceneError: sceneError,
            attribution: attribution
        )
    }

    @Test("Lifecycle phases map to the expected presentation states")
    func lifecycle() {
        #expect(resolve(.idle) == .idle)
        #expect(resolve(.ready) == .idle)
        #expect(resolve(.choosingRoot) == .choosingRoot)
        #expect(resolve(.failed) == .failed)
        #expect(resolve(.preparing) == .preparing)
        #expect(resolve(.cancelling) == .cancelling)
        #expect(resolve(.cancelled) == .cancelled)
        #expect(resolve(.scanning) == .awaitingFirstBatch)
    }

    @Test("A scan with counting progress is scanning")
    func scanningWithProgress() {
        let progress = ScanProgress(
            revision: Revision(1),
            status: .running,
            fileCount: 10,
            directoryCount: 2,
            attributedBytes: 1_024,
            pendingDirectories: 1,
            entriesPerSecond: 100,
            elapsedSeconds: 0.1
        )
        #expect(resolve(.scanning, progress: progress) == .scanning)
    }

    @Test("An empty focus is empty scope, not generic completion")
    func emptyScope() {
        #expect(resolve(.completed, scene: scene(items: []), attribution: 0) == .emptyScope)
    }

    @Test("Zero-weight children surface zero allocation without invented area")
    func zeroAllocation() {
        let value = resolve(
            .completed,
            scene: scene(items: [item(id: 2, bytes: 0), item(id: 3, bytes: 0)]),
            attribution: 0
        )
        #expect(value == .zeroAllocation)
    }

    @Test("A failed fresh read with a retained map is a scene error")
    func sceneError() {
        let value = resolve(
            .completed,
            scene: scene(items: [item(id: 2, bytes: 10)]),
            sceneError: true,
            attribution: 10
        )
        #expect(value == .sceneError)
        #expect(value.explanation != nil)
    }

    @Test("A scene error never claims an old map exists")
    func sceneErrorWording() {
        // Honest for both a first read (scene == nil) and a failed refresh.
        let explanation = AppPresentationState.sceneError.explanation
        #expect(explanation?.isEmpty == false)
        #expect(explanation?.contains("上一版") == false)
        #expect(explanation?.contains("重试") == true)
    }

    @Test("Non-empty content resolves to completed")
    func completed() {
        let value = resolve(
            .completed,
            scene: scene(items: [item(id: 2, bytes: 10)]),
            attribution: 10
        )
        #expect(value == .completed)
    }

    @Test("Busy states are the only ones that allow cancel")
    func busyStates() {
        #expect(resolve(.preparing).isBusy)
        #expect(resolve(.scanning).isBusy)
        #expect(resolve(.cancelling).isBusy)
        #expect(!resolve(.completed).isBusy)
        #expect(!resolve(.cancelled).isBusy)
        #expect(!resolve(.idle).isBusy)
    }

    @Test("Unknown capacity renders em dashes and draws no bar")
    func unknownCapacity() {
        let presentation = CapacityPresentation(volume: nil)
        #expect(presentation.totalBytes == nil)
        #expect(presentation.usedBytes == nil)
        #expect(presentation.usedFraction == nil)
        #expect(presentation.line.contains("—"))
        #expect(presentation.sourceLabel == "容量未知")
    }

    @Test("Important usage is labelled and produces a bounded used fraction")
    func importantCapacity() {
        let volume = VolumeFacts(
            totalCapacityBytes: 1000,
            availableCapacityBytes: 250,
            capacitySource: .importantUsage
        )
        let presentation = CapacityPresentation(volume: volume)
        #expect(presentation.usedBytes == 750)
        #expect(presentation.usedFraction == 0.75)
        #expect(presentation.sourceLabel == "重要用途可用")
        #expect(presentation.accessibilityLabel.contains("重要用途"))
    }

    @Test("A statfs/standard fallback is labelled and never confused with important usage")
    func standardFallbackCapacity() {
        let volume = VolumeFacts(
            totalCapacityBytes: 1000,
            availableCapacityBytes: 900,
            capacitySource: .standardAvailable
        )
        let presentation = CapacityPresentation(volume: volume)
        #expect(presentation.sourceLabel == "普通可用（含 statfs 回退）")
        #expect(presentation.usedFraction == 0.1)
    }

    @Test("A zero total never produces a NaN or infinite fraction")
    func zeroTotalCapacity() {
        let volume = VolumeFacts(
            totalCapacityBytes: 0,
            availableCapacityBytes: 0,
            capacitySource: .importantUsage
        )
        let presentation = CapacityPresentation(volume: volume)
        #expect(presentation.usedFraction == nil)
    }
}
