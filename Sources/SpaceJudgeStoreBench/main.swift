import Darwin
import Foundation
import SpaceJudgeDomain
import SpaceJudgeStore

// Repeatable synthetic store benchmark.
//
// It writes a multi-batch, scan-local-name tree with parent/child edges and
// complete directory aggregates, then measures direct-children query latency.
// It never asserts on wall time; callers compare the printed numbers.

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(code)
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func jsonDouble(_ value: Double) -> String {
    String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
}

// MARK: - Arguments

var nodeCount = 0
var databaseArgument: String?
var batchSize = 5_000
var branchFactor = 32
var childrenSamples = 200

var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--nodes":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
            fail("--nodes requires a positive integer", code: 2)
        }
        nodeCount = value
    case "--database":
        index += 1
        guard index < arguments.count else { fail("--database requires a path", code: 2) }
        databaseArgument = arguments[index]
    case "--batch":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
            fail("--batch requires a positive integer", code: 2)
        }
        batchSize = value
    case "--branching":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]), value >= 2 else {
            fail("--branching requires an integer >= 2", code: 2)
        }
        branchFactor = value
    case "--children-samples":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]), value >= 0 else {
            fail("--children-samples requires a non-negative integer", code: 2)
        }
        childrenSamples = value
    case "--help", "-h":
        print("usage: spacejudge-store-bench --nodes N [--database path] [--batch size] [--branching k]")
        exit(0)
    default:
        fail("unknown option \(argument)", code: 2)
    }
    index += 1
}

guard nodeCount > 0 else {
    fail("--nodes is required", code: 2)
}

// MARK: - Synthetic tree

/// Number of directories: roughly one per `branchFactor` nodes, at least one.
let directoryCount = max(1, nodeCount / (branchFactor + 1))
let namePool = 1_000

log("generating \(nodeCount) synthetic nodes (directories=\(directoryCount), branching=\(branchFactor))")
let generationStart = Date()

var parents = [Int](repeating: 0, count: nodeCount)
var isDirectory = [Bool](repeating: false, count: nodeCount)
var attributed = [UInt64](repeating: 0, count: nodeCount)

do {
    var directoriesCreated = 1
    isDirectory[0] = true
    var queue: [Int] = [0]
    var queueIndex = 0
    var next = 1
    while next < nodeCount {
        if queueIndex >= queue.count {
            // Safety net: attach remaining nodes to the root so the tree stays
            // connected even for tiny node counts.
            queueIndex = 0
        }
        let parent = queue[queueIndex]
        queueIndex += 1
        for _ in 0..<branchFactor {
            guard next < nodeCount else { break }
            parents[next] = parent
            if directoriesCreated < directoryCount {
                isDirectory[next] = true
                directoriesCreated += 1
                queue.append(next)
            } else {
                isDirectory[next] = false
                attributed[next] = 4096
            }
            next += 1
        }
    }
}

// Subtree fold: parents always have a smaller id than their children, so a
// reverse pass accumulates exact descendant totals.
var subtreeAttributed = attributed
var subtreeFiles = [UInt64](repeating: 0, count: nodeCount)
var subtreeDirectories = [UInt64](repeating: 0, count: nodeCount)
for id in 0..<nodeCount {
    if !isDirectory[id] {
        subtreeFiles[id] = 1
    }
}
for id in stride(from: nodeCount - 1, through: 1, by: -1) {
    let parent = parents[id]
    subtreeAttributed[parent] = subtreeAttributed[parent] + subtreeAttributed[id]
    subtreeFiles[parent] = subtreeFiles[parent] + subtreeFiles[id]
    subtreeDirectories[parent] = subtreeDirectories[parent] + subtreeDirectories[id]
    if isDirectory[id] {
        subtreeDirectories[parent] += 1
    }
}

log("tree generated in \(jsonDouble(Date().timeIntervalSince(generationStart)))s")

// MARK: - Persist

let databasePath: String
let isTemporaryDatabase: Bool
if let databaseArgument {
    databasePath = URL(fileURLWithPath: databaseArgument).path
    isTemporaryDatabase = false
    for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: databasePath + suffix) {
        fail("refusing to overwrite existing database file \(databasePath)\(suffix)", code: 2)
    }
    let parent = URL(fileURLWithPath: databasePath).deletingLastPathComponent().path
    guard FileManager.default.fileExists(atPath: parent) else {
        fail("database parent directory does not exist", code: 2)
    }
} else {
    databasePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("spacejudge-bench-\(UUID().uuidString).sqlite").path
    isTemporaryDatabase = true
}
log("database: \(databasePath)")

