import Foundation
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeUseCases
@testable import SpaceJudgeAppSupport

// MARK: - Directory access double

@MainActor
final class TestDirectoryAccess: DirectoryAccess {
    private var nextSelection: DirectorySelection?
    private var startResult = true
    private var startedURLs: [URL] = []
    private var stoppedURLs: [URL] = []

    init(nextSelection: DirectorySelection? = nil, startResult: Bool = true) {
        self.nextSelection = nextSelection
        self.startResult = startResult
    }

    func setNextSelection(_ selection: DirectorySelection?) {
        nextSelection = selection
    }

    func pickDirectory() async -> DirectorySelection? {
        nextSelection
    }

    func startAccess(for selection: DirectorySelection) -> Bool {
        startedURLs.append(selection.url)
        return startResult
    }

    func stopAccess(for selection: DirectorySelection) {
        stoppedURLs.append(selection.url)
    }

    var started: [URL] { startedURLs }

    var stopped: [URL] { stoppedURLs }
}

/// Directory access double whose picker suspends until `resolve(_:)` is called.
/// Used to prove a second `chooseRoot()` cannot open a second picker.
@MainActor
final class SuspendingDirectoryAccess: DirectoryAccess {
    private var continuation: CheckedContinuation<DirectorySelection?, Never>?
    private(set) var pickCallCount = 0
    private(set) var startedURLs: [URL] = []

    func pickDirectory() async -> DirectorySelection? {
        pickCallCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ selection: DirectorySelection?) {
        continuation?.resume(returning: selection)
        continuation = nil
    }

    func startAccess(for selection: DirectorySelection) -> Bool {
        startedURLs.append(selection.url)
        return true
    }

    func stopAccess(for selection: DirectorySelection) {}
}

// MARK: - Repository double

actor StubSnapshotRepository: SnapshotRepository {
    enum Call: Equatable {
        case begin(ScanID)
        case write(Revision)
        case record(ScanIssueCategory)
        case finish(ScanStatus)
        case fail(ScanID)
    }

    private(set) var calls: [Call] = []
    private var pagesByParent: [NodeID: SnapshotChildPage] = [:]
    private var issues: [IssueAggregateSummary] = []
    private var requestLimits: [Int] = []
    private var pageDelayNanoseconds: UInt64 = 0
    private var ancestorsByNode: [NodeID: [NodeRecord]] = [:]
    private var namesByID: [NameID: NameRecord] = [:]
    private var aggregatesByNode: [NodeID: DirectoryAggregateRecord] = [:]
    private var scanStates: [ScanID: ScanSnapshotState] = [:]

    func setPage(_ page: SnapshotChildPage, for parent: NodeID) {
        pagesByParent[parent] = page
    }

    func setAncestors(_ nodes: [NodeRecord], for node: NodeID) {
        ancestorsByNode[node] = nodes
    }

    func setName(_ record: NameRecord) {
        namesByID[record.id] = record
    }

    func setAggregate(_ record: DirectoryAggregateRecord) {
        aggregatesByNode[record.nodeID] = record
    }

    func setState(_ state: ScanSnapshotState) {
        scanStates[state.scanID] = state
    }

    func setIssues(_ value: [IssueAggregateSummary]) {
        issues = value
    }

    func setPageDelay(nanoseconds: UInt64) {
        pageDelayNanoseconds = nanoseconds
    }

    var recordedLimits: [Int] { requestLimits }

    func begin(_ metadata: ScanMetadata) async throws {
        calls.append(.begin(metadata.scanID))
    }

    func write(_ batch: NodeBatch) async throws {
        calls.append(.write(batch.revision))
    }

    func record(_ issue: ScanIssue) async throws {
        calls.append(.record(issue.category))
    }

    func finish(_ summary: ScanSummary) async throws {
        calls.append(.finish(summary.status))
    }

    func fail(scanID: ScanID) async throws {
        calls.append(.fail(scanID))
    }

    func children(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] {
        (pagesByParent[nodeID]?.items ?? []).map(\.node)
    }

    func childPage(
        of nodeID: NodeID,
        in scanID: ScanID,
        limit: Int
    ) async throws -> SnapshotChildPage {
        requestLimits.append(limit)
        if pageDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: pageDelayNanoseconds)
        }
        guard let page = pagesByParent[nodeID] else {
            return SnapshotChildPage(items: [], totalCount: 0)
        }
        let items = Array(page.items.prefix(limit))
        return SnapshotChildPage(
            items: items,
            totalCount: page.totalCount,
            snapshotRevision: page.snapshotRevision,
            parentAggregate: page.parentAggregate
        )
    }

    func name(id: NameID, in scanID: ScanID) async throws -> NameRecord? {
        namesByID[id]
    }

    func aggregate(
        of nodeID: NodeID,
        in scanID: ScanID
    ) async throws -> DirectoryAggregateRecord? {
        aggregatesByNode[nodeID]
    }

    func ancestors(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] {
        ancestorsByNode[nodeID] ?? []
    }

    func scanState(_ scanID: ScanID) async throws -> ScanSnapshotState? {
        scanStates[scanID]
    }

    func scanSummary(_ scanID: ScanID) async throws -> ScanSnapshotSummary? { nil }

    func issueSummary(_ scanID: ScanID) async throws -> [IssueAggregateSummary] { issues }

    func statistics(_ scanID: ScanID) async throws -> SnapshotStatistics {
        SnapshotStatistics(nodeCount: 0, nameCount: 0, aggregateCount: 0, issueCount: 0)
    }
}

