import Darwin
import Foundation
import SpaceJudgeDomain
import SpaceJudgeScan

/// Failures raised while preparing or cleaning SpaceJudge's own snapshot
/// workspace. Every message is path-free.
public enum SnapshotWorkspaceError: Error, Equatable, Sendable {
    /// A directory entry that is not a managed member was found. Cleanup is
    /// fail-closed: it refuses to guess rather than widen the delete scope.
    case unsafeWorkspaceEntry
    /// The workspace root exists but is not a directory.
    case workspaceRootNotDirectory
    /// The workspace root itself is a symbolic link. It is never followed.
    case workspaceRootSymbolicLink
    /// The workspace root mode could not be read or set, so owner-only access
    /// could not be confirmed.
    case workspacePermissionsUnavailable
    /// The workspace directory could not be created or tightened.
    case workspaceUnavailable
    /// A whitelisted member could not be removed.
    case entryRemovalFailed
}

/// Path and file lifecycle for the single-session snapshot cache.
///
/// This type only manages paths and the whitelist of files SpaceJudge itself
/// created. It never deletes user files, never follows a symbolic link and
/// never recurses into a parent directory. Production obtains the root from
/// Foundation's user `Caches` directory; tests pass a task-private temporary
/// directory.
public struct SnapshotWorkspace: Sendable, Equatable {
    /// Managed workspace directory (permissions target `0700`).
    public let rootURL: URL
    /// Database file inside the workspace.
    public let databaseURL: URL
    /// Spool directory inside the workspace.
    public let spoolDirectoryURL: URL
    /// Base database file name used by the cleanup whitelist.
    public let databaseFileName: String

    public init(rootURL: URL, databaseFileName: String = "snapshots.sqlite") {
        self.rootURL = rootURL
        self.databaseFileName = databaseFileName
        self.databaseURL = rootURL.appendingPathComponent(databaseFileName)
        self.spoolDirectoryURL = rootURL.appendingPathComponent("spool", isDirectory: true)
    }

    /// Production workspace: `<user Caches>/SpaceJudge`. The path is obtained
    /// from Foundation and never hardcoded.
    public static func production() throws -> SnapshotWorkspace {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return SnapshotWorkspace(
            rootURL: base.appendingPathComponent("SpaceJudge", isDirectory: true)
        )
    }

    /// Debug-only workspace for an explicit test database path. The override
    /// controls one database; cleanup still only touches that exact file, its
    /// `-wal`/`-shm` and managed spool files in the sibling `spool` directory.
    /// It never removes the parent directory.
    public static func debugOverride(databasePath: String) -> SnapshotWorkspace {
        let databaseURL = URL(fileURLWithPath: databasePath)
        let directory = databaseURL.deletingLastPathComponent()
        return SnapshotWorkspace(
            rootURL: directory,
            databaseFileName: databaseURL.lastPathComponent
        )
    }

    /// Whether `name` is one of the three managed database files.
    public func isManagedDatabaseFileName(_ name: String) -> Bool {
        name == databaseFileName
            || name == databaseFileName + "-wal"
            || name == databaseFileName + "-shm"
    }

    /// The three managed database file names, in main/WAL/SHM order.
    public var managedDatabaseFileNames: [String] {
        [databaseFileName, databaseFileName + "-wal", databaseFileName + "-shm"]
    }

    /// Creates (or tightens) the workspace and removes the previous session's
    /// managed members. Safe to call once per bootstrap.
    ///
    /// The two phases are intentionally ordered: validate every entry first, so
    /// an unknown name can never be followed by a partial delete that leaves the
    /// scope ambiguous.
    public func prepare() throws {
        try ensureRootDirectory()
        try validateMembers()
        try removeMembers()
    }

    /// Session-only exclusion for the scan request. Identity is captured when
    /// the workspace directory can be stat'ed, so matching stays identity-first.
    /// The stored path is lexical; the root precheck canonicalizes both sides so
    /// a symlink alias cannot hide the workspace.
    public func exclusion() -> SnapshotWorkspaceExclusion {
        var status = stat()
        let ok = rootURL.path.withCString { lstat($0, &status) == 0 }
        guard ok else {
            return SnapshotWorkspaceExclusion(path: rootURL.path)
        }
        return SnapshotWorkspaceExclusion(
            path: rootURL.path,
            deviceID: UInt64(UInt32(bitPattern: status.st_dev)),
            fileID: UInt64(status.st_ino)
        )
    }

    // MARK: Database file mode

    /// Creates the managed database trio as empty `0600` regular files when
    /// missing and tightens any existing member. Called by the app bootstrap
    /// before the repository opens so SQLite adopts the pre-created WAL/SHM
    /// instead of creating them with the process default mode.
    public func prepareDatabaseFiles() throws {
        for name in managedDatabaseFileNames {
            try ensureManagedRegularFile(named: name)
        }
    }

    /// Post-open safety net: tightens existing managed files to owner read/write.
    /// Missing sidecars are normal; an existing member that is not a regular
    /// file fails closed and is never followed.
    public func tightenDatabaseFilePermissions() throws {
        for name in managedDatabaseFileNames {
            try tightenManagedRegularFile(named: name)
        }
    }