let repository: SQLiteSnapshotRepository
do {
    repository = try SQLiteSnapshotRepository(path: databasePath)
} catch {
    fail("cannot open store: \(error)", code: 3)
}

let scanID = ScanID()
let rootNodeID = NodeID(0)
let metadata = ScanMetadata(
    scanID: scanID,
    request: ScanRequest(
        root: ScanRoot(fileSystemPath: "/synthetic", displayName: "synthetic")
    ),
    startedAt: Date(),
    rootNodeID: rootNodeID
)

do {
    try await repository.begin(metadata)
} catch {
    await repository.close()
    fail("begin failed: \(error)", code: 3)
}

log("writing batches of \(batchSize)")
let writeStart = Date()
var batches = 0
var seenNames: Set<UInt64> = []
var committed = 0
while committed < nodeCount {
    let upper = min(committed + batchSize, nodeCount)
    var names: [NameRecord] = []
    var nodes: [NodeRecord] = []
    var aggregates: [DirectoryAggregateRecord] = []

    for id in committed..<upper {
        let nameID = NameID(UInt64(id % namePool))
        if seenNames.insert(nameID.rawValue).inserted {
            names.append(NameRecord(id: nameID, bytes: Array("name-\(nameID.rawValue)".utf8)))
        }
        let directory = isDirectory[id]
        nodes.append(
            NodeRecord(
                id: NodeID(UInt64(id)),
                scanID: scanID,
                parentID: id == 0 ? nil : NodeID(UInt64(parents[id])),
                name: nameID,
                kind: directory ? .directory : .regularFile,
                flags: [],
                logicalBytes: directory ? nil : 4096,
                allocatedBytes: directory ? nil : 4096,
                attributedBytes: attributed[id],
                modifiedAt: nil,
                deviceID: nil,
                fileID: nil
            )
        )
        if directory {
            aggregates.append(
                DirectoryAggregateRecord(
                    nodeID: NodeID(UInt64(id)),
                    logicalBytes: subtreeAttributed[id],
                    allocatedBytes: subtreeAttributed[id],
                    attributedBytes: subtreeAttributed[id],
                    descendantFileCount: subtreeFiles[id],
                    descendantDirectoryCount: subtreeDirectories[id],
                    inaccessibleDescendantCount: 0,
                    isComplete: true
                )
            )
        }
    }

    batches += 1
    let revision = Revision(UInt64(batches))
    let batch = NodeBatch(
        scanID: scanID,
        revision: revision,
        names: names,
        nodes: nodes,
        directoryAggregates: aggregates
    )
    do {
        try await repository.write(batch)
    } catch {
        await repository.close()
        fail("batch \(batches) failed: \(error)", code: 3)
    }
    committed = upper
    if batches % 20 == 0 || committed == nodeCount {
        log("  wrote \(committed)/\(nodeCount) nodes")
    }
}

let writeSeconds = Date().timeIntervalSince(writeStart)
log("write finished in \(jsonDouble(writeSeconds))s (\(jsonDouble(Double(nodeCount) / max(writeSeconds, 0.000001))) nodes/s)")

// MARK: - Finish and verify persisted counts

let directoryNodeCount = isDirectory.filter { $0 }.count
let fileNodeCount = nodeCount - directoryNodeCount
let summary = ScanSummary(
    scanID: scanID,
    status: .completed,
    startedAt: Date(),
    finishedAt: Date(),
    fileCount: UInt64(fileNodeCount),
    directoryCount: UInt64(directoryNodeCount),
    inaccessibleCount: 0,
    issueCount: 0,
    rootAttributedBytes: subtreeAttributed[0]
)
do {
    try await repository.finish(summary)
} catch {
    await repository.close()
    fail("finish failed: \(error)", code: 3)
}

let statistics: SnapshotStatistics
do {
    statistics = try await repository.statistics(scanID)
} catch {
    await repository.close()
    fail("statistics failed: \(error)", code: 3)
}
guard statistics.nodeCount == UInt64(nodeCount) else {
    await repository.close()
    fail("persisted node count \(statistics.nodeCount) != \(nodeCount)", code: 3)
}
guard statistics.nameCount == UInt64(seenNames.count) else {
    await repository.close()
    fail("persisted name count \(statistics.nameCount) != \(seenNames.count)", code: 3)
}
guard statistics.aggregateCount == UInt64(directoryNodeCount) else {
    await repository.close()
    fail("persisted aggregate count \(statistics.aggregateCount) != \(directoryNodeCount)", code: 3)
}

