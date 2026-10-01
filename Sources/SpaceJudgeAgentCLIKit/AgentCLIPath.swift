import Darwin
import Foundation
import SpaceJudgeDomain

/// Path validation for the agent CLI.
///
/// Every check is fail-closed and returns a path-free error. A final-component
/// symbolic link is rejected for authorized roots and workspaces; the canonical
/// real path is computed only for containment and dedupe decisions.
public enum AgentCLIPath {
    /// Validates an absolute path that must resolve to an existing directory.
    public static func requireDirectory(_ path: String) throws -> String {
        guard path.hasPrefix("/") else {
            throw AgentCLIError(code: .invalidArgument)
        }
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else {
            if errno == ENOENT { throw AgentCLIError(code: .notFound) }
            throw AgentCLIError(code: .accessDenied)
        }
        let type = status.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFLNK) {
            throw AgentCLIError(code: .invalidArgument)
        }
        guard type == mode_t(S_IFDIR) else {
            throw AgentCLIError(code: .invalidArgument)
        }
        return canonical(path)
    }

    /// Canonicalizes an absolute path, resolving symlinks once.
    ///
    /// Foundation resolves symlinks inconsistently for a path whose final
    /// component does not exist yet, so a missing leaf is resolved through its
    /// deepest existing ancestor and then re-appended. This keeps containment
    /// checks stable for a brand-new database file.
    public static func canonical(_ path: String) -> String {
        let normalized = SnapshotWorkspacePath.normalize(path)
        var status = stat()
        if normalized.withCString({ lstat($0, &status) }) == 0 {
            let resolved = URL(fileURLWithPath: normalized).resolvingSymlinksInPath().path
            return SnapshotWorkspacePath.normalize(resolved)
        }
        let url = URL(fileURLWithPath: normalized)
        let parent = url.deletingLastPathComponent().path
        guard parent != normalized, !parent.isEmpty else {
            return normalized
        }
        return SnapshotWorkspacePath.normalize(
            canonical(parent) + "/" + url.lastPathComponent
        )
    }

    /// Whether `path` equals `ancestor` or is a descendant, by whole components.
    public static func isContained(_ path: String, in ancestor: String) -> Bool {
        SnapshotWorkspacePath.isContained(canonical(path), in: canonical(ancestor))
    }

    /// Validates that a new database path is absolute and does not exist yet.
    public static func requireNewFile(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw AgentCLIError(code: .invalidArgument)
        }
        var status = stat()
        if path.withCString({ lstat($0, &status) }) == 0 {
            throw AgentCLIError(code: .conflict)
        }
        guard errno == ENOENT else {
            throw AgentCLIError(code: .accessDenied)
        }
    }

    /// Validates an existing database file that will be opened read-only.
    public static func requireReadableFile(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw AgentCLIError(code: .invalidArgument)
        }
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else {
            if errno == ENOENT { throw AgentCLIError(code: .notFound) }
            throw AgentCLIError(code: .accessDenied)
        }
        let type = status.st_mode & mode_t(S_IFMT)
        guard type == mode_t(S_IFREG) else {
            throw AgentCLIError(code: .notFound)
        }
        guard path.withCString({ access($0, R_OK) }) == 0 else {
            throw AgentCLIError(code: .accessDenied)
        }
    }
}
