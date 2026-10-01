import Foundation
import SpaceJudgeDomain
import SpaceJudgeStore

/// Read-only snapshot queries: `status`, `children`, `hotspots`, `issues`.
///
/// All four open the SQLite snapshot through the repository's read-only entry
/// point, validate their identifiers before touching storage, and emit exactly
/// one JSON object. No full path is ever produced.
public enum AgentQueryCommands {
    /// Upper bound for `children --limit`, matching the MCP tool contract.
    public static let maximumChildrenLimit = 100
    public static let minimumChildrenLimit = 1
    /// Default page size when `--limit` is omitted.
    public static let defaultChildrenLimit = 30
    /// Bounded issue sample count.
    public static let maximumIssueSamples = 20

    public static func status(databasePath: String, scanIDText: String) async -> AgentCLIResult {
        let repository: SQLiteSnapshotRepository
        do {
            _ = try parseScanID(scanIDText)
            repository = try openRepository(databasePath)
        } catch {
            return AgentCLIResult.failure(AgentCLIErrorClassifier.classify(error))
        }
        let result = await performStatus(repository: repository, scanIDText: scanIDText)
        await repository.close()
        return result
    }

    public static func children(
        databasePath: String,
        scanIDText: String,
        nodeIDText: String,
        limitText: String
    ) async -> AgentCLIResult {
        let repository: SQLiteSnapshotRepository
        do {
            _ = try parseScanID(scanIDText)
            guard UInt64(nodeIDText) != nil else {
                throw AgentCLIError(code: .invalidArgument)
            }
            _ = try parseLimit(limitText)
            repository = try openRepository(databasePath)
        } catch {
            return AgentCLIResult.failure(AgentCLIErrorClassifier.classify(error))
        }
        let result = await performChildren(
            repository: repository,
            scanIDText: scanIDText,
            nodeIDText: nodeIDText,
            limitText: limitText
        )
        await repository.close()
        return result
    }

    public static func hotspots(
        databasePath: String,
        scanIDText: String,
        nodeIDText: String,
        limitText: String,
        minBytesText: String
    ) async -> AgentCLIResult {
        let repository: SQLiteSnapshotRepository
        do {
            _ = try parseScanID(scanIDText)
            guard UInt64(nodeIDText) != nil else {
                throw AgentCLIError(code: .invalidArgument)
            }
            _ = try parseHotspotsLimit(limitText)
            _ = try parseMinimumBytes(minBytesText)
            repository = try openRepository(databasePath)
        } catch {
            return AgentCLIResult.failure(AgentCLIErrorClassifier.classify(error))
        }
        let result = await performHotspots(
            repository: repository,
            scanIDText: scanIDText,
            nodeIDText: nodeIDText,
            limitText: limitText,
            minBytesText: minBytesText
        )
        await repository.close()
        return result
    }

    public static func issues(databasePath: String, scanIDText: String) async -> AgentCLIResult {
        let repository: SQLiteSnapshotRepository
        do {
            _ = try parseScanID(scanIDText)
            repository = try openRepository(databasePath)
        } catch {
            return AgentCLIResult.failure(AgentCLIErrorClassifier.classify(error))
        }
        let result = await performIssues(repository: repository, scanIDText: scanIDText)
        await repository.close()
        return result
    }

    // MARK: Implementations

    private static func performStatus(
        repository: SQLiteSnapshotRepository,
        scanIDText: String
    ) async -> AgentCLIResult {
        do {
            let scanID = try parseScanID(scanIDText)
            guard let state = try await repository.scanState(scanID) else {
                throw AgentCLIError(code: .notFound)
            }
            let summary = try await repository.scanSummary(scanID)
            let statistics = try await repository.statistics(scanID)
            let issues = try await repository.issueSummary(scanID)
            let volume = summary?.volume

            let document: [String: Any] = [
                "type": "status",
                "scanId": state.scanID.description,
                "status": AgentJSON.statusName(state.status),
                "startedAt": AgentJSON.dateOrNull(state.startedAt),
                "finishedAt": AgentJSON.dateOrNull(state.finishedAt),
                "fileCount": AgentJSON.uint64(state.fileCount),
                "directoryCount": AgentJSON.uint64(state.directoryCount),
                "inaccessibleCount": AgentJSON.uint64(state.inaccessibleCount),
                "issueCount": AgentJSON.uint64(state.issueCount),
                "rootAttributedBytes": AgentJSON.uint64(state.rootAttributedBytes),
                "rootAttributedGB": AgentJSON.gigabytesOrNull(state.rootAttributedBytes),
                "nodeCount": AgentJSON.uint64(statistics.nodeCount),
                "nameCount": AgentJSON.uint64(statistics.nameCount),
                "aggregateCount": AgentJSON.uint64(statistics.aggregateCount),
                "lastRevision": AgentJSON.revision(state.lastRevision),
                "capacityBytes": AgentJSON.uint64OrNull(volume?.totalCapacityBytes),
                "capacityGB": AgentJSON.gigabytesOrNull(volume?.totalCapacityBytes),
                "availableBytes": AgentJSON.uint64OrNull(volume?.availableCapacityBytes),
                "availableGB": AgentJSON.gigabytesOrNull(volume?.availableCapacityBytes),
                "usedBytes": AgentJSON.uint64OrNull(volume?.usedBytes),
                "usedGB": AgentJSON.gigabytesOrNull(volume?.usedBytes),
                "issues": aggregatedCategories(issues)
            ]
            return AgentCLIResult.output(AgentJSON.line(document))
        } catch {
            return AgentCLIResult.failure(AgentCLIErrorClassifier.classify(error))
        }
    }

