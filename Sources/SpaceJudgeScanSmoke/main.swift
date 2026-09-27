import Darwin
import Dispatch
import Foundation
import SpaceJudgeDomain
import SpaceJudgeScan

// Engineering acceptance CLI for the Phase 1 scan engine.
//
// It only scans the directory path the user passes on the command line, prints
// a stable JSON summary to stdout, and keeps progress/errors on stderr.

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(code)
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Argument parsing

var engineName = "bulk"
var timeoutSeconds: Double?
var directoryArgument: String?
var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--engine":
        index += 1
        guard index < arguments.count else {
            fail("--engine requires reference|bulk", code: 2)
        }
        engineName = arguments[index]
    case "--timeout":
        index += 1
        guard index < arguments.count, let value = Double(arguments[index]), value > 0 else {
            fail("--timeout requires a positive number of seconds", code: 2)
        }
        timeoutSeconds = value
    case "--help", "-h":
        print("usage: spacejudge-scan-smoke [--engine reference|bulk] [--timeout seconds] <directory>")
        exit(0)
    default:
        if argument.hasPrefix("-") {
            fail("unknown option \(argument)", code: 2)
        }
        if directoryArgument != nil {
            fail("only one directory may be scanned", code: 2)
        }
        directoryArgument = argument
    }
    index += 1
}

guard let directoryArgument else {
    fail("a directory argument is required", code: 2)
}
guard engineName == "reference" || engineName == "bulk" else {
    fail("--engine must be reference or bulk", code: 2)
}

// Reject unusable input before starting a scan so the exit code is unambiguous.
var inputStat = stat()
let inputPath = URL(fileURLWithPath: directoryArgument).path
let statResult = inputPath.withCString { pointer in
    lstat(pointer, &inputStat)
}
guard statResult == 0 else {
    fail("cannot read \(directoryArgument): \(String(cString: strerror(errno)))", code: 2)
}
guard (inputStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
    fail("\(directoryArgument) is not a directory", code: 2)
}

// MARK: - Engine setup

let enumerator: any DirectoryEnumerator = engineName == "reference"
    ? ReferenceEnumerator()
    : DarwinBulkEnumerator()
let configuration = ScanConfiguration(enumerator: enumerator)
let engine = FileSystemScanEngine(configuration: configuration)
let scanID = ScanID()

// Cancel on SIGINT or an optional timeout.
signal(SIGINT, SIG_IGN)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interruptSource.setEventHandler {
    Task { await engine.cancel(scanID: scanID) }
}
interruptSource.resume()

if let timeoutSeconds {
    Task {
        try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
        await engine.cancel(scanID: scanID)
    }
}

// MARK: - Consume events

var rootNodeID: NodeID?
var fileCount: UInt64 = 0
var directoryCount: UInt64 = 0
var issueCount: UInt64 = 0
var rootAttributedBytes: UInt64 = 0
var aggregateComplete = false
var terminalStatus = "failed"
var interrupted = false

let stream = engine.events(for: ScanRequest(root: ScanRoot(fileSystemPath: directoryArgument, displayName: directoryArgument)), scanID: scanID)
do {
    for try await event in stream {
        switch event {
        case .started(let metadata):
            rootNodeID = metadata.rootNodeID
        case .batch(let batch):
            for node in batch.nodes {
                if node.kind.isDirectoryLike {
                    directoryCount += 1
                } else {
                    fileCount += 1
                }
            }
            for aggregate in batch.directoryAggregates
            where aggregate.nodeID == rootNodeID && aggregate.isComplete {
                rootAttributedBytes = aggregate.attributedBytes
                aggregateComplete = true
            }
        case .progress(let progress):
            log(
                String(
                    format: "scanning files=%llu dirs=%llu attributed=%llu %.0f entries/s",
                    progress.fileCount,
                    progress.directoryCount,
                    progress.attributedBytes,
                    progress.entriesPerSecond
                )
            )
        case .issue(let issue):
            issueCount += issue.count
            log("issue \(issue.category)")
        case .completed(let summary):
            terminalStatus = "completed"
            fileCount = summary.fileCount
            directoryCount = summary.directoryCount
            issueCount = summary.issueCount
            rootAttributedBytes = summary.rootAttributedBytes
        case .cancelled(let summary):
            terminalStatus = "cancelled"
            fileCount = summary.fileCount
            directoryCount = summary.directoryCount
            issueCount = summary.issueCount
            rootAttributedBytes = summary.rootAttributedBytes
            interrupted = true
        }
    }
} catch {
    FileHandle.standardError.write(Data(("scan failed: \(error)\n").utf8))
    exit(3)
}

if terminalStatus == "failed" {
    fail("scan produced no terminal event", code: 3)
}

let statusValue = terminalStatus
let json = "{\"engine\":\"\(engineName)\","
    + "\"status\":\"\(statusValue)\","
    + "\"fileCount\":\(fileCount),"
    + "\"directoryCount\":\(directoryCount),"
    + "\"issueCount\":\(issueCount),"
    + "\"rootAttributedBytes\":\(rootAttributedBytes),"
    + "\"aggregateComplete\":\(aggregateComplete)}"
print(json)

if interrupted {
    exit(130)
}
exit(0)
