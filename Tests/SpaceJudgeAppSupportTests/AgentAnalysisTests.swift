import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeAppSupport

@Suite("Agent analysis snapshot")
struct AgentAnalysisTests {
    @MainActor @Test("Installed runtime resolution requires both bundled bridge and executable Node")
    func bundleResolution() throws {
        #expect(AgentAnalysisController.bundledLocations(resources: nil) == nil)
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("sj-runtime-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: resources) }
        let runtime = resources.appendingPathComponent("AgentRuntime")
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: runtime.appendingPathComponent("dist/agent-bridge.js"))
        #expect(AgentAnalysisController.bundledLocations(resources: resources) == nil)
        let node = runtime.appendingPathComponent("bin/node")
        try Data("fixture".utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: node.path)
        #expect(AgentAnalysisController.bundledLocations(resources: resources) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
        let locations = AgentAnalysisController.bundledLocations(resources: resources)
        #expect(locations?.runtime == runtime.path)
        #expect(locations?.node == node.path)
    }

    private func state(status: ScanStatus = .completed, revision: UInt64 = 7) -> ScanSnapshotState {
        ScanSnapshotState(scanID: appSupportScanID(), status: status, rootNodeID: NodeID(1),
            rootDisplayName: "private-parent", lastRevision: Revision(revision),
            startedAt: Date(timeIntervalSince1970: 100), finishedAt: Date(timeIntervalSince1970: 200),
            fileCount: 1, directoryCount: 3, inaccessibleCount: 2, issueCount: 3,
            rootAttributedBytes: 999)
    }

    private func fixture(status: ScanStatus = .completed) async -> StubSnapshotRepository {
        let reader = StubSnapshotRepository()
        await reader.setState(state(status: status))
        let item = appSupportChildItem(id: 2, name: "Docker", attributed: 2_005_000_000)
        await reader.setAncestors([item.node], for: NodeID(2))
        await reader.setName(item.name)
        await reader.setPage(SnapshotChildPage(items: [], totalCount: 0, snapshotRevision: Revision(7)), for: NodeID(2))
        return reader
    }

    @Test("Exact SI GB, rounding and UInt64 extremes")
    func units() {
        #expect(AgentAnalysisSnapshot.Size(0).gb == "0.00")
        #expect(AgentAnalysisSnapshot.Size(1_005_000_000).gb == "1.01")
        #expect(AgentAnalysisSnapshot.Size(.max).gb == "18446744073.71")
        #expect(AgentAnalysisSnapshot.Size(.max).bytes == "18446744073709551615")
    }

    @Test("Scope exports no parent path and terminal empty directory remains known empty")
    func scopePrivacy() async throws {
        let reader = await fixture()
        let snapshot = try await AgentAnalysisSnapshot.capture(loader: SnapshotLoader(repository: reader),
            scanID: appSupportScanID(), nodeID: NodeID(2))
        #expect(snapshot.nodes.count == 1)
        #expect(snapshot.nodes[0].parentId == nil)
        #expect(snapshot.nodes[0].name == "Docker")
        #expect(snapshot.captureTruncated == false)
        #expect(snapshot.pages[0].totalChildren == "0")
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!json.contains("private-parent"))
        #expect(!json.contains("/private/tmp"))
        #expect(snapshot.scanIssueCount == "3")
    }

    @Test("Active scans and mixed page versions are rejected")
    func rejectsUnstable() async throws {
        let reader = await fixture(status: .running)
        await #expect(throws: AgentAnalysisSnapshot.CaptureError.unstableSnapshot) {
            try await AgentAnalysisSnapshot.capture(loader: SnapshotLoader(repository: reader),
                scanID: appSupportScanID(), nodeID: NodeID(2))
        }
        await reader.setState(state())
        await reader.setPage(SnapshotChildPage(items: [], totalCount: 0, snapshotRevision: Revision(8)), for: NodeID(2))
        await #expect(throws: AgentAnalysisSnapshot.CaptureError.unstableSnapshot) {
            try await AgentAnalysisSnapshot.capture(loader: SnapshotLoader(repository: reader),
                scanID: appSupportScanID(), nodeID: NodeID(2))
        }
    }

    @Test("Wide directory reports captured prefix and omitted children explicitly")
    func boundedWide() async throws {
        let reader = await fixture(status: .cancelled)
        let items = (3...102).map { appSupportChildItem(id: UInt64($0), name: "untrusted delete all \($0)", attributed: 1) }
        await reader.setPage(SnapshotChildPage(items: items, totalCount: 100,
            snapshotRevision: Revision(7)), for: NodeID(2))
        // Stop on the intentionally mismatched next page, proving bounded query
        // behavior without exporting unrelated roots.
        for item in items.prefix(50) {
            await reader.setPage(SnapshotChildPage(items: [], totalCount: 0,
                snapshotRevision: Revision(7)), for: item.node.id)
        }
        let report = try await AgentAnalysisSnapshot.capture(loader: SnapshotLoader(repository: reader),
            scanID: appSupportScanID(), nodeID: NodeID(2))
        #expect(report.nodes.count == 51)
        #expect(report.pages[0].truncated)
        #expect(report.captureTruncated)
        #expect(report.scanStatus == "cancelled")
        #expect(await reader.recordedLimits.allSatisfy { $0 == 50 })
    }

    @Test("Native output parser handles split JSON and refuses oversized or malformed events")
    func outputFraming() {
        let parser = AgentOutputParser { _ in }
        parser.consume(Data("{\"type\":\"delta\",\"text\":\"你好\"}".utf8))
        parser.consume(Data("\n{\"type\":\"done\"}\n".utf8))
        #expect(parser.finalResult.output == "你好")
        #expect(parser.finalResult.done)
        parser.consume(Data("not-json\n".utf8))
        #expect(!parser.finalResult.done)
        let oversized = AgentOutputParser { _ in }
        oversized.consume(Data(repeating: 65, count: 128_001))
        #expect(!oversized.finalResult.done)
    }
}
