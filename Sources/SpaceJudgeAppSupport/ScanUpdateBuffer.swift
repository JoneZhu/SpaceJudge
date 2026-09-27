import Foundation
import SpaceJudgeDomain
import SpaceJudgeUseCases

/// Coalesced snapshot of pending runner updates.
struct PendingScanUpdates {
    var started: ScanMetadata?
    var committedRevision: Revision?
    var progress: ScanProgress?
    var issueTotalCount: UInt64?
    var terminal: ScanSummary?

    var isEmpty: Bool {
        started == nil && committedRevision == nil && progress == nil
            && issueTotalCount == nil && terminal == nil
    }
}

/// Lock-protected mailbox between the runner actor and the MainActor model.
///
/// `PersistingScanUpdate` values arrive on the runner's executor. The mailbox
/// keeps only the newest value per channel, so a flood of progress or commit
/// updates can never grow memory and never spawn a task per update. Only the
/// two one-shot updates (`started`, `terminal`) request an immediate drain;
/// everything else is picked up by the 10 Hz pump.
final class ScanUpdateBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var started: ScanMetadata?
    private var committedRevision: Revision?
    private var progress: ScanProgress?
    private var issueTotalCount: UInt64?
    private var terminal: ScanSummary?
    private var wakeScheduled = false
    private var immediateWake: (@Sendable () -> Void)?

    init() {}

    /// Installs the one-shot wake handler under the same lock used by
    /// `deliver`/`takePending`. Passing `nil` clears it. `AppModel.shutdown()`
    /// uses `clearImmediateWake()` so installation/removal and capture for
    /// invocation can never race.
    func setImmediateWake(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        immediateWake = handler
        lock.unlock()
    }

    /// Clears the wake handler under the lock. Safe to call concurrently with
    /// `deliver`.
    func clearImmediateWake() {
        setImmediateWake(nil)
    }

    /// Clears all channels. Called when a new scan replaces the old one.
    func reset() {
        lock.lock()
        started = nil
        committedRevision = nil
        progress = nil
        issueTotalCount = nil
        terminal = nil
        wakeScheduled = false
        lock.unlock()
    }

    func deliver(_ update: PersistingScanUpdate) {
        var fireImmediate = false
        var handler: (@Sendable () -> Void)?
        lock.lock()
        switch update {
        case .started(let metadata):
            started = metadata
            if markImmediateLocked() {
                fireImmediate = true
                handler = immediateWake
            }
        case .terminal(let summary):
            terminal = summary
            if markImmediateLocked() {
                fireImmediate = true
                handler = immediateWake
            }
        case .committed(_, let revision):
            if let current = committedRevision {
                if revision.rawValue > current.rawValue { committedRevision = revision }
            } else {
                committedRevision = revision
            }
        case .progress(_, let value):
            progress = value
        case .issueRecorded(_, let total):
            issueTotalCount = total
        }
        lock.unlock()
        // Invoke the captured handler outside the lock so a handler that
        // re-enters the buffer cannot deadlock and cannot observe a torn
        // installation/removal.
        if fireImmediate {
            handler?()
        }
    }

    private func markImmediateLocked() -> Bool {
        guard !wakeScheduled else { return false }
        wakeScheduled = true
        return true
    }

    func takePending() -> PendingScanUpdates {
        lock.lock()
        let pending = PendingScanUpdates(
            started: started,
            committedRevision: committedRevision,
            progress: progress,
            issueTotalCount: issueTotalCount,
            terminal: terminal
        )
        started = nil
        committedRevision = nil
        progress = nil
        issueTotalCount = nil
        terminal = nil
        wakeScheduled = false
        lock.unlock()
        return pending
    }
}
