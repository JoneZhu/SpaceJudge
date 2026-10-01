import Foundation

/// A directory or volume chosen by the user through the open panel.
///
/// The `url` is only meaningful for the current process: it carries the
/// security scope used by the scanner. It is never persisted, and only the
/// human-readable `displayName` may reach the UI or the database.
public struct DirectorySelection: Sendable, Equatable {
    /// Session-only file URL returned by the open panel.
    public let url: URL
    /// User-facing label. Defaults to the last path component.
    public let displayName: String

    public init(url: URL, displayName: String? = nil) {
        self.url = url
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            self.displayName = trimmed
        } else {
            let last = url.lastPathComponent
            self.displayName = last.isEmpty ? url.path : last
        }
    }

    /// Runtime POSIX path handed to the scan engine. Not persisted in SQLite.
    /// Desktop cleanup handoff may include a derived target path after UI review.
    public var fileSystemPath: String { url.path }
}

/// Presents the directory picker and manages the paired security scope.
///
/// The AppKit `NSOpenPanel` adapter lives in the App target so this module
/// stays free of UI frameworks. The model only depends on this protocol, which
/// makes scope pairing and picker cancellation testable. It is main-actor
/// isolated because panel presentation and AppKit security scope must happen
/// there.
@MainActor
public protocol DirectoryAccess: Sendable {
    /// Shows a single-directory picker. `nil` means the user cancelled.
    func pickDirectory() async -> DirectorySelection?
    /// Suggests a location; the user must still confirm it in the system picker.
    func pickDirectory(initialURL: URL?) async -> DirectorySelection?
    /// Starts access; the matching `stopAccess` must only be called when this
    /// returns `true`.
    func startAccess(for selection: DirectorySelection) -> Bool
    /// Stops a previously started access.
    func stopAccess(for selection: DirectorySelection)
}

public extension DirectoryAccess {
    func pickDirectory(initialURL: URL?) async -> DirectorySelection? {
        await pickDirectory()
    }
}
