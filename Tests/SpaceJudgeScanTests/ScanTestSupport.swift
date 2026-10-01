import Darwin
import Foundation
import SpaceJudgeDomain
import SpaceJudgeScan

/// Aggregated view of a finished scan used by differential and invariant tests.
struct CollectedScan {
    var rootNodeID: NodeID?
    var nodes: [NodeID: NodeRecord] = [:]
    var names: [NameID: [UInt8]] = [:]
    var aggregates: [NodeID: DirectoryAggregateRecord] = [:]
    var status: ScanStatus?
    var issueCount: UInt64 = 0
    var issueCategories: [ScanIssueCategory: UInt64] = [:]
    var terminalCount = 0
    var batchesAfterTerminal = 0
    var summary: ScanSummary?

    mutating func consume(_ event: ScanEvent) {
        switch event {
        case .started(let metadata):
            rootNodeID = metadata.rootNodeID
        case .batch(let batch):
            if terminalCount > 0 {
                batchesAfterTerminal += 1
            }
            for name in batch.names {
                names[name.id] = name.bytes
            }
            for node in batch.nodes {
                nodes[node.id] = node
            }
            for aggregate in batch.directoryAggregates {
                aggregates[aggregate.nodeID] = aggregate
            }
        case .progress:
            break
        case .issue(let issue):
            issueCount += issue.count
            issueCategories[issue.category, default: 0] += issue.count
        case .completed(let summary):
            terminalCount += 1
            status = .completed
            self.summary = summary
        case .cancelled(let summary):
            terminalCount += 1
            status = .cancelled
            self.summary = summary
        }
    }

    func relativePath(of nodeID: NodeID) -> String {
        var components: [[UInt8]] = []
        var current = nodes[nodeID]
        while let record = current, let parentID = record.parentID, let parent = nodes[parentID] {
            components.append(names[record.name] ?? [])
            current = parent
        }
        return components.reversed()
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "/")
    }

    /// Canonical per-path facts. Discovery order, IDs and batch boundaries are
    /// intentionally excluded.
    struct CanonicalRow: Equatable {
        var kind: NodeKind
        var logical: UInt64?
        var allocated: UInt64?
        var deviceID: UInt64?
        var fileID: UInt64?
        var sparse: Bool
        var mountBoundary: Bool

        init(_ record: NodeRecord) {
            kind = record.kind
            logical = record.logicalBytes
            allocated = record.allocatedBytes
            deviceID = record.deviceID
            fileID = record.fileID
            sparse = record.flags.contains(.sparse)
            mountBoundary = record.flags.contains(.mountBoundary)
        }
    }

    func canonicalRows() -> [String: CanonicalRow] {
        var rows: [String: CanonicalRow] = [:]
        for (id, record) in nodes {
            rows[relativePath(of: id)] = CanonicalRow(record)
        }
        return rows
    }

    /// Number of duplicate-attributed occurrences per `(deviceID, fileID)`.
    func duplicateCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in nodes.values where record.flags.contains(.duplicateHardLink) {
            let key = "\(record.deviceID ?? 0):\(record.fileID ?? 0)"
            counts[key, default: 0] += 1
        }
        return counts
    }

    var fileCount: UInt64 {
        UInt64(nodes.values.filter { !$0.kind.isDirectoryLike }.count)
    }

    var directoryCount: UInt64 {
        UInt64(nodes.values.filter { $0.kind.isDirectoryLike }.count)
    }

    func rootAggregate() -> DirectoryAggregateRecord? {
        guard let rootNodeID else { return nil }
        return aggregates[rootNodeID]
    }

    struct CanonicalAggregate: Equatable {
        var logical: UInt64
        var allocated: UInt64
        var attributed: UInt64
        var files: UInt64
        var directories: UInt64
        var inaccessible: UInt64
        var isComplete: Bool

        init(_ record: DirectoryAggregateRecord) {
            logical = record.logicalBytes
            allocated = record.allocatedBytes
            attributed = record.attributedBytes
            files = record.descendantFileCount
            directories = record.descendantDirectoryCount
            inaccessible = record.inaccessibleDescendantCount
            isComplete = record.isComplete
        }
    }

    func canonicalAggregates() -> [String: CanonicalAggregate] {
        var result: [String: CanonicalAggregate] = [:]
        for (nodeID, record) in aggregates {
            result[relativePath(of: nodeID)] = CanonicalAggregate(record)
        }
        return result
    }
}

