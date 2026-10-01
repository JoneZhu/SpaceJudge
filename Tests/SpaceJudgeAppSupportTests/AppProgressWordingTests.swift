import Testing
import SpaceJudgeAppSupport

@Suite("App progress wording")
struct AppProgressWordingTests {
    @Test("Active phases are active; terminal phases are not")
    func activePhaseMapping() {
        for phase in [AppPhase.preparing, .scanning, .cancelling] {
            #expect(AppProgressWording(phase: phase).isActive, "\(phase)")
        }
        for phase in [AppPhase.idle, .ready, .choosingRoot, .completed, .cancelled, .failed, .permissionLimited] {
            #expect(!AppProgressWording(phase: phase).isActive, "\(phase)")
        }
    }

    @Test("The omitted-items toast is neutral in every state and never claims scanning")
    func omittedItemsMessage() {
        for active in [true, false] {
            let wording = AppProgressWording(isActive: active)
            #expect(wording.omittedItemsMessage(count: 5) == "还有 5 项未显示")
            #expect(wording.omittedItemsMessage(count: 5)?.contains("正在统计") == false)
        }
        #expect(AppProgressWording(isActive: true).omittedItemsMessage(count: 0) == nil)
        #expect(AppProgressWording(isActive: false).omittedItemsMessage(count: 0) == nil)
    }

    @Test("An active scan says still counting; a terminal scan says incomplete")
    func incompleteSuffix() {
        #expect(AppProgressWording(isActive: true).incompleteSuffix(isComplete: false) == "（正在统计）")
        #expect(AppProgressWording(isActive: false).incompleteSuffix(isComplete: false) == "（未完成）")
        #expect(AppProgressWording(isActive: true).incompleteSuffix(isComplete: true).isEmpty)
        #expect(AppProgressWording(isActive: false).incompleteSuffix(isComplete: true).isEmpty)
    }

    @Test("Aggregate status distinguishes complete, active and terminal")
    func aggregateStatus() {
        #expect(AppProgressWording(isActive: true).aggregateStatusText(isComplete: true) == "已完成")
        #expect(AppProgressWording(isActive: false).aggregateStatusText(isComplete: true) == "已完成")
        #expect(AppProgressWording(isActive: true).aggregateStatusText(isComplete: false) == "正在统计")
        #expect(AppProgressWording(isActive: false).aggregateStatusText(isComplete: false) == "未完成")
        #expect(AppProgressWording(isActive: false).pendingAggregateLabel == "未完成")
        #expect(AppProgressWording(isActive: true).pendingAggregateLabel == "正在统计")
    }

    @Test("Cancelled, failed and permission-limited never read as active")
    func terminalPhasesAreNotActive() {
        for phase in [AppPhase.cancelled, .failed, .permissionLimited] {
            let wording = AppProgressWording(phase: phase)
            #expect(!wording.isActive)
            #expect(wording.incompleteSuffix(isComplete: false) == "（未完成）")
            #expect(wording.aggregateStatusText(isComplete: false) == "未完成")
            #expect(wording.omittedItemsMessage(count: 3) == "还有 3 项未显示")
        }
    }
}
