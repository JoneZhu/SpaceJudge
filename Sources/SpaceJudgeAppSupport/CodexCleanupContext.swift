import Foundation
import SpaceJudgeDomain

/// Explicitly reviewed desktop handoff context. Unlike the legacy ACP report,
/// this may contain a session-resolved absolute path; it is never stored in SQLite.
public struct CodexCleanupContext: Sendable, Equatable, Encodable {
    public let targetPath: String?
    public let pathSource: String
    public let scanStartedAt: String?
    public let scanFinishedAt: String?
    public let volume: Volume?

    public struct Volume: Sendable, Equatable, Encodable {
        public let total: AgentAnalysisSnapshot.Size?
        public let used: AgentAnalysisSnapshot.Size?
        public let available: AgentAnalysisSnapshot.Size?
        public let source: String
        public init(_ facts: VolumeFacts) {
            total = facts.totalCapacityBytes.map(AgentAnalysisSnapshot.Size.init)
            used = facts.usedBytes.map(AgentAnalysisSnapshot.Size.init)
            available = facts.availableCapacityBytes.map(AgentAnalysisSnapshot.Size.init)
            source = String(describing: facts.capacitySource)
        }
    }

    public init(targetPath: String? = nil, scanStartedAt: String? = nil,
                scanFinishedAt: String? = nil, volume: Volume? = nil) {
        self.targetPath = targetPath
        pathSource = targetPath == nil ? "withheldOrUnavailable" : "sessionRootAndSnapshotAncestorsNotLiveVerified"
        self.scanStartedAt = scanStartedAt; self.scanFinishedAt = scanFinishedAt; self.volume = volume
    }

    public func withholdingPath() -> Self {
        Self(scanStartedAt: scanStartedAt, scanFinishedAt: scanFinishedAt, volume: volume)
    }

    public static func capture(loader: SnapshotLoader, scanID: ScanID, nodeID: NodeID,
                               rootNodeID: NodeID, rootPath: String,
                               snapshot: AgentAnalysisSnapshot, volume: VolumeFacts?) async throws -> Self {
        guard snapshot.scanId == scanID.description, snapshot.scopeNodeId == nodeID.description,
              let before = try await loader.state(scanID: scanID),
              before.lastRevision.description == snapshot.revision,
              before.status != .running, before.status != .cancelling else {
            throw AgentAnalysisSnapshot.CaptureError.unstableSnapshot
        }
        let nodes = try await loader.ancestors(scanID: scanID, nodeID: nodeID)
        guard nodes.last?.id == nodeID,
              nodes.allSatisfy({ $0.scanID == scanID }) else {
            throw RuntimePathResolverError.invalidChain
        }
        for index in nodes.indices.dropFirst() {
            guard nodes[index].parentID == nodes[index - 1].id else {
                throw RuntimePathResolverError.invalidChain
            }
        }
        var names: [NameRecord] = []
        for node in nodes {
            guard let name = try await loader.name(id: node.name, scanID: scanID) else {
                throw RuntimePathResolverError.invalidChain
            }
            names.append(name)
        }
        let path = try RuntimePathResolver(rootPath: rootPath, rootNodeID: rootNodeID)
            .url(ancestorNodes: nodes, names: names).path
        guard try await loader.state(scanID: scanID) == before else {
            throw AgentAnalysisSnapshot.CaptureError.unstableSnapshot
        }
        let formatter = ISO8601DateFormatter()
        return Self(targetPath: path, scanStartedAt: formatter.string(from: before.startedAt),
                    scanFinishedAt: before.finishedAt.map(formatter.string), volume: volume.map(Volume.init))
    }

    /// Does not execute a process or search arbitrary directories.
    public static func bundledCLIPath(bundleURL: URL) -> String? {
        let url = bundleURL.appendingPathComponent("Contents/Helpers/spacejudge-agent-cli")
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
              !directory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }
}
