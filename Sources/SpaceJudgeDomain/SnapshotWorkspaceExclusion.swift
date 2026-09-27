import Foundation

/// A session-only directory that the scanner must treat as a storage boundary.
///
/// The exclusion set exists so SpaceJudge's own snapshot workspace can never be
/// re-enumerated while it is being written. It is intentionally tiny, bounded
/// and never persisted: it carries a full runtime path so equality/identity can
/// be decided locally, but that path is never written to SQLite, logs or
/// diagnostics.
///
/// Matching is identity-first: when the enumerator reports both a device and a
/// file identifier, that pair decides the match. The normalized path is only a
/// fallback for facts that are missing or unreliable (for example bulk
/// enumeration gaps), never a name-only comparison.
public struct SnapshotWorkspaceExclusion: Sendable, Equatable, Hashable, Codable {
    /// Why this directory may not be enumerated.
    public enum Reason: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        /// SpaceJudge's own snapshot database, WAL/SHM and directory spool.
        case snapshotWorkspace
    }

    /// Normalized absolute runtime directory path. Session-only.
    public let path: String
    /// Device identifier when already known, used for identity-first matching.
    public let deviceID: UInt64?
    /// File identifier when already known, used for identity-first matching.
    public let fileID: UInt64?
    /// Reason this directory is excluded.
    public let reason: Reason

    public init(
        path: String,
        deviceID: UInt64? = nil,
        fileID: UInt64? = nil,
        reason: Reason = .snapshotWorkspace
    ) {
        self.path = SnapshotWorkspacePath.normalize(path)
        self.deviceID = deviceID
        self.fileID = fileID
        self.reason = reason
    }

    /// Identity of this exclusion, when both identifiers are known.
    public var fileIdentity: FileIdentity? {
        guard let deviceID, let fileID else { return nil }
        return FileIdentity(deviceID: deviceID, fileID: fileID)
    }
}

/// Pure, testable path handling for the session-only exclusion set.
///
/// The production workspace path comes from Foundation and is already absolute,
/// but normalization is applied again so repeated separators, a trailing slash
/// or a `.` component can never change matching. `..` components are resolved
/// lexically because the workspace path is a real directory and never a
/// symlink-followed path.
public enum SnapshotWorkspacePath {
    /// Normalizes an absolute POSIX path into a canonical form with no trailing
    /// separator, no empty components and no `.`/lexically-resolvable `..`.
    /// A relative path is returned unchanged after the same component cleanup,
    /// because exclusion paths are only meaningful as absolute directories.
    public static func normalize(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// Whether `path` equals `ancestor` or is a strict descendant of it, using
    /// whole path components so `/a/bc` is not treated as inside `/a/b`.
    public static func isContained(_ path: String, in ancestor: String) -> Bool {
        let candidate = normalize(path)
        let root = normalize(ancestor)
        if candidate == root { return true }
        guard root != "/" else { return candidate.hasPrefix("/") }
        return candidate.hasPrefix(root + "/")
    }

    /// Resolves symlinks and standardizes an absolute path once, without
    /// touching individual directory entries. Used only at the scan-root
    /// precheck (and for the workspace exclusion value), never on the per-node
    /// hot path. Falls back to lexical normalization when resolution fails.
    public static func canonical(_ path: String) -> String {
        guard !path.isEmpty, path.hasPrefix("/") else { return path }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return normalize(resolved)
    }
}
