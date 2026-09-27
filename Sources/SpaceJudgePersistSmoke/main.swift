import Darwin
import Foundation
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeUseCases

// Phase 2 persistence smoke CLI.
//
// It scans exactly the directory the user passes, persists into exactly the
// new database path the user passes, and prints stable JSON to stdout. Errors
// and progress go to stderr. The absolute scan path is never printed.

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(code)
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func databaseByteCount(_ path: String) throws -> Int64 {
    var total: Int64 = 0
    for suffix in ["", "-wal", "-shm"] {
        let candidate = path + suffix
        guard FileManager.default.fileExists(atPath: candidate) else { continue }
        let attributes = try FileManager.default.attributesOfItem(atPath: candidate)
        total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
    return total
}

// MARK: - Arguments

var engineName: String?
var databaseArgument: String?
var directoryArgument: String?
var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--engine":
        index += 1
        guard index < arguments.count else { fail("--engine requires reference|bulk", code: 2) }
        engineName = arguments[index]
    case "--database":
        index += 1
        guard index < arguments.count else { fail("--database requires a new path", code: 2) }
        databaseArgument = arguments[index]
    case "--help", "-h":
        print("usage: spacejudge-persist-smoke --engine reference|bulk --database <new-db-path> <directory>")
        exit(0)
    default:
        if argument.hasPrefix("-") { fail("unknown option \(argument)", code: 2) }
        if directoryArgument != nil { fail("only one directory may be scanned", code: 2) }
        directoryArgument = argument
    }
    index += 1
}

guard let engineName, engineName == "reference" || engineName == "bulk" else {
    fail("--engine must be reference or bulk", code: 2)
}
guard let databaseArgument, !databaseArgument.isEmpty else {
    fail("--database is required", code: 2)
}
guard let directoryArgument else {
    fail("a directory argument is required", code: 2)
}

// MARK: - Input validation

var inputStat = stat()
let directoryPath = URL(fileURLWithPath: directoryArgument).path
let statResult = directoryPath.withCString { lstat($0, &inputStat) }
guard statResult == 0 else {
    fail("cannot read \(directoryArgument): \(String(cString: strerror(errno)))", code: 2)
}
guard (inputStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
    fail("\(directoryArgument) is not a directory", code: 2)
}

let databasePath = URL(fileURLWithPath: databaseArgument).path
for suffix in ["", "-wal", "-shm"] {
    if FileManager.default.fileExists(atPath: databasePath + suffix) {
        fail("refusing to overwrite existing database file \(databaseArgument)\(suffix)", code: 2)
    }
}
let databaseParent = URL(fileURLWithPath: databasePath).deletingLastPathComponent().path
guard FileManager.default.fileExists(atPath: databaseParent) else {
    fail("database parent directory does not exist", code: 2)
}

// MARK: - Setup

let enumerator: any DirectoryEnumerator = engineName == "reference"
    ? ReferenceEnumerator()
    : DarwinBulkEnumerator()
let engine = FileSystemScanEngine(configuration: ScanConfiguration(enumerator: enumerator))

let repository: SQLiteSnapshotRepository
do {
    repository = try SQLiteSnapshotRepository(path: databasePath)
} catch {
    fail("cannot open store: \(error)", code: 4)
}

let displayName = URL(fileURLWithPath: directoryPath).lastPathComponent
let request = ScanRequest(root: ScanRoot(fileSystemPath: directoryPath, displayName: displayName))
let runner = PersistingScanRunner(engine: engine, repository: repository)

log("scanning with engine=\(engineName)")

let summary: ScanSummary
do {
    summary = try await runner.run(request)
} catch {
    await repository.close()
    fail("scan/store failed: \(error)", code: 3)
}

// MARK: - Query the persisted snapshot

do {
    guard let state = try await repository.scanState(summary.scanID) else {
        await repository.close()
        fail("persisted scan header is missing", code: 4)
    }
    let statistics = try await repository.statistics(summary.scanID)
    let rootChildren = try await repository.children(of: state.rootNodeID, in: summary.scanID)
    let schemaVersion = try await repository.schemaVersion()
    await repository.close()
    let databaseBytes = try databaseByteCount(databasePath)

    let json = "{"
        + "\"engine\":\"\(engineName)\","
        + "\"status\":\"\(summary.status)\","
        + "\"fileCount\":\(summary.fileCount),"
        + "\"directoryCount\":\(summary.directoryCount),"
        + "\"issueCount\":\(summary.issueCount),"
        + "\"inaccessibleCount\":\(summary.inaccessibleCount),"
        + "\"rootAttributedBytes\":\(summary.rootAttributedBytes),"
        + "\"persistedNodes\":\(statistics.nodeCount),"
        + "\"persistedNames\":\(statistics.nameCount),"
        + "\"persistedAggregates\":\(statistics.aggregateCount),"
        + "\"persistedIssues\":\(statistics.issueCount),"
        + "\"rootChildCount\":\(rootChildren.count),"
        + "\"databaseBytes\":\(databaseBytes),"
        + "\"schemaVersion\":\(schemaVersion)"
        + "}"
    print(json)
    exit(0)
} catch {
    await repository.close()
    fail("cannot query store: \(error)", code: 4)
}
