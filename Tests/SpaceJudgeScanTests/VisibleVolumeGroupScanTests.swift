import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

/// Enumerator that scripts entries per directory inode.
///
/// It resolves the real directory behind the descriptor to a fixture-relative
/// path, so the synthetic tree is independent of the engine's scheduling order.
private final class InodeScriptedEnumerator: DirectoryEnumerator, @unchecked Sendable {
    private let lock = NSLock()
    private var scriptsByRelativePath: [String: [RawDirectoryEntry]]
    private var inodeToPath: [UInt64: String]
    private var usedPaths: [String] = []
    /// A directory whose cursor never reports `isLast`, so a cancel test can
    /// keep the scan open deterministically instead of racing completion.
    private let nonCompletingPath: String?

    init(
        rootPath: String,
        scriptsByRelativePath: [String: [RawDirectoryEntry]],
        nonCompletingPath: String? = nil
    ) throws {
        self.nonCompletingPath = nonCompletingPath
        self.scriptsByRelativePath = scriptsByRelativePath
        var inodeToPath: [UInt64: String] = [:]
        for relative in scriptsByRelativePath.keys {
            let full = relative.isEmpty
                ? rootPath
                : rootPath + "/" + relative
            var status = stat()
            guard stat(full, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            inodeToPath[UInt64(status.st_ino)] = relative
        }
        self.inodeToPath = inodeToPath
    }

    func makeCursor(
        in directory: DirectoryHandle,
        request: EnumerationRequest
    ) throws -> any DirectoryCursor {
        var status = stat()
        guard fstat(directory.fileDescriptor, &status) == 0 else {
            throw ScanError.enumerationFailed(errno: errno)
        }
        lock.lock()
        let relative = inodeToPath[UInt64(status.st_ino)]
        if let relative { usedPaths.append(relative) }
        let entries = relative.flatMap { scriptsByRelativePath[$0] } ?? []
        let isNonCompleting = relative == nonCompletingPath
        lock.unlock()
        if isNonCompleting {
            return NeverEndingCursor(entries)
        }
        return ScriptedCursor(.entries(entries))
    }

    var enumeratedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return usedPaths
    }
}

/// Emits one non-final page then never finishes, so the owning worker keeps
/// yielding to cancellation instead of letting the scan complete first.
private final class NeverEndingCursor: DirectoryCursor {
    private var pending: [RawDirectoryEntry]?

    init(_ entries: [RawDirectoryEntry]) { pending = entries }

    func nextPage() throws -> DirectoryEntryPage {
        if let pending {
            self.pending = nil
            return DirectoryEntryPage(entries: pending, isLast: false)
        }
        usleep(5_000)
        return DirectoryEntryPage(entries: [], isLast: false)
    }
}

@Suite("Synthetic visible volume group", .serialized)
struct VisibleVolumeGroupScanTests {
    private func directory(
        _ name: String,
        device: UInt64?,
        isFirmlink: Bool = false,
        isMountPoint: Bool = false,
        fileID: UInt64? = nil
    ) -> RawDirectoryEntry {
        RawDirectoryEntry(
            nameBytes: Array(name.utf8),
            kind: .directory,
            deviceID: device,
            fileID: fileID,
            isMountPoint: isMountPoint,
            isFirmlink: isFirmlink
        )
    }

    private func file(_ name: String, device: UInt64) -> RawDirectoryEntry {
        RawDirectoryEntry(
            nameBytes: Array(name.utf8),
            kind: .regularFile,
            logicalBytes: 100,
            allocatedBytes: 4096,
            deviceID: device,
            fileID: 5_000,
            linkCount: 1
        )
    }

    private func makeFixture(
        nonCompletingPath: String? = nil
    ) throws -> (TempFixture, InodeScriptedEnumerator) {
        let fixture = try TempFixture(prefix: "spacejudge-volume-group")
        try fixture.directory("Applications/AppA")
        try fixture.directory("Users/user")
        try fixture.file("Users/user/file.txt")
        try fixture.directory("System/Volumes")
        try fixture.directory("Volumes")

        // The engine compares entry devices against the real device of the
        // fixture root, so the synthetic system volume must use that identity;
        // the data volume is a distinct, non-matching identity.
        var rootStatus = stat()
        guard stat(fixture.url.path, &rootStatus) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let systemDevice = UInt64(rootStatus.st_dev)
        let dataDevice = systemDevice &+ 1

        let scripts: [String: [RawDirectoryEntry]] = [
            "": [
                directory("Applications", device: systemDevice, isFirmlink: true),
                directory("Users", device: systemDevice, isFirmlink: true),
                directory("System", device: systemDevice),
                directory("Volumes", device: systemDevice, isFirmlink: true)
            ],
            "Applications": [directory("AppA", device: dataDevice)],
            "Users": [directory("user", device: dataDevice)],
            "Users/user": [file("file.txt", device: dataDevice)],
            "System": [directory("Volumes", device: systemDevice)],
            "System/Volumes": [
                directory("Data", device: dataDevice, isMountPoint: true),
                directory("VM", device: systemDevice, isMountPoint: true)
            ],
            "Volumes": [directory("External", device: systemDevice, isMountPoint: true)],
            "Applications/AppA": []
        ]
        let enumerator = try InodeScriptedEnumerator(
            rootPath: fixture.url.path,
            scriptsByRelativePath: scripts,
            nonCompletingPath: nonCompletingPath
        )
        return (fixture, enumerator)
    }

    private func visibleRequest(for path: String) -> ScanRequest {
        ScanRequest(
            root: ScanRoot(fileSystemPath: path, displayName: "startup"),
            boundaryPolicy: .visibleStartupVolumeGroup
        )
    }