func collectScan(
    engine: FileSystemScanEngine,
    request: ScanRequest,
    scanID: ScanID = ScanID(),
    cancelAfterFirstBatch: Bool = false
) async throws -> CollectedScan {
    var collected = CollectedScan()
    let stream = engine.events(for: request, scanID: scanID)
    var cancelledOnce = false
    for try await event in stream {
        collected.consume(event)
        if cancelAfterFirstBatch, !cancelledOnce, case .batch = event {
            cancelledOnce = true
            await engine.cancel(scanID: scanID)
        }
    }
    return collected
}

// MARK: - Temporary fixtures

final class TempFixture {
    let url: URL

    init(prefix: String = "spacejudge-scan") throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ relative: String) -> String {
        url.appendingPathComponent(relative).path
    }

    @discardableResult
    func directory(_ relative: String) throws -> String {
        let target = path(relative)
        try FileManager.default.createDirectory(
            atPath: target,
            withIntermediateDirectories: true
        )
        return target
    }

    @discardableResult
    func file(_ relative: String, contents: String = "x") throws -> String {
        let target = path(relative)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: target).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: URL(fileURLWithPath: target))
        return target
    }

    @discardableResult
    func symlink(_ relative: String, to target: String) throws -> String {
        let linkPath = path(relative)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: linkPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: linkPath,
            withDestinationPath: target
        )
        return linkPath
    }

    @discardableResult
    func hardLink(_ relative: String, to existing: String) throws -> String {
        let linkPath = path(relative)
        let existingPath = path(existing)
        guard link(existingPath, linkPath) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return linkPath
    }

    @discardableResult
    func sparseFile(_ relative: String, logicalSize: Int) throws -> String {
        let target = path(relative)
        try Data().write(to: URL(fileURLWithPath: target))
        guard target.withCString({ truncate($0, off_t(logicalSize)) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return target
    }
}

func openFileDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}

/// Minimum file-descriptor count over a short settle window.
///
/// `/dev/fd` is process-global, so other parallel suites can transiently hold
/// descriptors while this test samples. Taking the minimum across a short
/// window removes those transients without hiding a real leak: a leaked
/// descriptor stays open and is present in every sample.
func settledFileDescriptorCount(
    samples: Int = 12,
    intervalMicroseconds: UInt64 = 10_000
) -> Int {
    var minimum = Int.max
    for _ in 0..<max(1, samples) {
        minimum = min(minimum, openFileDescriptorCount())
        usleep(useconds_t(intervalMicroseconds))
    }
    return minimum == Int.max ? openFileDescriptorCount() : minimum
}

/// Cursor used by injected test enumerators. Each directory script is one
/// step: a single final page, an explicit multi-page sequence, or a failure.
final class ScriptedCursor: DirectoryCursor {
    enum Step: Sendable {
        case entries([RawDirectoryEntry])
        case pages([DirectoryEntryPage])
        case failure(Int32)
    }

    private var step: Step?
    private var pages: [DirectoryEntryPage] = []
    private var index = 0

    init(_ step: Step) {
        self.step = step
    }

    func nextPage() throws -> DirectoryEntryPage {
        if let step {
            self.step = nil
            switch step {
            case .entries(let entries):
                return DirectoryEntryPage(entries: entries, isLast: true)
            case .pages(let explicitPages):
                pages = explicitPages
                index = 0
            case .failure(let code):
                throw ScanError.enumerationFailed(errno: code)
            }
        }
        if index < pages.count {
            let page = pages[index]
            index += 1
            return page
        }
        return DirectoryEntryPage(entries: [], isLast: true)
    }
}

/// Names of leftover directory-spool files in a specific directory.
///
/// Scoping the count to one scan's own spool root keeps parallel test suites
/// from polluting each other's assertions.
func spoolFiles(in directory: URL) -> [String] {
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return contents.filter { $0.hasPrefix("spacejudge-spool-") }
}

/// Names of any leftover directory-spool files in the process temporary
/// directory. Used to prove spool files are unlinked on every exit path.
func spoolFilesInTemporaryDirectory() -> [String] {
    spoolFiles(in: FileManager.default.temporaryDirectory)
}