    private static func performChildren(
        repository: SQLiteSnapshotRepository,
        scanIDText: String,
        nodeIDText: String,
        limitText: String
    ) async -> AgentCLIResult {
        do {
            let scanID = try parseScanID(scanIDText)
            guard let nodeValue = UInt64(nodeIDText) else {
                throw AgentCLIError(code: .invalidArgument)
            }
            let limit = try parseLimit(limitText)
            guard try await repository.scanState(scanID) != nil else {
                throw AgentCLIError(code: .notFound)
            }
            let nodeID = NodeID(nodeValue)
            // `ancestors` throws when the node does not exist, which lets us
            // distinguish "no children" from "bad node id" without guessing.
            do {
                _ = try await repository.ancestors(of: nodeID, in: scanID)
            } catch SnapshotStoreError.missingParent {
                throw AgentCLIError(code: .notFound)
            } catch SnapshotStoreError.ancestorCycle {
                throw AgentCLIError(code: .notFound)
            }

            let page = try await repository.childPage(of: nodeID, in: scanID, limit: limit)
            let items: [[String: Any]] = page.items.map { item in
                childItemFields(
                    node: item.node,
                    name: item.name,
                    effectiveAttributedBytes: item.effectiveAttributedBytes
                )
            }
            let document: [String: Any] = [
                "type": "children",
                "scanId": scanID.description,
                "nodeId": AgentJSON.uint64(nodeID.rawValue),
                "limit": limit,
                "totalCount": AgentJSON.uint64(page.totalCount),
                "snapshotRevision": AgentJSON.revision(page.snapshotRevision),
                "items": items
            ]
            return AgentCLIResult.output(AgentJSON.line(document))
        } catch let error as AgentCLIError {
            return AgentCLIResult.failure(error)
        } catch {
            return AgentCLIResult.failure(AgentCLIErrorClassifier.classify(error))
        }
    }