    @Test("Firmlink projections are scanned once and real mounts are truncated")
    func syntheticTree() async throws {
        let (fixture, enumerator) = try makeFixture()
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(enumerator: enumerator, workerCount: 1)
        )
        let collected = try await collectScan(
            engine: engine,
            request: visibleRequest(for: fixture.url.path)
        )

        #expect(collected.status == .completed)
        #expect(collected.terminalCount == 1)
        #expect(collected.batchesAfterTerminal == 0)

        // Projected data appears exactly once, reached through the visible
        // firmlink, never through the raw mount.
        let appA = collected.nodes.values.filter { collected.relativePath(of: $0.id) == "Applications/AppA" }
        #expect(appA.count == 1)
        let userPath = collected.nodes.values.filter {
            collected.relativePath(of: $0.id) == "Users/user/file.txt"
        }
        #expect(userPath.count == 1)

        for name in ["Applications", "Users", "Volumes"] {
            let matches = collected.nodes.values.filter { collected.relativePath(of: $0.id) == name }
            #expect(matches.count == 1)
            #expect(matches.first?.flags.contains(.firmlinkProjection) == true)
        }

        // Mount points are visible boundary leaves with no descendants.
        for path in ["System/Volumes/Data", "System/Volumes/VM", "Volumes/External"] {
            let matches = collected.nodes.values.filter { collected.relativePath(of: $0.id) == path }
            #expect(matches.count == 1)
            #expect(matches.first?.flags.contains(.mountBoundary) == true)
        }

        let enumerated = enumerator.enumeratedPaths
        #expect(!enumerated.contains("System/Volumes/Data"))
        #expect(!enumerated.contains("System/Volumes/VM"))
        #expect(!enumerated.contains("Volumes/External"))

        #expect(collected.fileCount == 1)
        // root, Applications, AppA, Users, user, System, System/Volumes,
        // Volumes, Data, VM, External
        #expect(collected.directoryCount == 11)
        let aggregate = try #require(collected.rootAggregate())
        #expect(aggregate.isComplete)
        #expect(aggregate.attributedBytes == 4096)
        #expect(aggregate.descendantFileCount == 1)
    }

    @Test("Cancelling the synthetic tree yields one cancelled terminal")
    func syntheticCancel() async throws {
        // `System` never finishes its own enumeration, so the scan cannot
        // complete before `collectScan` processes the first batch and cancels.
        let (fixture, enumerator) = try makeFixture(nonCompletingPath: "System")
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: enumerator,
                workerCount: 1,
                batchNodeLimit: 1
            )
        )
        let collected = try await collectScan(
            engine: engine,
            request: visibleRequest(for: fixture.url.path),
            cancelAfterFirstBatch: true
        )
        #expect(collected.status == .cancelled)
        #expect(collected.terminalCount == 1)
        #expect(collected.batchesAfterTerminal == 0)
    }

    @Test("An unknown child device inside a firmlink still traverses the projection")
    func unknownChildDeviceInsideFirmlink() async throws {
        let fixture = try TempFixture(prefix: "spacejudge-volume-group-unknown")
        try fixture.directory("Link/mid/deep")

        var rootStatus = stat()
        guard stat(fixture.url.path, &rootStatus) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let systemDevice = UInt64(rootStatus.st_dev)
        let dataDevice = systemDevice &+ 1

        let scripts: [String: [RawDirectoryEntry]] = [
            "": [directory("Link", device: systemDevice, isFirmlink: true)],
            // The projected child does not report a device; it must not inherit
            // the old system device, or its own data-device children would be
            // wrongly truncated.
            "Link": [directory("mid", device: nil)],
            "Link/mid": [directory("deep", device: dataDevice)],
            "Link/mid/deep": []
        ]
        let enumerator = try InodeScriptedEnumerator(
            rootPath: fixture.url.path,
            scriptsByRelativePath: scripts
        )
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(enumerator: enumerator, workerCount: 1)
        )
        let collected = try await collectScan(
            engine: engine,
            request: visibleRequest(for: fixture.url.path)
        )
        let deep = collected.nodes.values.filter {
            collected.relativePath(of: $0.id) == "Link/mid/deep"
        }
        #expect(deep.count == 1)
        #expect(deep.first?.flags.contains(.mountBoundary) == false)
        #expect(enumerator.enumeratedPaths.contains("Link/mid"))
    }

    @Test("Without the visible policy the same tree truncates at the firmlink")
    func defaultPolicyTruncatesFirmlink() async throws {
        let (fixture, enumerator) = try makeFixture()
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(enumerator: enumerator, workerCount: 1)
        )
        let request = ScanRequest(
            root: ScanRoot(fileSystemPath: fixture.url.path, displayName: "startup"),
            boundaryPolicy: .stayOnRootFileSystem
        )
        let collected = try await collectScan(engine: engine, request: request)
        // The firmlink directory itself is entered (its bulk device matches the
        // root), but its projected children live on the data device and are
        // truncated: they appear as boundary leaves, never expanded.
        let appA = collected.nodes.values.filter {
            collected.relativePath(of: $0.id) == "Applications/AppA"
        }
        #expect(appA.count == 1)
        #expect(appA.first?.flags.contains(.mountBoundary) == true)
        #expect(!collected.nodes.values.contains {
            collected.relativePath(of: $0.id) == "Users/user/file.txt"
        })
        // The firmlink itself is enumerated; only its projected children are
        // truncated.
        #expect(enumerator.enumeratedPaths.contains("Applications"))
    }
}
