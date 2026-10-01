import Foundation

/// Package-only side channel that carries the directory identities a cancel
/// dropped before they could be published.
///
/// A cancelled scan can already have committed files whose `parentID` points at
/// a directory whose own enumeration never finished. Without those directory
/// rows the committed leaves are unreachable: the parent's bounded child page
/// is empty and the ancestor/name chain cannot be resolved. This value restores
/// only the missing directory identities (and the names they need). It carries
/// no aggregate, no area and no fabricated weight.
///
/// It is deliberately not part of `ScanEvent`, `ScanSummary` or the persisted
/// schema, so the public protocol, CLI/MCP output and SQLite encoding are all
/// unchanged. Only engines that opt in implement
/// `CancelledCheckpointProviding`; every other engine keeps the previous path.
package struct CancelledDirectoryCheckpoint: Sendable, Equatable {
    /// Names referenced by `directories` that had not been persisted yet.
    package let names: [NameRecord]
    /// Full directory `NodeRecord`s (final discovery-time or failure flags).
    package let directories: [NodeRecord]

    package init(names: [NameRecord], directories: [NodeRecord]) {
        self.names = names
        self.directories = directories
    }

    package var isEmpty: Bool { names.isEmpty && directories.isEmpty }
}

/// Optional engine capability: hand over the cancelled directory identities so
/// the runner can persist them before the `cancelled` terminal.
///
/// `take` is a one-shot consume: a checkpoint is returned at most once and the
/// engine keeps at most one latest cancelled slot. Completed or failed scans
/// leave no checkpoint.
package protocol CancelledCheckpointProviding: Sendable {
    /// Returns and clears the checkpoint for `scanID`, or `nil` when there is
    /// none (including after it was already taken).
    func takeCancelledCheckpoint(scanID: ScanID) async -> CancelledDirectoryCheckpoint?
}
