import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeAppSupport

@Suite("Codex cleanup context")
struct CodexCleanupContextTests {
    private func state(revision: UInt64 = 7) -> ScanSnapshotState {
        .init(scanID: appSupportScanID(), status: .completed, rootNodeID: NodeID(1),
              rootDisplayName: "fixture", lastRevision: Revision(revision),
              startedAt: Date(timeIntervalSince1970: 100), finishedAt: Date(timeIntervalSince1970: 200),
              fileCount: 1, directoryCount: 2, inaccessibleCount: 0, issueCount: 0, rootAttributedBytes: 100)
    }
    private func fixture(name: String = "Docker 中文'") async throws -> (StubSnapshotRepository, AgentAnalysisSnapshot) {
        let reader = StubSnapshotRepository()
        let root = NodeRecord(id: NodeID(1), scanID: appSupportScanID(), parentID: nil, name: NameID(1),
                              kind: .directory, flags: [], logicalBytes: nil, allocatedBytes: nil, attributedBytes: 100)
        let target = appSupportChildItem(id: 2, name: name, attributed: 100)
        await reader.setState(state())
        await reader.setAncestors([root, target.node], for: NodeID(2))
        await reader.setName(NameRecord(id: NameID(1), bytes: Array("fixture".utf8)))
        await reader.setName(target.name)
        await reader.setPage(.init(items: [], totalCount: 0, snapshotRevision: Revision(7)), for: NodeID(2))
        let report = try await AgentAnalysisSnapshot.capture(loader: SnapshotLoader(repository: reader),
            scanID: appSupportScanID(), nodeID: NodeID(2))
        return (reader, report)
    }
    @Test("Exact session path and scan times are explicit, legacy snapshot stays path-free")
    func pathAndFacts() async throws {
        let (reader, report) = try await fixture()
        let facts = VolumeFacts(totalCapacityBytes: 1_000_000_000_000,
            availableCapacityBytes: 40_000_000_000, capacitySource: .importantUsage)
        let context = try await CodexCleanupContext.capture(loader: SnapshotLoader(repository: reader),
            scanID: appSupportScanID(), nodeID: NodeID(2), rootNodeID: NodeID(1),
            rootPath: "/private/tmp/Root Space", snapshot: report, volume: facts)
        #expect(context.targetPath == "/private/tmp/Root Space/Docker 中文'")
        #expect(context.scanStartedAt == "1970-01-01T00:01:40Z")
        #expect(context.scanFinishedAt == "1970-01-01T00:03:20Z")
        #expect(context.volume?.available?.gb == "40.00")
        #expect(context.volume?.used?.bytes == "960000000000")
        #expect(context.pathSource.contains("NotLiveVerified"))
        #expect(context.withholdingPath().targetPath == nil)
        #expect(context.withholdingPath().volume == context.volume)
        #expect(!String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("/private/tmp"))
    }
    @Test("Mixed revision and invalid path components fail closed")
    func rejectsUnsafe() async throws {
        let (reader, report) = try await fixture()
        await reader.setState(state(revision: 8))
        await #expect(throws: AgentAnalysisSnapshot.CaptureError.unstableSnapshot) {
            try await CodexCleanupContext.capture(loader: SnapshotLoader(repository: reader),
                scanID: appSupportScanID(), nodeID: NodeID(2), rootNodeID: NodeID(1),
                rootPath: "/private/tmp/fixture", snapshot: report, volume: nil)
        }
        let (badReader, badReport) = try await fixture(name: "../escape")
        await #expect(throws: RuntimePathResolverError.invalidComponent) {
            try await CodexCleanupContext.capture(loader: SnapshotLoader(repository: badReader),
                scanID: appSupportScanID(), nodeID: NodeID(2), rootNodeID: NodeID(1),
                rootPath: "/private/tmp/fixture", snapshot: badReport, volume: nil)
        }
        let target = appSupportChildItem(id: 2, name: "unrooted", attributed: 1)
        await badReader.setAncestors([target.node], for: NodeID(2))
        await #expect(throws: RuntimePathResolverError.rootMismatch) {
            try await CodexCleanupContext.capture(loader: SnapshotLoader(repository: badReader),
                scanID: appSupportScanID(), nodeID: NodeID(2), rootNodeID: NodeID(1),
                rootPath: "/private/tmp/fixture", snapshot: badReport, volume: nil)
        }
    }
    @Test("Bundled CLI locator requires an executable file, no guessed PATH or repository fallback")
    func helperLocator() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("sj-cli-locator-\(UUID()).app")
        defer { try? FileManager.default.removeItem(at: app) }
        #expect(CodexCleanupContext.bundledCLIPath(bundleURL: app) == nil)
        let helper = app.appendingPathComponent("Contents/Helpers/spacejudge-agent-cli")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: helper.path)
        #expect(CodexCleanupContext.bundledCLIPath(bundleURL: app) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        #expect(CodexCleanupContext.bundledCLIPath(bundleURL: app) == helper.path)
    }
}
