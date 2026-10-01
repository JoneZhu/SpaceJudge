import Foundation
import Observation

/// Shared enablement policy for the menu bar and the toolbar.
///
/// Both surfaces must use exactly the same conditions, so the rules live in one
/// pure value instead of being re-derived in each view. It is also the value the
/// app delegate republishes so the menu can observe the model's lifecycle.
public struct AppCommandPolicy: Sendable, Equatable {
    /// `⌘O` / "选择文件夹或磁盘…" is allowed unless a picker is already open or
    /// the model is shut down. It stays allowed during a scan because
    /// `chooseRoot()` cancels the active scan itself.
    public let canChooseRoot: Bool
    /// `⌘R` / "重新扫描" is allowed only with a root and no active scan.
    public let canRescan: Bool
    /// Cancel is allowed only while a scan is active.
    public let canCancel: Bool

    public init(canChooseRoot: Bool, canRescan: Bool, canCancel: Bool) {
        self.canChooseRoot = canChooseRoot
        self.canRescan = canRescan
        self.canCancel = canCancel
    }

    public init(phase: AppPhase, hasRoot: Bool, isShutDown: Bool) {
        canChooseRoot = !isShutDown && phase != .choosingRoot
        canRescan = hasRoot && !phase.isActive && !isShutDown
        canCancel = phase.isActive && !isShutDown
    }

    /// Policy before an `AppModel` exists: every command is disabled.
    public static let unavailable = AppCommandPolicy(
        canChooseRoot: false, canRescan: false, canCancel: false
    )

    /// Policy for a live model with nothing chosen and no active scan.
    public static let idle = AppCommandPolicy(phase: .idle, hasRoot: false, isShutDown: false)
}

extension AppModel {
    /// Observes `commandPolicy` and re-arms itself after every change.
    ///
    /// `AppModel` is `@Observable` while the app delegate is `ObservableObject`,
    /// so the delegate cannot observe the model directly from SwiftUI's
    /// `Commands`. This bridge reads the policy under `withObservationTracking`
    /// and delivers each new value, which the delegate republishes on its
    /// `@Published` surface. The observation is re-armed on the main actor after
    /// every change, so the menu reflects bootstrap completion, root selection,
    /// scan start/finish and picker open/close without ever force-enabling.
    @MainActor
    public func observeCommandPolicy(
        onChange: @escaping @MainActor (AppCommandPolicy) -> Void
    ) {
        withObservationTracking {
            _ = self.commandPolicy
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                onChange(self.commandPolicy)
                self.observeCommandPolicy(onChange: onChange)
            }
        }
    }
}
