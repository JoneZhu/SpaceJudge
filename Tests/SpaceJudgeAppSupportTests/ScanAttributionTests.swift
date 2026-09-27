import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeUseCases
@testable import SpaceJudgeAppSupport

@Suite("Scan attribution formatting")
struct ScanAttributionFormattingTests {
    private func volume(total: UInt64?, available: UInt64?) -> VolumeFacts {
        VolumeFacts(
            totalCapacityBytes: total,
            availableCapacityBytes: available,
            capacitySource: total == nil ? .unavailable : .importantUsage
        )
    }

    @Test("Nil state produces no line")
    func nilState() {
        #expect(ByteFormatting.attributionLine(nil, volume: nil) == nil)
    }

    @Test("Scanning shows the best-known attributed value")
    func scanning() {
        let line = ByteFormatting.attributionLine(
            .scanning(attributedBytes: 18_200_000_000),
            volume: volume(total: 500_000_000_000, available: 100_000_000_000)
        )
        #expect(line?.hasPrefix("已扫描并归属 ") == true)
        #expect(line?.contains("已扫描并归属 \(ByteFormatting.bytes(18_200_000_000))") == true)
    }

    @Test("Completed with used greater than attributed shows the neutral remainder")
    func completedUnder() {
        let line = ByteFormatting.attributionLine(
            .terminal(attributedBytes: 312_600_000_000, isComplete: true),
            volume: volume(total: 500_000_000_000, available: 87_400_000_000)
        )
        #expect(line?.contains("当前范围 \(ByteFormatting.bytes(312_600_000_000))") == true)
        #expect(line?.contains("卷内其他/未纳入 \(ByteFormatting.bytes(100_000_000_000))") == true)
        #expect(line?.contains("未完成") == false)
    }

    @Test("Completed with equal values shows a genuine zero remainder")
    func completedEqual() {
        let line = ByteFormatting.attributionLine(
            .terminal(attributedBytes: 4_096, isComplete: true),
            volume: volume(total: 500_000_000_000, available: 499_999_995_904)
        )
        #expect(line?.contains("卷内其他/未纳入 0 B") == true)
    }

    @Test("Completed with unknown used shows only the current scope")
    func completedUnknownUsed() {
        let line = ByteFormatting.attributionLine(
            .terminal(attributedBytes: 4_096, isComplete: true),
            volume: volume(total: nil, available: nil)
        )
        #expect(line == "当前范围 \(ByteFormatting.bytes(4_096))")
        #expect(line?.contains("卷内其他") == false)
    }

    @Test("Cancelled marks the scope as unfinished")
    func cancelled() {
        let line = ByteFormatting.attributionLine(
            .terminal(attributedBytes: 18_200_000_000, isComplete: false),
            volume: volume(total: 500_000_000_000, available: 87_400_000_000)
        )
        #expect(line?.contains("当前范围（未完成）") == true)
        #expect(line?.contains("卷内其他/未纳入") == true)
    }

    @Test("Attribution greater than used shows a positive difference without underflow")
    func overAttributed() {
        let line = ByteFormatting.attributionLine(
            .terminal(attributedBytes: 500_000_000_000, isComplete: true),
            volume: volume(total: 600_000_000_000, available: 107_400_000_000)
        )
        #expect(line?.contains("与卷用量差异 +\(ByteFormatting.bytes(7_400_000_000))") == true)
    }

    @Test("UInt64.max and zero are handled without overflow")
    func extremes() {
        let maxLine = ByteFormatting.attributionLine(
            .terminal(attributedBytes: UInt64.max, isComplete: true),
            volume: volume(total: 2_000, available: 1_000)
        )
        #expect(maxLine?.contains("与卷用量差异 +") == true)

        let zeroLine = ByteFormatting.attributionLine(
            .terminal(attributedBytes: 0, isComplete: true),
            volume: volume(total: 2_000, available: 1_000)
        )
        #expect(zeroLine?.contains("卷内其他/未纳入 \(ByteFormatting.bytes(1_000))") == true)

        let scanningZero = ByteFormatting.attributionLine(
            .scanning(attributedBytes: 0),
            volume: nil
        )
        #expect(scanningZero == "已扫描并归属 0 B")
    }
}

@MainActor
@Suite("App model attribution", .serialized)
struct AppModelAttributionTests {
    private let scanID = appSupportScanID()
    private let rootNodeID = NodeID(1)
    private let fixtureURL = URL(fileURLWithPath: "/private/tmp/spacejudge-fixture")

    private func makeSelection() -> DirectorySelection {
        DirectorySelection(url: fixtureURL, displayName: "fixture")
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

    private func makeModel(engine: any ScanEngine) -> AppModel {
        AppModel(
            engine: engine,
            repository: StubSnapshotRepository(),
            reader: StubSnapshotRepository(),
            directoryAccess: TestDirectoryAccess(nextSelection: makeSelection()),
            shutdown: {}
        )
    }

    @Test("A fresh model has no attribution line")
    func freshModel() {
        let model = makeModel(engine: ScriptedScanEngine(scanID: scanID, events: []))
        #expect(model.scanAttribution == nil)
        #expect(model.attributionLine == nil)
    }

    @Test("Progress surfaces the best-known scanning attribution")
    func scanningUsesProgress() async {
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID)),
                .progress(
                    ScanProgress(
                        revision: Revision(1), status: .running, fileCount: 1,
                        directoryCount: 1, attributedBytes: 4_096, pendingDirectories: 0,
                        entriesPerSecond: 10, elapsedSeconds: 0.1
                    )
                )
            ],
            holdsOpen: true,
            terminalOnCancel: appSupportSummary(scanID: scanID, status: .cancelled)
        )
        let model = makeModel(engine: engine)
        await model.chooseRoot()
        #expect(await waitUntil { model.progress?.attributedBytes == 4_096 })
        #expect(model.scanAttribution == .scanning(attributedBytes: 4_096))
        #expect(model.attributionLine?.contains("已扫描并归属") == true)
        await model.cancelScan()
        #expect(model.phase == .cancelled)
    }

    @Test("A terminal summary wins over in-flight progress")
    func summaryWinsOverProgress() async {
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID)),
                .progress(
                    ScanProgress(
                        revision: Revision(1), status: .running, fileCount: 1,
                        directoryCount: 1, attributedBytes: 4_096, pendingDirectories: 0,
                        entriesPerSecond: 10, elapsedSeconds: 0.1
                    )
                ),
                .completed(appSupportSummary(scanID: scanID, status: .completed))
            ]
        )
        let model = makeModel(engine: engine)
        await model.chooseRoot()
        await model.waitForScanToFinish()
        #expect(await waitUntil { model.phase == .completed })
        #expect(model.scanAttribution == .terminal(attributedBytes: 12_288, isComplete: true))
    }

    @Test("A cancelled terminal is unfinished and shows no completeness claim")
    func cancelledTerminal() async {
        let engine = ScriptedScanEngine(
            scanID: scanID,
            events: [
                .started(appSupportMetadata(scanID: scanID)),
                .batch(NodeBatch(scanID: scanID, revision: Revision(1), nodes: []))
            ],
            holdsOpen: true,
            terminalOnCancel: appSupportSummary(scanID: scanID, status: .cancelled)
        )
        let model = makeModel(engine: engine)
        await model.chooseRoot()
        #expect(await waitUntil { model.phase == .scanning })
        await model.cancelScan()
        #expect(model.scanAttribution == .terminal(attributedBytes: 12_288, isComplete: false))
        #expect(model.attributionLine?.contains("未完成") == true)
        await model.shutdown()
    }
}
