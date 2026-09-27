import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeUseCases
@testable import SpaceJudgeAppSupport

@Suite("Scan update buffer")
struct ScanUpdateBufferTests {
    private let scanID = appSupportScanID()

    private func progress(_ revision: UInt64) -> ScanProgress {
        ScanProgress(
            revision: Revision(revision),
            status: .running,
            fileCount: revision,
            directoryCount: 0,
            attributedBytes: revision * 100,
            pendingDirectories: 0,
            entriesPerSecond: 1_000,
            elapsedSeconds: Double(revision)
        )
    }

    @Test("Progress updates coalesce to the newest value")
    func progressCoalesces() {
        let buffer = ScanUpdateBuffer()
        for revision in 1...500 {
            buffer.deliver(.progress(scanID: scanID, value: progress(UInt64(revision))))
        }
        let pending = buffer.takePending()
        #expect(pending.progress?.revision == Revision(500))
        #expect(buffer.takePending().isEmpty)
    }

    @Test("Committed revisions coalesce to the highest")
    func committedCoalesces() {
        let buffer = ScanUpdateBuffer()
        buffer.deliver(.committed(scanID: scanID, revision: Revision(7)))
        buffer.deliver(.committed(scanID: scanID, revision: Revision(3)))
        buffer.deliver(.committed(scanID: scanID, revision: Revision(9)))
        #expect(buffer.takePending().committedRevision == Revision(9))
    }

    @Test("Only one-shot updates request an immediate drain")
    func immediateWakeCoalesces() {
        let buffer = ScanUpdateBuffer()
        let counter = CallCounter()
        buffer.setImmediateWake { counter.increment() }

        buffer.deliver(.started(appSupportMetadata(scanID: scanID)))
        buffer.deliver(.terminal(appSupportSummary(scanID: scanID, status: .completed)))
        // Both arrived before the drain; the wake is coalesced into one.
        #expect(counter.count == 1)

        _ = buffer.takePending()
        buffer.deliver(.committed(scanID: scanID, revision: Revision(1)))
        buffer.deliver(.progress(scanID: scanID, value: progress(1)))
        #expect(counter.count == 1)

        buffer.deliver(.terminal(appSupportSummary(scanID: scanID, status: .cancelled)))
        #expect(counter.count == 2)

        buffer.clearImmediateWake()
        _ = buffer.takePending()
        buffer.deliver(.terminal(appSupportSummary(scanID: scanID, status: .completed)))
        #expect(counter.count == 2)
    }

    @Test("Concurrent install/clear and one-shot delivery does not race or deadlock")
    func concurrentWakeLifecycle() async {
        let buffer = ScanUpdateBuffer()
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<6 {
                group.addTask {
                    for iteration in 0..<400 {
                        if (worker + iteration) % 2 == 0 {
                            buffer.setImmediateWake {
                                // Keep the handler cheap; correctness is the
                                // absence of torn reads or deadlock.
                                _ = iteration
                            }
                        } else {
                            buffer.clearImmediateWake()
                        }
                        switch iteration % 4 {
                        case 0:
                            buffer.deliver(.started(appSupportMetadata(scanID: self.scanID)))
                        case 1:
                            buffer.deliver(.terminal(appSupportSummary(scanID: self.scanID, status: .completed)))
                        case 2:
                            buffer.deliver(.progress(scanID: self.scanID, value: self.progress(1)))
                        default:
                            buffer.deliver(.committed(scanID: self.scanID, revision: Revision(UInt64(iteration + 1))))
                        }
                        if iteration % 16 == 0 {
                            _ = buffer.takePending()
                        }
                    }
                }
            }
        }
        buffer.clearImmediateWake()
        _ = buffer.takePending()
    }

    @Test("A reset drops pending state")
    func resetDropsState() {
        let buffer = ScanUpdateBuffer()
        buffer.deliver(.progress(scanID: scanID, value: progress(1)))
        buffer.deliver(.started(appSupportMetadata(scanID: scanID)))
        buffer.reset()
        #expect(buffer.takePending().isEmpty)
    }
}
