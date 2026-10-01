import Foundation

/// Single-flight gate for the app's database bootstrap.
///
/// `AppModel` bootstrap is asynchronous: the first call suspends while opening
/// SQLite, and a second activation of the retry entry (double click, held key)
/// must not open a second repository pair against the same workspace. This type
/// keeps that guard explicit and unit-testable instead of relying on a comment.
public struct BootstrapGate: Sendable, Equatable {
    /// Whether a bootstrap is currently in flight.
    public private(set) var isRunning: Bool

    public init(isRunning: Bool = false) {
        self.isRunning = isRunning
    }

    /// Returns `true` for the first caller only. Every caller while a bootstrap
    /// is running gets `false`.
    public mutating func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    /// Marks the in-flight bootstrap finished. Safe to call more than once.
    public mutating func end() {
        isRunning = false
    }
}