    private static func performIssues(
        repository: SQLiteSnapshotRepository,
        scanIDText: String
    ) async -> AgentCLIResult {
        do {
            let scanID = try parseScanID(scanIDText)
            guard try await repository.scanState(scanID) != nil else {
                throw AgentCLIError(code: .notFound)
            }
            let issues = try await repository.issueSummary(scanID)

            let samples = issues
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    if lhs.category != rhs.category {
                        return AgentJSON.issueCategoryName(lhs.category)
                            < AgentJSON.issueCategoryName(rhs.category)
                    }
                    return (lhs.errnoValue ?? 0) < (rhs.errnoValue ?? 0)
                }
                .prefix(maximumIssueSamples)
                .map { issue -> [String: Any] in
                    [
                        "category": AgentJSON.issueCategoryName(issue.category),
                        "errno": AgentJSON.int32OrNull(issue.errnoValue),
                        "count": AgentJSON.uint64(issue.count)
                    ]
                }

            let document: [String: Any] = [
                "type": "issues",
                "scanId": scanID.description,
                "categories": aggregatedCategories(issues),
                "samples": Array(samples)
            ]
            return AgentCLIResult.output(AgentJSON.line(document))
        } catch {
            return AgentCLIResult.failure(AgentCLIErrorClassifier.classify(error))
        }
    }

    // MARK: Hotspots

    private static func performHotspots(
        repository: SQLiteSnapshotRepository,
        scanIDText: String,
        nodeIDText: String,
        limitText: String,
        minBytesText: String
    ) async -> AgentCLIResult {
        do {
            let scanID = try parseScanID(scanIDText)
            guard let nodeValue = UInt64(nodeIDText) else {
                throw AgentCLIError(code: .invalidArgument)
            }
            let limit = try parseHotspotsLimit(limitText)
            let minimumBytes = try parseMinimumBytes(minBytesText)
            let outcome = try await AgentHotspotsQuery.run(
                repository: repository,
                scanID: scanID,
                scopeNodeID: NodeID(nodeValue),
                limit: limit,
                minimumBytes: minimumBytes
            )
            let items: [[String: Any]] = outcome.items.map { item in
                var fields = childItemFields(
                    node: item.node,
                    name: item.name,
                    effectiveAttributedBytes: item.effectiveAttributedBytes
                )
                fields["depth"] = item.depth
                return fields
            }
            let document: [String: Any] = [
                "type": "hotspots",
                "scanId": outcome.scanID.description,
                "scopeNodeId": AgentJSON.uint64(outcome.scopeNodeID.rawValue),
                "status": AgentJSON.statusName(outcome.status),
                "snapshotComplete": outcome.snapshotComplete,
                "snapshotRevision": AgentJSON.revision(outcome.snapshotRevision),
                "limit": outcome.limit,
                "minimumBytes": AgentJSON.uint64(outcome.minimumBytes),
                "minimumGB": AgentJSON.gigabytes(outcome.minimumBytes),
                "overlapSemantics": "ancestorInclusive",
                "truncated": outcome.truncated,
                "items": items
            ]
            return AgentCLIResult.output(AgentJSON.line(document))
        } catch let error as AgentCLIError {
            return AgentCLIResult.failure(error)
        } catch {
            return AgentCLIResult.failure(AgentCLIErrorClassifier.classify(error))
        }
    }

    // MARK: Helpers

    static func parseScanID(_ text: String) throws -> ScanID {
        guard let uuid = UUID(uuidString: text) else {
            throw AgentCLIError(code: .invalidArgument)
        }
        return ScanID(rawValue: uuid)
    }

    static func parseLimit(_ text: String) throws -> Int {
        if text.isEmpty { return defaultChildrenLimit }
        guard let value = Int(text),
              value >= minimumChildrenLimit,
              value <= maximumChildrenLimit else {
            throw AgentCLIError(code: .invalidArgument)
        }
        return value
    }

    static func parseHotspotsLimit(_ text: String) throws -> Int {
        if text.isEmpty { return AgentHotspotsLimits.defaultLimit }
        guard let value = Int(text),
              value >= AgentHotspotsLimits.minimumLimit,
              value <= AgentHotspotsLimits.maximumLimit else {
            throw AgentCLIError(code: .invalidArgument)
        }
        return value
    }

    static func parseMinimumBytes(_ text: String) throws -> UInt64 {
        if text.isEmpty { return AgentHotspotsLimits.defaultMinimumBytes }
        guard let value = UInt64(text) else {
            throw AgentCLIError(code: .invalidArgument)
        }
        return value
    }

    /// The node/name/flags/time/capacity fields shared by `children.items[]`
    /// and `hotspots.items[]`, kept in one place so the payloads cannot drift.
    /// `hotspots` adds `depth` on top.
    private static func childItemFields(
        node: NodeRecord,
        name: NameRecord,
        effectiveAttributedBytes: UInt64
    ) -> [String: Any] {
        [
            "nodeId": AgentJSON.uint64(node.id.rawValue),
            "parentId": node.parentID.map { AgentJSON.uint64($0.rawValue) } ?? NSNull(),
            "name": String(decoding: name.utf8, as: UTF8.self),
            "nameBase64": name.utf8.base64EncodedString(),
            "kind": AgentJSON.kindName(node.kind),
            "flags": AgentJSON.flagNames(node.flags),
            "logicalBytes": AgentJSON.uint64OrNull(node.logicalBytes),
            "logicalGB": AgentJSON.gigabytesOrNull(node.logicalBytes),
            "allocatedBytes": AgentJSON.uint64OrNull(node.allocatedBytes),
            "allocatedGB": AgentJSON.gigabytesOrNull(node.allocatedBytes),
            "attributedBytes": AgentJSON.uint64(node.attributedBytes),
            "attributedGB": AgentJSON.gigabytes(node.attributedBytes),
            "effectiveAttributedBytes": AgentJSON.uint64(effectiveAttributedBytes),
            "effectiveAttributedGB": AgentJSON.gigabytes(effectiveAttributedBytes),
            "modifiedAt": AgentJSON.dateOrNull(node.modifiedAt)
        ]
    }

    private static func openRepository(_ databasePath: String) throws -> SQLiteSnapshotRepository {
        try AgentCLIPath.requireReadableFile(databasePath)
        do {
            return try SQLiteSnapshotRepository.openReadOnly(path: databasePath)
        } catch let error as SnapshotStoreError {
            throw AgentCLIErrorClassifier.classify(error)
        } catch {
            throw AgentCLIError(code: .internalError)
        }
    }

    private static func aggregatedCategories(
        _ issues: [IssueAggregateSummary]
    ) -> [[String: Any]] {
        var totals: [ScanIssueCategory: UInt64] = [:]
        for issue in issues {
            let (sum, overflow) = (totals[issue.category] ?? 0)
                .addingReportingOverflow(issue.count)
            totals[issue.category] = overflow ? UInt64.max : sum
        }
        return totals
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return AgentJSON.issueCategoryName(lhs.key)
                    < AgentJSON.issueCategoryName(rhs.key)
            }
            .map { entry in
                [
                    "category": AgentJSON.issueCategoryName(entry.key),
                    "count": AgentJSON.uint64(entry.value)
                ]
            }
    }
}