    private func ensureManagedRegularFile(named name: String) throws {
        let url = rootURL.appendingPathComponent(name)
        var status = stat()
        if url.path.withCString({ lstat($0, &status) }) == 0 {
            guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                throw SnapshotWorkspaceError.unsafeWorkspaceEntry
            }
        } else {
            guard errno == ENOENT else {
                throw SnapshotWorkspaceError.workspaceUnavailable
            }
            let raw = url.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_EXCL, 0o600) }
            guard raw >= 0 else {
                throw SnapshotWorkspaceError.workspaceUnavailable
            }
            close(raw)
        }
        try tightenManagedRegularFile(named: name)
    }

    private func tightenManagedRegularFile(named name: String) throws {
        let url = rootURL.appendingPathComponent(name)
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            if errno == ENOENT { return }
            throw SnapshotWorkspaceError.workspacePermissionsUnavailable
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw SnapshotWorkspaceError.unsafeWorkspaceEntry
        }
        guard (status.st_mode & 0o077) != 0 else { return }
        guard url.path.withCString({ chmod($0, 0o600) }) == 0 else {
            throw SnapshotWorkspaceError.workspacePermissionsUnavailable
        }
    }

    // MARK: Directory lifecycle

    private func ensureRootDirectory() throws {
        let manager = FileManager.default
        var status = stat()
        let exists = rootURL.path.withCString { lstat($0, &status) } == 0
        if exists {
            // lstat never follows the final component, so a symlink root is
            // detected before anything is enumerated or deleted.
            let type = status.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFLNK) {
                throw SnapshotWorkspaceError.workspaceRootSymbolicLink
            }
            guard type == mode_t(S_IFDIR) else {
                throw SnapshotWorkspaceError.workspaceRootNotDirectory
            }
            try tightenDirectoryPermissions()
            return
        }
        guard errno == ENOENT else {
            throw SnapshotWorkspaceError.workspaceUnavailable
        }
        do {
            try manager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SnapshotWorkspaceError.workspaceUnavailable
        }
        // Re-verify without following links so a racing replacement cannot turn
        // the workspace into a symlink we then enumerate.
        var created = stat()
        guard rootURL.path.withCString({ lstat($0, &created) }) == 0,
              (created.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw SnapshotWorkspaceError.workspaceUnavailable
        }
        try tightenDirectoryPermissions()
    }

    /// Sets the managed directory to `0700` only when it is currently more
    /// permissive; a stricter existing mode is preserved. A mode that cannot be
    /// read or written is an error, never a silent success.
    private func tightenDirectoryPermissions() throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: rootURL.path)
        } catch {
            throw SnapshotWorkspaceError.workspacePermissionsUnavailable
        }
        guard let current = attributes[.posixPermissions] as? NSNumber else {
            throw SnapshotWorkspaceError.workspacePermissionsUnavailable
        }
        let mode = current.uint16Value
        guard mode & 0o077 != 0 else { return }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: rootURL.path
            )
        } catch {
            throw SnapshotWorkspaceError.workspaceUnavailable
        }
    }

    // MARK: Cleanup

    private struct Member {
        let url: URL
        let isDirectory: Bool
        let isRegularFile: Bool
        let isSymbolicLink: Bool
    }

    private func members(of directory: URL) throws -> [Member] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: []
            )
        } catch {
            throw SnapshotWorkspaceError.workspaceUnavailable
        }
        return try entries.map { url in
            let values = try url.resourceValues(forKeys: Set(keys))
            return Member(
                url: url,
                isDirectory: values.isDirectory ?? false,
                isRegularFile: values.isRegularFile ?? false,
                isSymbolicLink: values.isSymbolicLink ?? false
            )
        }
    }

    private func validateMembers() throws {
        for member in try members(of: rootURL) {
            if member.isSymbolicLink { throw SnapshotWorkspaceError.unsafeWorkspaceEntry }
            if member.isDirectory {
                guard member.url.lastPathComponent == "spool" else {
                    throw SnapshotWorkspaceError.unsafeWorkspaceEntry
                }
                try validateSpoolMembers(in: member.url)
                continue
            }
            guard member.isRegularFile,
                  isManagedDatabaseFileName(member.url.lastPathComponent) else {
                throw SnapshotWorkspaceError.unsafeWorkspaceEntry
            }
        }
    }

    private func validateSpoolMembers(in directory: URL) throws {
        for member in try members(of: directory) {
            if member.isSymbolicLink { throw SnapshotWorkspaceError.unsafeWorkspaceEntry }
            guard member.isRegularFile,
                  ManagedSpoolNaming.isManagedFileName(member.url.lastPathComponent) else {
                throw SnapshotWorkspaceError.unsafeWorkspaceEntry
            }
        }
    }

    private func removeMembers() throws {
        for member in try members(of: rootURL) {
            if member.isDirectory, member.url.lastPathComponent == "spool" {
                try removeSpoolMembers(in: member.url)
                continue
            }
            do {
                try FileManager.default.removeItem(at: member.url)
            } catch {
                throw SnapshotWorkspaceError.entryRemovalFailed
            }
        }
    }

    private func removeSpoolMembers(in directory: URL) throws {
        for member in try members(of: directory) {
            do {
                try FileManager.default.removeItem(at: member.url)
            } catch {
                throw SnapshotWorkspaceError.entryRemovalFailed
            }
        }
    }
}
