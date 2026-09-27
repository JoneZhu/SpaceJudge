import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

@Suite("Snapshot workspace scan boundary", .serialized)
struct SnapshotWorkspaceBoundaryTests {
    private func spoolFiles(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    // MARK: Matcher unit tests

    @Test("Identity wins over path, and a missing identity falls back to path")
    func matcherIdentityThenPath() {
        let exclusionPath = "/private/tmp/exclusion"
        let identity = FileIdentity(deviceID: 7, fileID: 42)
        let set = SnapshotWorkspaceExclusionSet([
            SnapshotWorkspaceExclusion(
                path: exclusionPath,
                deviceID: identity.deviceID,
                fileID: identity.fileID
            )
        ])

        // Identity match at a different path still matches.
        #expect(
            set.matches(
                path: Array("/elsewhere".utf8),
                deviceID: 7,
                fileID: 42
            )
        )
        // Same name, different identity and path does not match.
        #expect(
            !set.matches(
                path: Array("/other/exclusion".utf8),
                deviceID: 7,
                fileID: 99
            )
        )
        // Missing identity falls back to exact normalized path.
        #expect(
            set.matches(
                path: Array(exclusionPath.utf8),
                deviceID: nil,
                fileID: nil
            )
        )
        #expect(
            !set.matches(
                path: Array("/other/exclusion".utf8),
                deviceID: nil,
                fileID: nil
            )
        )
    }

    @Test("Root containment is component-exact and covers equality and descendants")
    func rootContainment() {
        let set = SnapshotWorkspaceExclusionSet([
            SnapshotWorkspaceExclusion(path: "/a/b")
        ])
        #expect(set.containsRoot(path: "/a/b", deviceID: nil, fileID: nil))
        #expect(set.containsRoot(path: "/a/b/c", deviceID: nil, fileID: nil))
        #expect(!set.containsRoot(path: "/a/bc", deviceID: nil, fileID: nil))
        #expect(!set.containsRoot(path: "/a", deviceID: nil, fileID: nil))
        #expect(
            set.containsRoot(path: "/completely/elsewhere", deviceID: 1, fileID: 2) == false
        )
    }

    @Test("Path normalization collapses separators and dot components")
    func pathNormalization() {
        #expect(SnapshotWorkspacePath.normalize("/a//b/./c/") == "/a/b/c")
        #expect(SnapshotWorkspacePath.normalize("/a/b/../c") == "/a/c")
        #expect(SnapshotWorkspacePath.isContained("/a/b/c", in: "/a/b"))
        #expect(!SnapshotWorkspacePath.isContained("/a/b", in: "/a/b/c"))
    }

    // MARK: Engine boundary

    @Test("A workspace directory is kept as a leaf with no enumerated children")
    func workspaceIsLeafBoundary() async throws {
        let fixture = try TempFixture()
        try fixture.directory("ws/inner")
        try fixture.file("ws/inner/deep.txt", contents: "deep")
        try fixture.file("ws/direct.txt", contents: "direct")
        try fixture.file("keep/file.txt", contents: "keep")

        let exclusion = SnapshotWorkspaceExclusion(
            path: fixture.path("ws"),
            deviceID: nil,
            fileID: nil
        )
        let request = ScanRequest(
            root: ScanRoot(fileSystemPath: fixture.url.path, displayName: "fixture"),
            workspaceExclusions: [exclusion]
        )
        let engine = FileSystemScanEngine(configuration: ScanConfiguration(workerCount: 2))
        let collected = try await collectScan(engine: engine, request: request)

        #expect(collected.status == .completed)
        let boundary = collected.nodes.values.first {
            collected.relativePath(of: $0.id) == "ws"
        }
        #expect(boundary?.flags.contains(.snapshotStorageBoundary) == true)
        #expect(
            !collected.nodes.values.contains {
                collected.relativePath(of: $0.id).hasPrefix("ws/")
            }
        )
        #expect(
            collected.nodes.values.contains {
                collected.relativePath(of: $0.id) == "keep/file.txt"
            }
        )
        // The boundary is complete but deliberately contributes no bytes.
        if let boundary {
            #expect(collected.aggregates[boundary.id]?.isComplete == true)
            #expect(collected.aggregates[boundary.id]?.descendantFileCount == 0)
        }
        #expect(!collected.issueCategories.keys.contains(.permissionDenied))
    }

    @Test("A same-named directory at a different path is not excluded")
    func sameNameDifferentPath() async throws {
        let fixture = try TempFixture()
        try fixture.file("a/ws/inside.txt", contents: "a")
        try fixture.file("b/ws/inside.txt", contents: "b")

        let exclusion = SnapshotWorkspaceExclusion(
            path: fixture.path("a/ws"),
            deviceID: nil,
            fileID: nil
        )
        let request = ScanRequest(
            root: ScanRoot(fileSystemPath: fixture.url.path, displayName: "fixture"),
            workspaceExclusions: [exclusion]
        )
        let engine = FileSystemScanEngine(configuration: ScanConfiguration(workerCount: 2))
        let collected = try await collectScan(engine: engine, request: request)

        #expect(
            collected.nodes.values.contains {
                collected.relativePath(of: $0.id) == "b/ws/inside.txt"
            }
        )
        #expect(
            !collected.nodes.values.contains {
                collected.relativePath(of: $0.id) == "a/ws/inside.txt"
            }
        )
    }

    @Test("A root equal to the workspace fails before .started")
    func rootEqualsWorkspace() async throws {
        let fixture = try TempFixture()
        try fixture.file("ws/file.txt", contents: "x")
        let exclusion = SnapshotWorkspaceExclusion(path: fixture.path("ws"))
        let request = ScanRequest(
            root: ScanRoot(fileSystemPath: fixture.path("ws"), displayName: "ws"),
            workspaceExclusions: [exclusion]
        )
        let engine = FileSystemScanEngine(configuration: ScanConfiguration(workerCount: 1))
        do {
            _ = try await collectScan(engine: engine, request: request)
            Issue.record("expected refusal")
        } catch let error as ScanError {
            #expect(error == .scanRootInsideSnapshotWorkspace)
        }
    }

    @Test("A root inside the workspace fails before .started")
    func rootInsideWorkspace() async throws {
        let fixture = try TempFixture()
        try fixture.file("ws/inner/file.txt", contents: "x")
        let exclusion = SnapshotWorkspaceExclusion(path: fixture.path("ws"))
        let request = ScanRequest(
            root: ScanRoot(fileSystemPath: fixture.path("ws/inner"), displayName: "inner"),
            workspaceExclusions: [exclusion]
        )
        let engine = FileSystemScanEngine(configuration: ScanConfiguration(workerCount: 1))
        do {
            _ = try await collectScan(engine: engine, request: request)
            Issue.record("expected refusal")
        } catch let error as ScanError {
            #expect(error == .scanRootInsideSnapshotWorkspace)
        }
    }

    @Test("A symlink alias into the workspace fails before .started")
    func symlinkAliasIntoWorkspace() async throws {
        let fixture = try TempFixture()
        try fixture.file("ws/inner/file.txt", contents: "x")
        let alias = fixture.path("alias")
        try FileManager.default.createSymbolicLink(
            atPath: alias,
            withDestinationPath: fixture.path("ws/inner")
        )
        let exclusion = SnapshotWorkspaceExclusion(path: fixture.path("ws"))
        let request = ScanRequest(
            root: ScanRoot(fileSystemPath: alias, displayName: "alias"),
            workspaceExclusions: [exclusion]
        )
        let engine = FileSystemScanEngine(configuration: ScanConfiguration(workerCount: 1))
        var sawStarted = false
        do {
            for try await event in engine.events(for: request) {
                if case .started = event { sawStarted = true }
            }
            Issue.record("expected refusal")
        } catch let error as ScanError {
            #expect(error == .scanRootInsideSnapshotWorkspace)
        }
        #expect(!sawStarted)
    }

    @Test("An ancestor directory scan still truncates at the workspace leaf")
    func ancestorScanStillTruncates() async throws {
        let fixture = try TempFixture()
        try fixture.file("ws/inner/file.txt", contents: "x")
        try fixture.file("sibling/file.txt", contents: "y")
        let exclusion = SnapshotWorkspaceExclusion(path: fixture.path("ws"))
        let request = ScanRequest(
            root: ScanRoot(fileSystemPath: fixture.url.path, displayName: "fixture"),
            workspaceExclusions: [exclusion]
        )
        let engine = FileSystemScanEngine(configuration: ScanConfiguration(workerCount: 2))
        let collected = try await collectScan(engine: engine, request: request)
        #expect(collected.status == .completed)
        let boundary = collected.nodes.values.first {
            collected.relativePath(of: $0.id) == "ws"
        }
        #expect(boundary?.flags.contains(.snapshotStorageBoundary) == true)
        #expect(
            !collected.nodes.values.contains {
                collected.relativePath(of: $0.id).hasPrefix("ws/")
            }
        )
        #expect(
            collected.nodes.values.contains {
                collected.relativePath(of: $0.id) == "sibling/file.txt"
            }
        )
    }

    @Test("More than the bounded exclusion count is rejected")
    func tooManyExclusions() async throws {
        let fixture = try TempFixture()
        try fixture.file("file.txt", contents: "x")
        let exclusions = (0...ScanRequest.maximumWorkspaceExclusions).map { index in
            SnapshotWorkspaceExclusion(path: "/tmp/spacejudge-exclusion-\(index)")
        }
        let request = ScanRequest(
            root: ScanRoot(fileSystemPath: fixture.url.path, displayName: "fixture"),
            workspaceExclusions: exclusions
        )
        let engine = FileSystemScanEngine(configuration: ScanConfiguration(workerCount: 1))
        do {
            _ = try await collectScan(engine: engine, request: request)
            Issue.record("expected refusal")
        } catch let error as ScanError {
            #expect(error == .tooManyWorkspaceExclusions(limit: ScanRequest.maximumWorkspaceExclusions))
        }
    }

    @Test("A forced spool uses the configured workspace directory and is removed")
    func spoolUsesConfiguredDirectory() async throws {
        let fixture = try TempFixture()
        for index in 0..<8 {
            try fixture.file("dir\(index)/file.txt", contents: "x")
        }
        let spoolDirectory = fixture.url.appendingPathComponent("spool", isDirectory: true)
        let scanID = ScanID()
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                workerCount: 1,
                maximumQueuedDirectories: 1,
                spoolDirectory: spoolDirectory
            )
        )
        let collected = try await collectScan(
            engine: engine,
            request: ScanRequest(
                root: ScanRoot(fileSystemPath: fixture.url.path, displayName: "fixture")
            ),
            scanID: scanID
        )
        #expect(collected.status == .completed)
        // Diagnostics are recorded by a detached task after the stream ends, so
        // wait briefly instead of racing that task.
        var spoolUsed = false
        for _ in 0..<200 {
            if engine.takeDiagnostics(for: scanID)?.spoolUsed == true {
                spoolUsed = true
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(spoolUsed)
        #expect(spoolFiles(in: spoolDirectory).isEmpty)
    }
}
