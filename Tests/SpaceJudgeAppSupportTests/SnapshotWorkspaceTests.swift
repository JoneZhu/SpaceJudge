import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeStore
@testable import SpaceJudgeAppSupport

@Suite("Snapshot workspace", .serialized)
struct SnapshotWorkspaceTests {
    /// Task-private temporary directory; never a real user Caches path.
    private final class TempDirectory {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("spacejudge-ws-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        @discardableResult
        func write(_ name: String, _ contents: String = "x") throws -> URL {
            let target = url.appendingPathComponent(name)
            try Data(contents.utf8).write(to: target)
            return target
        }

        @discardableResult
        func writeSpool(_ name: String) throws -> URL {
            let spool = url.appendingPathComponent("spool", isDirectory: true)
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
            return try write("spool/\(name)")
        }

        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
        }
    }

    private func mode(of url: URL) -> UInt16 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0xFFFF
    }

    private func workspace(_ temp: TempDirectory) -> SnapshotWorkspace {
        SnapshotWorkspace(rootURL: temp.url)
    }

    @Test("Startup removes the managed trio and managed spool files")
    func removesManagedMembers() throws {
        let temp = try TempDirectory()
        try temp.write("snapshots.sqlite")
        try temp.write("snapshots.sqlite-wal")
        try temp.write("snapshots.sqlite-shm")
        let spool = "spacejudge-spool-\(UUID().uuidString).bin"
        try temp.writeSpool(spool)

        try workspace(temp).prepare()

        #expect(!temp.exists("snapshots.sqlite"))
        #expect(!temp.exists("snapshots.sqlite-wal"))
        #expect(!temp.exists("snapshots.sqlite-shm"))
        #expect(!temp.exists("spool/\(spool)"))
        // The spool directory itself is kept and will be reused.
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("spool").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("Cleanup is idempotent")
    func idempotent() throws {
        let temp = try TempDirectory()
        try temp.write("snapshots.sqlite")
        let workspace = workspace(temp)
        try workspace.prepare()
        try workspace.prepare()
        #expect(!temp.exists("snapshots.sqlite"))
    }

    @Test("An unknown neighbour fails closed without deleting anything")
    func unknownNeighbourFailsClosed() throws {
        let temp = try TempDirectory()
        try temp.write("snapshots.sqlite")
        let neighbour = try temp.write("keep-me.txt")

        #expect(throws: SnapshotWorkspaceError.unsafeWorkspaceEntry) {
            try workspace(temp).prepare()
        }
        #expect(FileManager.default.fileExists(atPath: neighbour.path))
        // Validation happens before deletion, so the managed file also survives.
        #expect(temp.exists("snapshots.sqlite"))
    }

    @Test("A near-miss spool name and a plain subdirectory fail closed")
    func nearMissAndSubdirectoryFail() throws {
        let temp = try TempDirectory()
        try temp.writeSpool("spacejudge-spool-not-a-uuid.bin")
        #expect(throws: SnapshotWorkspaceError.unsafeWorkspaceEntry) {
            try workspace(temp).prepare()
        }

        let temp2 = try TempDirectory()
        try FileManager.default.createDirectory(
            at: temp2.url.appendingPathComponent("other"),
            withIntermediateDirectories: true
        )
        #expect(throws: SnapshotWorkspaceError.unsafeWorkspaceEntry) {
            try workspace(temp2).prepare()
        }
    }

    @Test("A symbolic link member is never followed or deleted")
    func symlinkMemberFailsClosed() throws {
        let temp = try TempDirectory()
        let target = try temp.write("real-database.sqlite")
        try FileManager.default.createSymbolicLink(
            atPath: temp.url.appendingPathComponent("snapshots.sqlite").path,
            withDestinationPath: target.path
        )

        #expect(throws: SnapshotWorkspaceError.unsafeWorkspaceEntry) {
            try workspace(temp).prepare()
        }
        #expect(FileManager.default.fileExists(atPath: target.path))
        let link = try FileManager.default.destinationOfSymbolicLink(
            atPath: temp.url.appendingPathComponent("snapshots.sqlite").path
        )
        #expect(link == target.path)
    }

    @Test("The workspace directory is tightened to 0700")
    func directoryPermissions() throws {
        let temp = try TempDirectory()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: temp.url.path
        )
        try workspace(temp).prepare()
        let attributes = try FileManager.default.attributesOfItem(atPath: temp.url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        #expect(mode & 0o077 == 0)
    }

    @Test("Debug override cleanup never removes the parent directory")
    func debugOverrideKeepsParent() throws {
        let temp = try TempDirectory()
        let databasePath = temp.url.appendingPathComponent("store.sqlite").path
        try temp.write("store.sqlite")
        try temp.write("store.sqlite-wal")

        let workspace = SnapshotWorkspace.debugOverride(databasePath: databasePath)
        try workspace.prepare()

        #expect(FileManager.default.fileExists(atPath: temp.url.path))
        #expect(!temp.exists("store.sqlite"))
        #expect(!temp.exists("store.sqlite-wal"))
    }

    @Test("Exclusion carries the workspace path and identity")
    func exclusion() throws {
        let temp = try TempDirectory()
        let workspace = workspace(temp)
        try workspace.prepare()
        let exclusion = workspace.exclusion()
        #expect(exclusion.path == temp.url.path)
        #expect(exclusion.reason == .snapshotWorkspace)
        #expect(exclusion.deviceID != nil)
        #expect(exclusion.fileID != nil)
    }

    // MARK: Root type safety (Phase 5C follow-up)

    @Test("A symbolic-link workspace root is never followed")
    func symlinkRootFailsClosed() throws {
        let temp = try TempDirectory()
        let target = try TempDirectory()
        try target.write("snapshots.sqlite", "keep")
        let neighbour = try target.write("keep-me.txt", "keep")
        try FileManager.default.createSymbolicLink(
            atPath: temp.url.appendingPathComponent("link").path,
            withDestinationPath: target.url.path
        )

        let linkWorkspace = SnapshotWorkspace(
            rootURL: temp.url.appendingPathComponent("link", isDirectory: true)
        )
        #expect(throws: SnapshotWorkspaceError.workspaceRootSymbolicLink) {
            try linkWorkspace.prepare()
        }
        // The target directory and its files are untouched.
        #expect(target.exists("snapshots.sqlite"))
        #expect(FileManager.default.fileExists(atPath: neighbour.path))
        let link = try FileManager.default.destinationOfSymbolicLink(
            atPath: temp.url.appendingPathComponent("link").path
        )
        #expect(link == target.url.path)
    }

    @Test("A non-directory workspace root fails closed")
    func nonDirectoryRootFailsClosed() throws {
        let temp = try TempDirectory()
        let file = try temp.write("not-a-directory")
        #expect(throws: SnapshotWorkspaceError.workspaceRootNotDirectory) {
            try SnapshotWorkspace(rootURL: file).prepare()
        }
    }

    @Test("A workspace root whose type cannot be confirmed fails closed")
    func unconfirmableRootFailsClosed() throws {
        let temp = try TempDirectory()
        let base = temp.url.appendingPathComponent("base", isDirectory: true)
        let child = base.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try temp.write("base/child/snapshots.sqlite", "keep")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: base.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: base.path
            )
        }
        do {
            try SnapshotWorkspace(rootURL: child).prepare()
            Issue.record("expected a fail-closed error")
        } catch let error as SnapshotWorkspaceError {
            #expect(error == .workspaceUnavailable)
        }
    }

    // MARK: Managed database file mode

    @Test("Pre-created database files stay owner-only through a real open and write")
    func databaseFilesStayOwnerOnly() async throws {
        let temp = try TempDirectory()
        let workspace = workspace(temp)
        try workspace.prepare()
        try workspace.prepareDatabaseFiles()

        let writer = try SQLiteSnapshotRepository(
            path: workspace.databaseURL.path,
            capacityProvider: FixedStorageCapacityProvider(bytes: 1 << 40)
        )
        let reader = try SQLiteSnapshotRepository.openReadOnly(path: workspace.databaseURL.path)
        let scanID = ScanID()
        try await writer.begin(
            ScanMetadata(
                scanID: scanID,
                request: ScanRequest(
                    root: ScanRoot(fileSystemPath: "/synthetic", displayName: "synthetic")
                ),
                startedAt: Date(timeIntervalSince1970: 1_000),
                rootNodeID: NodeID(1)
            )
        )
        try workspace.tightenDatabaseFilePermissions()

        for name in workspace.managedDatabaseFileNames {
            let url = temp.url.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path), "\(name) missing")
            #expect(mode(of: url) & 0o077 == 0, "\(name) mode=\(String(mode(of: url), radix: 8))")
        }
        await writer.close()
        await reader.close()
    }

    @Test("Tightening fixes files that were created with wider permissions")
    func tightenWidenedFiles() async throws {
        let temp = try TempDirectory()
        let workspace = workspace(temp)
        try workspace.prepare()
        try workspace.prepareDatabaseFiles()
        for name in workspace.managedDatabaseFileNames {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: temp.url.appendingPathComponent(name).path
            )
        }
        try workspace.tightenDatabaseFilePermissions()
        for name in workspace.managedDatabaseFileNames {
            #expect(mode(of: temp.url.appendingPathComponent(name)) & 0o077 == 0)
        }
    }

    @Test("A managed database member that is a symlink fails closed")
    func managedDatabaseSymlinkFailsClosed() throws {
        let temp = try TempDirectory()
        let target = try temp.write("other.sqlite", "keep")
        try FileManager.default.createSymbolicLink(
            atPath: temp.url.appendingPathComponent("snapshots.sqlite").path,
            withDestinationPath: target.path
        )
        #expect(throws: SnapshotWorkspaceError.unsafeWorkspaceEntry) {
            try workspace(temp).prepareDatabaseFiles()
        }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
}
