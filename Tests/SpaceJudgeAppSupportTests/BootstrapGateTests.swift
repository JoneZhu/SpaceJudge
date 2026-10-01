import Testing
@testable import SpaceJudgeAppSupport

@Suite("Bootstrap single-flight gate")
struct BootstrapGateTests {
    @Test("Only the first caller may begin while one bootstrap is running")
    func singleFlight() {
        var gate = BootstrapGate()
        let first = gate.begin()
        #expect(first)
        #expect(gate.isRunning)
        // A second, third activation during the same bootstrap is rejected, so
        // no second repository pair is opened.
        let second = gate.begin()
        let third = gate.begin()
        #expect(!second)
        #expect(!third)
        #expect(gate.isRunning)
        gate.end()
        #expect(!gate.isRunning)
        let afterEnd = gate.begin()
        #expect(afterEnd)
        gate.end()
    }

    @Test("Ending an idle gate is harmless and leaves it ready")
    func endIsIdempotent() {
        var gate = BootstrapGate()
        gate.end()
        gate.end()
        #expect(!gate.isRunning)
        let began = gate.begin()
        #expect(began)
    }
}
