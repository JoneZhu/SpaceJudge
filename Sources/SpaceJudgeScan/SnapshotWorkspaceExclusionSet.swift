import Foundation
import SpaceJudgeDomain

/// Bounded, session-only matcher for `SnapshotWorkspaceExclusion` values.
///
/// The coordinator builds one of these per scan and reuses it for every
/// discovered directory. It stores only the tiny exclusion list (never a
/// per-node field), so adding it does not change the resident cost of a
/// million-node scan. Matching is identity-first with a normalized-path
/// fallback; a directory name alone can never exclude an unrelated directory.
struct SnapshotWorkspaceExclusionSet: Sendable {
    private struct Entry: Sendable {
        let identity: FileIdentity?
        let pathBytes: [UInt8]
        let canonicalPathBytes: [UInt8]

        init(_ exclusion: SnapshotWorkspaceExclusion) {
            self.identity = exclusion.fileIdentity
            self.pathBytes = Array(exclusion.path.utf8)
            self.canonicalPathBytes = Array(
                SnapshotWorkspacePath.canonical(exclusion.path).utf8
            )
        }
    }

    private let entries: [Entry]

    init(_ exclusions: [SnapshotWorkspaceExclusion]) {
        self.entries = exclusions.map(Entry.init)
    }

    var isEmpty: Bool { entries.isEmpty }

    var count: Int { entries.count }

    /// Whether the exclusion set is within the bounded request contract.
    static func isWithinLimit(_ count: Int) -> Bool {
        count >= 0 && count <= ScanRequest.maximumWorkspaceExclusions
    }

    /// Identity-first match for a discovered directory entry.
    ///
    /// `deviceID`/`fileID` are the enumerator facts. When both are present and
    /// equal an exclusion identity, the entry matches regardless of its path.
    /// Otherwise the normalized absolute `path` is compared exactly.
    func matches(
        path: [UInt8],
        deviceID: UInt64?,
        fileID: UInt64?
    ) -> Bool {
        guard !entries.isEmpty else { return false }
        if let deviceID, let fileID {
            let identity = FileIdentity(deviceID: deviceID, fileID: fileID)
            if entries.contains(where: { $0.identity == identity }) {
                return true
            }
        }
        return entries.contains { $0.pathBytes == path }
    }

    /// Whether the scan root itself equals an exclusion or lives inside one.
    /// Used to refuse a self-scanning request before `.started`.
    ///
    /// The root path is canonicalized here (once, at the root precheck) so a
    /// symlink alias pointing at the workspace or one of its descendants cannot
    /// bypass the lexical check. Exclusion paths were canonicalized once when
    /// the set was built, so this never resolves anything per node.
    func containsRoot(path: String, deviceID: UInt64?, fileID: UInt64?) -> Bool {
        guard !entries.isEmpty else { return false }
        if let deviceID, let fileID {
            let identity = FileIdentity(deviceID: deviceID, fileID: fileID)
            if entries.contains(where: { $0.identity == identity }) {
                return true
            }
        }
        let rootBytes = Array(SnapshotWorkspacePath.canonical(path).utf8)
        for entry in entries {
            if rootBytes == entry.canonicalPathBytes { return true }
            if entry.canonicalPathBytes.last != UInt8(ascii: "/"),
               rootBytes.starts(with: entry.canonicalPathBytes),
               rootBytes.count > entry.canonicalPathBytes.count,
               rootBytes[entry.canonicalPathBytes.count] == UInt8(ascii: "/") {
                return true
            }
        }
        return false
    }
}