// MARK: - Children query latency

var samples: [Double] = []
if childrenSamples > 0 {
    let directoryIDs = (0..<nodeCount).filter { isDirectory[$0] }
    let stride = max(1, directoryIDs.count / childrenSamples)
    var selected: [Int] = []
    var cursor = 0
    while cursor < directoryIDs.count && selected.count < childrenSamples {
        selected.append(directoryIDs[cursor])
        cursor += stride
    }
    for id in selected {
        let start = Date()
        do {
            _ = try await repository.children(of: NodeID(UInt64(id)), in: scanID)
        } catch {
            await repository.close()
            fail("children query failed: \(error)", code: 3)
        }
        samples.append(Date().timeIntervalSince(start) * 1000)
    }
}
samples.sort()
func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let position = Int((Double(values.count - 1) * fraction).rounded())
    return values[position]
}
let p50 = percentile(samples, 0.5)
let p95 = percentile(samples, 0.95)

// MARK: - Sizes, close, reopen and verify

func fileSize(_ path: String) -> Int64 {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return 0 }
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
}

let databaseBytes = fileSize(databasePath)
let walBytes = fileSize(databasePath + "-wal")
let shmBytes = fileSize(databasePath + "-shm")
await repository.close()
let databaseBytesAfterClose = fileSize(databasePath)
let walBytesAfterClose = fileSize(databasePath + "-wal")
let shmBytesAfterClose = fileSize(databasePath + "-shm")

// Reopen the committed snapshot through a separate read-only connection.
let reopened: SQLiteSnapshotRepository
do {
    reopened = try SQLiteSnapshotRepository.openReadOnly(path: databasePath)
} catch {
    fail("reopen failed: \(error)", code: 3)
}
do {
    guard let state = try await reopened.scanState(scanID) else {
        await reopened.close()
        fail("reopened scan state missing", code: 3)
    }
    guard state.status == .completed else {
        await reopened.close()
        fail("reopened status \(state.status) != completed", code: 3)
    }
    guard state.lastRevision == Revision(UInt64(batches)) else {
        await reopened.close()
        fail("reopened revision \(state.lastRevision) != \(batches)", code: 3)
    }
    guard let rootAggregate = try await reopened.aggregate(of: rootNodeID, in: scanID),
          rootAggregate.isComplete else {
        await reopened.close()
        fail("reopened root aggregate missing or incomplete", code: 3)
    }
    let rootChildren = try await reopened.children(of: rootNodeID, in: scanID)
    guard !rootChildren.isEmpty else {
        await reopened.close()
        fail("reopened root has no children", code: 3)
    }
    log(
        "reopened read-only: status=\(state.status) revision=\(state.lastRevision) "
            + "rootChildren=\(rootChildren.count) rootAggregateComplete=\(rootAggregate.isComplete)"
    )
} catch {
    await reopened.close()
    fail("reopen verification failed: \(error)", code: 3)
}
await reopened.close()

if isTemporaryDatabase {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: databasePath + suffix)
    }
    log("removed temporary database")
} else {
    log("kept database at \(databasePath)")
}

let json = "{"
    + "\"nodes\":\(nodeCount),"
    + "\"directories\":\(directoryNodeCount),"
    + "\"batches\":\(batches),"
    + "\"wallSeconds\":\(jsonDouble(writeSeconds)),"
    + "\"nodesPerSecond\":\(jsonDouble(Double(nodeCount) / max(writeSeconds, 0.000001))),"
    + "\"databaseBytes\":\(databaseBytes),"
    + "\"walBytes\":\(walBytes),"
    + "\"shmBytes\":\(shmBytes),"
    + "\"databaseBytesAfterClose\":\(databaseBytesAfterClose),"
    + "\"walBytesAfterClose\":\(walBytesAfterClose),"
    + "\"shmBytesAfterClose\":\(shmBytesAfterClose),"
    + "\"verifiedNodeCount\":\(statistics.nodeCount),"
    + "\"verifiedNameCount\":\(statistics.nameCount),"
    + "\"verifiedAggregateCount\":\(statistics.aggregateCount),"
    + "\"verifiedStatus\":\"completed\","
    + "\"verifiedRevision\":\(batches),"
    + "\"reopenedStatus\":\"completed\","
    + "\"childrenSamples\":\(samples.count),"
    + "\"childrenP50Millis\":\(jsonDouble(p50)),"
    + "\"childrenP95Millis\":\(jsonDouble(p95))"
    + "}"
print(json)
