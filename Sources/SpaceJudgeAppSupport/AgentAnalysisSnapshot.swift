import Foundation
import SpaceJudgeDomain

/// Versioned, bounded metadata hand-off. It contains no runtime filesystem path.
public struct AgentAnalysisSnapshot: Codable, Sendable, Equatable {
    public struct Size: Codable, Sendable, Equatable {
        public let bytes: String
        public let gb: String
        public init(_ value: UInt64) {
            bytes = String(value)
            // No UInt64 addition overflow, floating point, or locale dependence.
            var hundredths = value / 10_000_000
            if value % 10_000_000 >= 5_000_000 { hundredths += 1 }
            gb = "\(hundredths / 100).\(hundredths % 100 < 10 ? "0" : "")\(hundredths % 100)"
        }
    }
    public struct Node: Codable, Sendable, Equatable {
        public let nodeId: String
        public let parentId: String?
        public let name: String
        public let nameTruncated: Bool
        public let kind: String
        public let flags: UInt32
        public let attributed: Size
        public let aggregateComplete: Bool?
    }
    public struct Page: Codable, Sendable, Equatable {
        public let nodeId: String
        public let totalChildren: String
        public let childIds: [String]
        public let truncated: Bool
    }
    public let schemaVersion: Int
    public let scanId: String
    public let revision: String
    public let scanStatus: String
    public let capturedAt: String
    public let scopeNodeId: String
    public let metric: String
    public let nodes: [Node]
    public let pages: [Page]
    public let captureTruncated: Bool
    public let scanIssueCount: String
    public let scanInaccessibleCount: String

    public enum CaptureError: Error { case unstableSnapshot, missingScope }

    /// At most 2,000 nodes, 64 directory pages, 50 children/page, depth four.
    /// Missing pages are *unknown*, not empty directories. Large children first.
    public static func capture(loader: SnapshotLoader, scanID: ScanID,
                               nodeID: NodeID) async throws -> Self {
        guard let before = try await loader.state(scanID: scanID),
              before.status != .running, before.status != .cancelling else {
            throw CaptureError.unstableSnapshot
        }
        guard let scope = try await loader.ancestors(scanID: scanID, nodeID: nodeID).last,
              scope.id == nodeID else { throw CaptureError.missingScope }
        let name = try await loader.name(id: scope.name, scanID: scanID)
        let aggregate = try await loader.aggregate(scanID: scanID, nodeID: nodeID)
        var nodes = [makeNode(scope, name: name, parent: nil,
                              bytes: aggregate?.attributedBytes ?? scope.attributedBytes,
                              complete: aggregate?.isComplete)]
        var pages: [Page] = []
        var queue: [(NodeID, Int)] = scope.kind.isDirectoryLike ? [(nodeID, 0)] : []
        var visited: Set<NodeID> = [nodeID]
        var cursor = 0
        var truncated = false
        while cursor < queue.count, pages.count < 64, nodes.count < 2_000 {
            try Task.checkCancellation()
            let (parent, depth) = queue[cursor]
            cursor += 1
            let page = try await loader.loadChildren(scanID: scanID, nodeID: parent, limit: 50)
            guard page.snapshotRevision == before.lastRevision else {
                throw CaptureError.unstableSnapshot
            }
            let children = Array(page.items.prefix(2_000 - nodes.count))
            let pageTruncated = UInt64(children.count) < page.totalCount
            truncated = truncated || pageTruncated
            pages.append(Page(nodeId: parent.description, totalChildren: String(page.totalCount),
                              childIds: children.map { $0.node.id.description }, truncated: pageTruncated))
            for child in children {
                guard visited.insert(child.node.id).inserted else { throw CaptureError.unstableSnapshot }
                nodes.append(makeNode(child.node, name: child.name, parent: parent.description,
                                      bytes: child.effectiveAttributedBytes, complete: nil))
                if child.node.kind.isDirectoryLike {
                    if depth + 1 < 4 { queue.append((child.node.id, depth + 1)) }
                    else { truncated = true }
                }
            }
        }
        truncated = truncated || cursor < queue.count
        guard try await loader.state(scanID: scanID) == before else {
            throw CaptureError.unstableSnapshot
        }
        return Self(schemaVersion: 1, scanId: scanID.description, revision: before.lastRevision.description,
                    scanStatus: String(describing: before.status),
                    capturedAt: ISO8601DateFormatter().string(from: Date()),
                    scopeNodeId: nodeID.description, metric: "attributedBytes",
                    nodes: nodes, pages: pages, captureTruncated: truncated,
                    scanIssueCount: String(before.issueCount),
                    scanInaccessibleCount: String(before.inaccessibleCount))
    }

    private static func makeNode(_ node: NodeRecord, name: NameRecord?, parent: String?,
                                 bytes: UInt64, complete: Bool?) -> Node {
        let fullName = name.map { String(decoding: $0.utf8, as: UTF8.self) } ?? "（名称不可用）"
        return Node(nodeId: node.id.description, parentId: parent, name: String(fullName.prefix(256)),
                    nameTruncated: fullName.count > 256, kind: String(describing: node.kind),
                    flags: node.flags.rawValue, attributed: Size(bytes), aggregateComplete: complete)
    }
}