// MARK: - Engine double

/// Engine that replays scripted events. With `holdsOpen` it keeps the stream
/// alive until `cancel(scanID:)` publishes a cancelled terminal.
final class ScriptedScanEngine: ScanEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ScanEvent, any Error>.Continuation?
    private var cancelledIDs: [ScanID] = []
    private var requests: [ScanRequest] = []
    private let scripted: [ScanEvent]
    private let holdsOpen: Bool
    private let scanID: ScanID
    private let terminalOnCancel: ScanSummary?
    private let finishError: (any Error)?

    init(
        scanID: ScanID,
        events: [ScanEvent],
        holdsOpen: Bool = false,
        terminalOnCancel: ScanSummary? = nil,
        finishError: (any Error)? = nil
    ) {
        self.scanID = scanID
        self.scripted = events
        self.holdsOpen = holdsOpen
        self.terminalOnCancel = terminalOnCancel
        self.finishError = finishError
    }

    nonisolated func events(for request: ScanRequest) -> AsyncThrowingStream<ScanEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ScanEvent, any Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        lock.lock()
        self.continuation = continuation
        self.requests.append(request)
        let scripted = self.scripted
        let holdsOpen = self.holdsOpen
        let finishError = self.finishError
        lock.unlock()
        for event in scripted {
            continuation.yield(event)
        }
        if let finishError {
            continuation.finish(throwing: finishError)
        } else if !holdsOpen {
            continuation.finish()
        }
        return stream
    }

    func cancel(scanID: ScanID) async {
        let (continuation, terminal): (AsyncThrowingStream<ScanEvent, any Error>.Continuation?, ScanSummary?) =
            lock.withLock {
                cancelledIDs.append(scanID)
                return (self.continuation, terminalOnCancel)
            }
        if let continuation, let terminal {
            continuation.yield(.cancelled(terminal))
            continuation.finish()
        }
    }

    var cancelledScanIDs: [ScanID] {
        lock.lock()
        defer { lock.unlock() }
        return cancelledIDs
    }

    var recordedRequests: [ScanRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

// MARK: - Fixtures

/// Thread-safe call counter for shutdown assertions.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func appSupportScanID(_ value: Int = 1) -> ScanID {
    ScanID(
        rawValue: UUID(uuidString: String(format: "11111111-1111-1111-1111-%012d", value))!
    )
}

func appSupportMetadata(
    scanID: ScanID,
    rootNodeID: NodeID = NodeID(1),
    displayName: String = "fixture",
    volume: VolumeFacts? = nil
) -> ScanMetadata {
    ScanMetadata(
        scanID: scanID,
        request: ScanRequest(
            root: ScanRoot(fileSystemPath: "/private/tmp/fixture", displayName: displayName)
        ),
        startedAt: Date(timeIntervalSince1970: 100),
        rootNodeID: rootNodeID,
        volume: volume
    )
}

func appSupportSummary(
    scanID: ScanID,
    status: ScanStatus,
    volume: VolumeFacts? = nil
) -> ScanSummary {
    ScanSummary(
        scanID: scanID,
        status: status,
        startedAt: Date(timeIntervalSince1970: 100),
        finishedAt: Date(timeIntervalSince1970: 200),
        fileCount: 3,
        directoryCount: 1,
        inaccessibleCount: 0,
        issueCount: 0,
        rootAttributedBytes: 12_288,
        volume: volume
    )
}

func appSupportChildItem(id: UInt64, name: String, attributed: UInt64) -> SnapshotChildItem {
    let scanID = appSupportScanID()
    return SnapshotChildItem(
        node: NodeRecord(
            id: NodeID(id),
            scanID: scanID,
            parentID: NodeID(1),
            name: NameID(id),
            kind: .directory,
            flags: [],
            logicalBytes: nil,
            allocatedBytes: nil,
            attributedBytes: attributed
        ),
        name: NameRecord(id: NameID(id), bytes: Array(name.utf8))
    )
}
