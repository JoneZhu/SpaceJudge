import Darwin
import Foundation
import SpaceJudgeDomain

// MARK: - Engine

/// Thread-safe registry of running coordinators, keyed by `ScanID`.
/// One-shot completion diagnostics for a finished scan. Tests consume these;
/// the registry never keeps unbounded per-scan history.
struct ScanDiagnostics: Sendable, Equatable {
    var queueHighWater: Int
    var spoolUsed: Bool
}

/// Thread-safe registry of running coordinators, keyed by `ScanID`.
final class CoordinatorRegistry: @unchecked Sendable {
    /// Diagnostics exist only to support acceptance tests. Keep a small,
    /// explicit cap so callers that never consume them cannot turn this test
    /// hook into a production memory leak.
    static let maximumRetainedDiagnostics = 64

    private let lock = NSLock()
    private var coordinators: [ScanID: ScanCoordinator] = [:]
    private var diagnostics: [ScanID: ScanDiagnostics] = [:]
    private var diagnosticsOrder: [ScanID] = []
    /// At most one latest cancelled directory checkpoint. A cancelled scan
    /// stores it before publishing its terminal; the runner takes it once
    /// before persisting `cancelled`. Completed/failed scans never store one,
    /// and a new scan clears any leftover so it cannot grow across scans.
    private var cancelledCheckpoint: (scanID: ScanID, checkpoint: CancelledDirectoryCheckpoint)?

    /// Returns `false` when a coordinator for `scanID` already exists.
    func insert(_ coordinator: ScanCoordinator, for scanID: ScanID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard coordinators[scanID] == nil else { return false }
        coordinators[scanID] = coordinator
        return true
    }

    func remove(_ scanID: ScanID) {
        lock.lock()
        coordinators[scanID] = nil
        lock.unlock()
    }

    func coordinator(for scanID: ScanID) -> ScanCoordinator? {
        lock.lock()
        defer { lock.unlock() }
        return coordinators[scanID]
    }

    func recordDiagnostics(_ value: ScanDiagnostics, for scanID: ScanID) {
        lock.lock()
        if diagnostics[scanID] == nil {
            diagnosticsOrder.append(scanID)
        }
        diagnostics[scanID] = value
        while diagnosticsOrder.count > Self.maximumRetainedDiagnostics {
            let oldest = diagnosticsOrder.removeFirst()
            diagnostics[oldest] = nil
        }
        lock.unlock()
    }

    /// Returns and removes the diagnostics for a finished scan. Returns `nil`
    /// when the scan is still running or the diagnostics were already taken.
    func takeDiagnostics(for scanID: ScanID) -> ScanDiagnostics? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = diagnostics.removeValue(forKey: scanID) else {
            return nil
        }
        diagnosticsOrder.removeAll { $0 == scanID }
        return value
    }

    var diagnosticsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return diagnostics.count
    }

    // MARK: Cancelled directory checkpoint (bounded, one slot)

    func storeCancelledCheckpoint(
        _ checkpoint: CancelledDirectoryCheckpoint,
        for scanID: ScanID
    ) {
        lock.lock()
        cancelledCheckpoint = (scanID, checkpoint)
        lock.unlock()
    }

    func takeCancelledCheckpoint(for scanID: ScanID) -> CancelledDirectoryCheckpoint? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = cancelledCheckpoint, value.scanID == scanID else { return nil }
        cancelledCheckpoint = nil
        return value.checkpoint
    }

    /// Clears any checkpoint at the start of a new scan so a scan that finished
    /// without a runner taking it cannot leave an unbounded slot behind.
    func clearCancelledCheckpoint() {
        lock.lock()
        cancelledCheckpoint = nil
        lock.unlock()
    }

    /// Test hook: whether a checkpoint is currently retained.
    var hasCancelledCheckpoint: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledCheckpoint != nil
    }
}

/// Real file-system `ScanEngine`.
///
/// The engine actor itself only owns immutable configuration and the
/// coordinator registry; all mutable scan state lives inside a
/// `ScanCoordinator` actor so it is isolated in one domain.
public actor FileSystemScanEngine: ScanEngine {
    private nonisolated let configuration: ScanConfiguration
    private nonisolated let registry: CoordinatorRegistry

    public init(configuration: ScanConfiguration = ScanConfiguration()) {
        self.configuration = configuration
        self.registry = CoordinatorRegistry()
    }

    public nonisolated func events(for request: ScanRequest) -> AsyncThrowingStream<ScanEvent, any Error> {
        events(for: request, scanID: ScanID())
    }

    /// Deterministic variant used by tests to exercise duplicate-scan and
    /// explicit-cancel paths.
    public nonisolated func events(
        for request: ScanRequest,
        scanID: ScanID
    ) -> AsyncThrowingStream<ScanEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ScanEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(configuration.eventBufferSize)
        )
        // A new scan can never reuse a previous cancelled checkpoint.
        registry.clearCancelledCheckpoint()
        let coordinator = ScanCoordinator(
            scanID: scanID,
            request: request,
            configuration: configuration,
            registry: registry
        )
        guard registry.insert(coordinator, for: scanID) else {
            continuation.finish(throwing: ScanError.duplicateScan(scanID))
            return stream
        }
        continuation.onTermination = { @Sendable _ in
            Task { await coordinator.consumerTerminated() }
        }
        let registry = self.registry
        Task.detached {
            await coordinator.run(continuation: continuation)
            let highWater = await coordinator.queueHighWater
            let usedSpool = await coordinator.spoolWasUsed
            registry.recordDiagnostics(
                ScanDiagnostics(queueHighWater: highWater, spoolUsed: usedSpool),
                for: scanID
            )
            registry.remove(scanID)
        }
        return stream
    }

    /// One-shot diagnostics for a finished scan. Internal test hook; at most
    /// one finished scan's diagnostics are retained per `ScanID`, and taking
    /// them removes them from the registry.
    nonisolated func takeDiagnostics(for scanID: ScanID) -> ScanDiagnostics? {
        registry.takeDiagnostics(for: scanID)
    }

    /// Number of pending (unconsumed) diagnostics records. Internal test hook.
    nonisolated func debugDiagnosticsCount() -> Int {
        registry.diagnosticsCount
    }

    public func cancel(scanID: ScanID) async {
        if let coordinator = registry.coordinator(for: scanID) {
            await coordinator.cancel()
        }
    }

    /// Test hook: whether a cancelled checkpoint is currently retained.
    nonisolated func debugHasCancelledCheckpoint() -> Bool {
        registry.hasCancelledCheckpoint
    }
}

/// The engine opts into the package-only cancelled-checkpoint side channel. A
/// cancelled scan leaves at most one directory checkpoint for the runner to
/// persist before the `cancelled` terminal; completed and failed scans leave
/// none. Engines that do not implement this keep the previous behaviour.
extension FileSystemScanEngine: CancelledCheckpointProviding {
    package func takeCancelledCheckpoint(scanID: ScanID) async -> CancelledDirectoryCheckpoint? {
        registry.takeCancelledCheckpoint(for: scanID)
    }
}

// MARK: - Work values

struct DirectoryWorkItem: Sendable {
    let nodeID: NodeID
    let parentID: NodeID?
    let pathBytes: [UInt8]
    let deviceID: UInt64?
    let isRoot: Bool
    /// True only for a directory that was reached by following a firmlink. The
    /// boundary policy uses it to authorize exactly the direct children of that
    /// projection to live on the projected volume; it is never inherited by
    /// those children, so it cannot become a global cross-device allowance.
    let enteredThroughFirmlink: Bool
    let preopened: FileDescriptor?

    init(
        nodeID: NodeID,
        parentID: NodeID?,
        pathBytes: [UInt8],
        deviceID: UInt64?,
        isRoot: Bool,
        enteredThroughFirmlink: Bool = false,
        preopened: FileDescriptor?
    ) {
        self.nodeID = nodeID
        self.parentID = parentID
        self.pathBytes = pathBytes
        self.deviceID = deviceID
        self.isRoot = isRoot
        self.enteredThroughFirmlink = enteredThroughFirmlink
        self.preopened = preopened
    }
}

struct DiscoveredDirectory {
    let id: NodeID
    let parentID: NodeID?
    let name: NameID
    let kind: NodeKind
    let flags: NodeFlags
    let deviceID: UInt64?
    let fileID: UInt64?
    let modifiedAt: Date?

    func makeRecord(scanID: ScanID, extraFlags: NodeFlags) -> NodeRecord {
        NodeRecord(
            id: id,
            scanID: scanID,
            parentID: parentID,
            name: name,
            kind: kind,
            flags: flags.union(extraFlags),
            logicalBytes: nil,
            allocatedBytes: nil,
            attributedBytes: 0,
            modifiedAt: modifiedAt,
            deviceID: deviceID,
            fileID: fileID
        )
    }
}

/// Runs one directory work item as a paged cursor: open (or adopt) the FD,
/// create a worker-exclusive cursor, and hand one page at a time to the
/// coordinator. The worker only reads the next page after the coordinator has
/// awaited processing the current one, so backpressure reaches the syscall.
/// `inFlight` is released exactly once by the coordinator's terminal method
/// for this item.
func runDirectoryWorkItem(
    _ item: DirectoryWorkItem,
    enumerator: any DirectoryEnumerator,
    token: ScanCancellationToken,
    coordinator: ScanCoordinator
) async {
    // Open (or adopt) the directory descriptor. Device identity comes from the
    // enumeration facts carried by the work item, not from a second syscall on
    // the hot path.
    let descriptor: FileDescriptor
    if let preopened = item.preopened {
        descriptor = preopened
    } else {
        let raw = POSIXPath.open(
            item.pathBytes,
            flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard raw >= 0 else {
            await coordinator.directoryFailed(item, errno: errno)
            return
        }
        descriptor = FileDescriptor(raw)
    }
    defer { descriptor.close() }

    let request = EnumerationRequest(cancellation: token)
    let cursor: any DirectoryCursor
    do {
        cursor = try enumerator.makeCursor(
            in: DirectoryHandle(fileDescriptor: descriptor.rawValue),
            request: request
        )
    } catch let error as ScanError {
        await coordinator.directoryFailed(item, errno: error.errnoValue ?? EIO)
        return
    } catch {
        await coordinator.directoryFailed(item, errno: EIO)
        return
    }

    var cursorValue = cursor
    while true {
        if token.isCancelled {
            await coordinator.directoryCancelled(item)
            return
        }
        let page: DirectoryEntryPage
        do {
            page = try cursorValue.nextPage()
        } catch let error as ScanError {
            if error == .cancelled {
                await coordinator.directoryCancelled(item)
            } else {
                await coordinator.directoryFailed(item, errno: error.errnoValue ?? EIO)
            }
            return
        } catch {
            await coordinator.directoryFailed(item, errno: EIO)
            return
        }
        if token.isCancelled {
            await coordinator.directoryCancelled(item)
            return
        }
        do {
            try await coordinator.submitPage(page, item: item)
        } catch let error as ScanError where error == .cancelled {
            await coordinator.directoryCancelled(item)
            return
        } catch {
            await coordinator.failScan(error)
            return
        }
        if page.isLast {
            break
        }
    }

    do {
        try await coordinator.directoryCompleted(item)
    } catch {
        await coordinator.failScan(error)
    }
}

// MARK: - Coordinator

/// Owns all mutable state for one scan in a single isolation domain: node and
/// name allocation, hard-link claims, aggregation, batching, the bounded
/// directory frontier and cancellation.
actor ScanCoordinator {
    typealias Continuation = AsyncThrowingStream<ScanEvent, any Error>.Continuation

    private struct CompletionInfo {
        var isComplete: Bool
        var extraInaccessible: UInt64
        var failureFlag: NodeFlags?
    }

    private let scanID: ScanID
    private let request: ScanRequest
    private let configuration: ScanConfiguration
    private let exclusions: SnapshotWorkspaceExclusionSet
    /// Shared, bounded slot for the cancelled directory checkpoint.
    private nonisolated let registry: CoordinatorRegistry
    let cancellation = ScanCancellationToken()

    private var continuation: Continuation?
    private var startedAt = Date()
    private var revision = Revision(0)

    private var rootNodeID = NodeID(0)
    private var rootDeviceID: UInt64?
    /// Captured once after the root opens successfully and before `.started`.
    /// The same immutable value is reused in the terminal summary and, through
    /// `ScanMetadata`/`ScanSummary`, in the persisted snapshot.
    private var volumeFacts: VolumeFacts?
    private var nextNodeRawValue: UInt64 = 0
    private var nameInterner = NameInterner()
    private var hardLinks = HardLinkAttributor()
    private var aggregator = DirectoryAggregateBuilder()

    /// In-memory directory frontier. Its size never exceeds
    /// `configuration.maximumQueuedDirectories`; overflow goes to `spool`.
    /// The ring releases each consumed item's storage slot immediately.
    private var queue: DirectoryWorkQueue
    private var spool: DirectorySpool?
    private(set) var queueHighWater = 0
    private(set) var spoolWasUsed = false

    private var inFlight = 0
    private var waiters: [CheckedContinuation<DirectoryWorkItem?, Never>] = []
    private var workersLaunched = 0
    private var workersFinished = 0
    private var completionWaiter: CheckedContinuation<Void, Never>?

    private var pendingNames: [NameRecord] = []
    private var pendingNodes: [NodeRecord] = []
    private var pendingAggregates: [DirectoryAggregateRecord] = []
    private var lastProgressivePublication: Date = .distantPast
    private var publishedProgressiveDescendant = false
    private var bestKnownLiveAttributedBytes: UInt64 = 0
    private var pendingDirectoryNodes: [NodeID: DiscoveredDirectory] = [:]
    /// Directory identities and names from a flush batch that a cancel
    /// suppressed before it reached the consumer. They are cleared with the
    /// rest of the buffers, but retained long enough to build the cancelled
    /// checkpoint.
    private var suppressedNames: [NameRecord] = []
    private var suppressedDirectories: [NodeRecord] = []
    private var pendingChildren: [NodeID: UInt64] = [:]
    private var selfComplete: Set<NodeID> = []
    private var completionInfo: [NodeID: CompletionInfo] = [:]
    private var lastFlush = Date()

    private var fileCount: UInt64 = 0
    private var directoryCount: UInt64 = 0
    private var inaccessibleCount: UInt64 = 0
    private var issueCount: UInt64 = 0

    private var cancelled = false
    private var terminalEmitted = false
    private var scanFailure: Error?

    /// Single-writer FIFO gate for every `ScanEvent` delivery.
    ///
    /// `emit` can suspend when the bounded stream buffer is full, which makes
    /// the actor reentrant. Without a gate a later `emit` from another worker
    /// could reach `continuation.yield` first and publish a higher revision
    /// before the blocked one. Ownership is handed directly to the queue head
    /// on release so there is never a free window in which a new caller can
    /// overtake an already-waiting delivery.
    private var emitOwnershipHeld = false
    private var emitWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        scanID: ScanID,
        request: ScanRequest,
        configuration: ScanConfiguration,
        registry: CoordinatorRegistry = CoordinatorRegistry()
    ) {
        self.scanID = scanID
        self.request = request
        self.configuration = configuration
        self.exclusions = SnapshotWorkspaceExclusionSet(request.workspaceExclusions)
        self.registry = registry
        self.queue = DirectoryWorkQueue(
            capacityLimit: configuration.maximumQueuedDirectories
        )
    }

    // MARK: Lifecycle

    func run(continuation: Continuation) async {
        self.continuation = continuation
        do {
            try await performScan()
        } catch {
            discardPendingBuffers()
            terminalEmitted = true
            continuation.finish(throwing: error)
        }
        cleanupResources()
    }

    private func performScan() async throws {
        guard SnapshotWorkspaceExclusionSet.isWithinLimit(exclusions.count) else {
            throw ScanError.tooManyWorkspaceExclusions(
                limit: ScanRequest.maximumWorkspaceExclusions
            )
        }
        startedAt = Date()
        rootNodeID = try allocateNodeID()

        let pathBytes = Array(request.root.fileSystemPath.utf8)
        guard !pathBytes.isEmpty else {
            throw ScanError.rootOpenFailed(errno: ENOENT)
        }
        let rawRoot = POSIXPath.open(pathBytes, flags: O_RDONLY | O_DIRECTORY)
        guard rawRoot >= 0 else {
            throw ScanError.rootOpenFailed(errno: errno)
        }
        let rootDescriptor = FileDescriptor(rawRoot)
        var status = stat()
        guard fstat(rootDescriptor.rawValue, &status) == 0 else {
            let code = errno
            rootDescriptor.close()
            throw ScanError.rootOpenFailed(errno: code)
        }
        rootDeviceID = deviceIdentifier(status.st_dev)
        let rootFileID = UInt64(status.st_ino)

        // Refuse to scan SpaceJudge's own snapshot workspace before publishing
        // `.started`: the cache must never enumerate itself. `containsRoot`
        // resolves the root path exactly once here (never on the per-node hot
        // path) so a symlink alias that points at the workspace or one of its
        // descendants cannot bypass the lexical check; identity decides first
        // when available.
        guard !exclusions.containsRoot(
            path: request.root.fileSystemPath,
            deviceID: rootDeviceID,
            fileID: rootFileID
        ) else {
            rootDescriptor.close()
            throw ScanError.scanRootInsideSnapshotWorkspace
        }

        // Meter the root's volume once, after a successful open and before any
        // fact is published. Capacity metering is advisory: a provider that
        // cannot confirm values yields `.unavailable`, never a fatal scan error
        // and never a fabricated zero.
        let volumeFacts = configuration.volumeFactsProvider.facts(
            forFileSystemPath: request.root.fileSystemPath
        )
        self.volumeFacts = volumeFacts

        await emit(
            .started(
                ScanMetadata(
                    scanID: scanID,
                    request: request,
                    startedAt: startedAt,
                    rootNodeID: rootNodeID,
                    volume: volumeFacts
                )
            )
        )

        let rootName = Self.rootName(
            pathBytes: pathBytes,
            displayName: request.root.displayName
        )
        let (rootNameID, rootNameIsNew) = try nameInterner.intern(rootName)
        if rootNameIsNew {
            pendingNames.append(NameRecord(id: rootNameID, bytes: rootName))
        }
        pendingDirectoryNodes[rootNodeID] = DiscoveredDirectory(
            id: rootNodeID,
            parentID: nil,
            name: rootNameID,
            kind: .directory,
            flags: [],
            deviceID: rootDeviceID,
            fileID: rootFileID,
            modifiedAt: nil
        )
        directoryCount = try ScanCounter.increment(directoryCount)
        try enqueue(
            DirectoryWorkItem(
                nodeID: rootNodeID,
                parentID: nil,
                pathBytes: pathBytes,
                deviceID: rootDeviceID,
                isRoot: true,
                preopened: rootDescriptor
            )
        )

        workersLaunched = configuration.resolvedWorkerCount
        let enumerator = configuration.enumerator
        let token = cancellation
        for _ in 0..<workersLaunched {
            let coordinator = self
            Task.detached {
                await ScanCoordinator.workerLoop(
                    coordinator: coordinator,
                    enumerator: enumerator,
                    token: token
                )
            }
        }

        await waitForWorkers()

        if let failure = scanFailure {
            throw failure
        }

        if cancelled {
            // A public cancel means no further normal facts are published. The
            // checkpoint preserves only the directory identities needed to
            // reach already-committed leaves.
            publishCancelledCheckpoint()
            discardPendingBuffers()
            let summary = try buildSummary(status: .cancelled)
            // Lock the terminal decision before any await so a concurrent
            // cancel becomes a no-op and cannot split the terminal state.
            terminalEmitted = true
            await emit(.cancelled(summary), isTerminal: true)
            continuation?.finish()
            return
        }

        try await flush()

        if let failure = scanFailure {
            throw failure
        }
        if cancelled {
            // A cancel arrived while the final normal batches were being
            // delivered; only the cancelled terminal may follow.
            publishCancelledCheckpoint()
            discardPendingBuffers()
            let summary = try buildSummary(status: .cancelled)
            terminalEmitted = true
            await emit(.cancelled(summary), isTerminal: true)
            continuation?.finish()
            return
        }
        let summary = try buildSummary(status: .completed)
        terminalEmitted = true
        await emit(.completed(summary), isTerminal: true)
        continuation?.finish()
    }

    func cancel() {
        guard !terminalEmitted else { return }
        cancelled = true
        cancellation.cancel()
        releaseQueuedDescriptors()
        spool?.dispose()
        spool = nil
        wakeWaiters()
    }

    func consumerTerminated() {
        cancel()
    }

    func failScan(_ error: Error) {
        guard scanFailure == nil else { return }
        scanFailure = error
        cancelled = true
        cancellation.cancel()
        releaseQueuedDescriptors()
        spool?.dispose()
        spool = nil
        wakeWaiters()
    }

    private func cleanupResources() {
        releaseQueuedDescriptors()
        spool?.dispose()
        spool = nil
    }

    private func discardPendingBuffers() {
        pendingNames.removeAll(keepingCapacity: false)
        pendingNodes.removeAll(keepingCapacity: false)
        pendingAggregates.removeAll(keepingCapacity: false)
        pendingDirectoryNodes.removeAll(keepingCapacity: false)
        pendingChildren.removeAll(keepingCapacity: false)
        selfComplete.removeAll(keepingCapacity: false)
        completionInfo.removeAll(keepingCapacity: false)
        suppressedNames.removeAll(keepingCapacity: false)
        suppressedDirectories.removeAll(keepingCapacity: false)
    }

    /// Builds the cancelled directory checkpoint from the directories and names
    /// that were discovered but not yet published, plus any directory from a
    /// flush batch this cancel suppressed. It carries no aggregate, so a
    /// cancelled directory's weight stays unknown rather than fabricated.
    ///
    /// Called only on the cancel branches, before `discardPendingBuffers()`.
    private func publishCancelledCheckpoint() {
        let checkpoint = makeCancelledCheckpoint()
        guard !checkpoint.isEmpty else { return }
        registry.storeCancelledCheckpoint(checkpoint, for: scanID)
    }

    private func makeCancelledCheckpoint() -> CancelledDirectoryCheckpoint {
        var directories: [NodeRecord] = []
        var neededNames = Set<NameID>()
        directories.reserveCapacity(pendingDirectoryNodes.count + pendingNodes.count)

        // Directories whose own enumeration never finished.
        for discovered in pendingDirectoryNodes.values {
            directories.append(discovered.makeRecord(scanID: scanID, extraFlags: []))
            neededNames.insert(discovered.name)
        }
        // Directories that finished (or failed) but were not flushed, including
        // the ones from a suppressed in-flight flush.
        for node in pendingNodes where node.kind.isDirectoryLike {
            directories.append(node)
            neededNames.insert(node.name)
        }
        directories.append(contentsOf: suppressedDirectories)
        for node in suppressedDirectories {
            neededNames.insert(node.name)
        }

        // Only names that are still unpublished and referenced by an included
        // directory. Published names already exist in SQLite and must not be
        // re-inserted.
        var seen = Set<NameID>()
        var names: [NameRecord] = []
        for record in pendingNames where neededNames.contains(record.id) {
            if seen.insert(record.id).inserted { names.append(record) }
        }
        for record in suppressedNames where neededNames.contains(record.id) {
            if seen.insert(record.id).inserted { names.append(record) }
        }
        return CancelledDirectoryCheckpoint(names: names, directories: directories)
    }

    // MARK: Worker coordination

    private static func workerLoop(
        coordinator: ScanCoordinator,
        enumerator: any DirectoryEnumerator,
        token: ScanCancellationToken
    ) async {
        while true {
            let item: DirectoryWorkItem?
            do {
                item = try await coordinator.acquireWork()
            } catch {
                await coordinator.failScan(error)
                break
            }
            guard let item else { break }
            await runDirectoryWorkItem(
                item,
                enumerator: enumerator,
                token: token,
                coordinator: coordinator
            )
        }
        await coordinator.workerExited()
    }

    func acquireWork() async throws -> DirectoryWorkItem? {
        while true {
            if cancelled {
                return nil
            }
            try refill()
            if activeQueuedCount > 0 {
                guard let item = queue.pop() else { continue }
                inFlight += 1
                return item
            }
            if inFlight == 0, (spool?.count ?? 0) == 0 {
                return nil
            }
            _ = await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func workerExited() {
        workersFinished += 1
        wakeWaiters()
        if workersFinished >= workersLaunched, let waiter = completionWaiter {
            completionWaiter = nil
            waiter.resume()
        }
    }

    private func waitForWorkers() async {
        if workersFinished >= workersLaunched {
            return
        }
        await withCheckedContinuation { continuation in
            completionWaiter = continuation
        }
    }

    /// Processes one page of entries. The work item stays `inFlight` until a
    /// terminal coordinator method (`directoryCompleted`, `directoryFailed`,
    /// `directoryCancelled`) is called.
    func submitPage(_ page: DirectoryEntryPage, item: DirectoryWorkItem) async throws {
        if cancelled {
            throw ScanError.cancelled
        }
        try await processEntries(page.entries, item: item)
        try await maybeFlush()
    }

    /// Final page processed: finalize the directory and release `inFlight`.
    func directoryCompleted(_ item: DirectoryWorkItem) async throws {
        defer { finishInFlight() }
        if cancelled { return }
        try await markSelfComplete(
            item.nodeID,
            isComplete: true,
            extraInaccessible: 0,
            failureFlag: nil
        )
        try await maybeFlush()
    }

    /// Enumeration failed for this directory: record a recoverable issue.
    func directoryFailed(_ item: DirectoryWorkItem, errno code: Int32) async {
        if !cancelled {
            do {
                try await handleDirectoryFailure(item, errno: code)
                try await maybeFlush()
            } catch {
                failScan(error)
            }
        }
        finishInFlight()
    }

    /// The directory was abandoned because of cancellation.
    func directoryCancelled(_ item: DirectoryWorkItem) {
        finishInFlight()
    }

    private func finishInFlight() {
        if inFlight > 0 {
            inFlight -= 1
        }
        wakeWaiters()
    }

    // MARK: Entry processing

    private func processEntries(
        _ entries: [RawDirectoryEntry],
        item: DirectoryWorkItem
    ) async throws {
        for entry in entries {
            if cancellation.isCancelled {
                throw ScanError.cancelled
            }
            if let entryError = entry.entryError {
                try await recordIssue(
                    category: ScanIssueClassifier.category(for: entryError),
                    errno: entryError,
                    nodeID: item.nodeID,
                    sampleName: nil
                )
                continue
            }

            let (nameID, nameIsNew) = try nameInterner.intern(entry.nameBytes)
            if nameIsNew {
                pendingNames.append(NameRecord(id: nameID, bytes: entry.nameBytes))
                if String(bytes: entry.nameBytes, encoding: .utf8) == nil {
                    try await recordIssue(
                        category: .nameEncoding,
                        errno: nil,
                        nodeID: nil,
                        sampleName: nameID
                    )
                }
            }

            let nodeID = try allocateNodeID()
            var flags: NodeFlags = []
            if entry.usesFallback {
                flags.insert(.fallbackEnumerator)
            }

            if entry.kind == .directory {
                let childPath = POSIXPath.appending(item.pathBytes, entry.nameBytes)
                // SpaceJudge's own snapshot workspace wins over package/firmlink
                // decisions but never authorizes a descent; a real mount point
                // still stops below via `decision`.
                let isWorkspaceBoundary = exclusions.matches(
                    path: childPath,
                    deviceID: entry.deviceID,
                    fileID: entry.fileID
                )
                if isWorkspaceBoundary {
                    flags.insert(.snapshotStorageBoundary)
                }
                let decision = DirectoryBoundaryPolicy.decide(
                    policy: request.boundaryPolicy,
                    rootDeviceID: rootDeviceID,
                    currentDeviceID: item.deviceID,
                    childDeviceID: entry.deviceID,
                    isMountPoint: entry.isMountPoint,
                    isFirmlink: entry.isFirmlink,
                    enteredThroughFirmlink: item.enteredThroughFirmlink
                )
                flags.formUnion(decision.extraFlags)
                var descend = decision.shouldDescend
                if isWorkspaceBoundary {
                    descend = false
                } else if descend, request.packagePolicy == .treatAsLeaf,
                          Self.isPackage(childPath) {
                    flags.insert(.package)
                    descend = false
                }

                pendingDirectoryNodes[nodeID] = DiscoveredDirectory(
                    id: nodeID,
                    parentID: item.nodeID,
                    name: nameID,
                    kind: .directory,
                    flags: flags,
                    deviceID: entry.deviceID,
                    fileID: entry.fileID,
                    modifiedAt: entry.modifiedAt
                )
                directoryCount = try ScanCounter.increment(directoryCount)
                try aggregator.registerDirectory(nodeID, parent: item.nodeID)
                pendingChildren[item.nodeID] = try ScanCounter.increment(
                    pendingChildren[item.nodeID] ?? 0
                )

                if descend {
                    // Inside a firmlink projection the parent's device belongs
                    // to the old volume, so an unknown child device must stay
                    // unknown rather than inherit it. For an ordinary directory
                    // the parent device is still the best-known value.
                    let childDevice: UInt64?
                    if let known = entry.deviceID {
                        childDevice = known
                    } else if item.enteredThroughFirmlink {
                        childDevice = nil
                    } else {
                        childDevice = item.deviceID
                    }
                    try enqueue(
                        DirectoryWorkItem(
                            nodeID: nodeID,
                            parentID: item.nodeID,
                            pathBytes: childPath,
                            deviceID: childDevice,
                            isRoot: false,
                            enteredThroughFirmlink: entry.isFirmlink,
                            preopened: nil
                        )
                    )
                } else {
                    try await markSelfComplete(
                        nodeID,
                        isComplete: true,
                        extraInaccessible: 0,
                        failureFlag: nil
                    )
                }
            } else {
                let identity: FileIdentity? = {
                    guard let deviceID = entry.deviceID, let fileID = entry.fileID else {
                        return nil
                    }
                    return FileIdentity(deviceID: deviceID, fileID: fileID)
                }()
                let isHardLinked = (entry.linkCount ?? 1) > 1
                let candidate = entry.allocatedBytes ?? 0
                let base = FileAttribution.resolve(
                    candidate: candidate,
                    allocated: entry.allocatedBytes,
                    duplicate: false
                )

                switch base {
                case .invalid:
                    // Known allocation smaller than the attributed candidate:
                    // damaged fact. Report and skip publishing/aggregation/claim.
                    try await recordIssue(
                        category: .io,
                        errno: nil,
                        nodeID: nodeID,
                        sampleName: nameID
                    )
                    continue
                case .unknown:
                    // Unknown allocation is a legitimate incomplete fact. Publish
                    // it with attributed 0, count it and its logical bytes, but
                    // never claim an identity so a later known occurrence can.
                    pendingNodes.append(
                        NodeRecord(
                            id: nodeID,
                            scanID: scanID,
                            parentID: item.nodeID,
                            name: nameID,
                            kind: entry.kind,
                            flags: flags,
                            logicalBytes: entry.logicalBytes,
                            allocatedBytes: nil,
                            attributedBytes: 0,
                            modifiedAt: entry.modifiedAt,
                            deviceID: entry.deviceID,
                            fileID: entry.fileID
                        )
                    )
                    fileCount = try ScanCounter.increment(fileCount)
                    try aggregator.addFile(
                        parent: item.nodeID,
                        logical: entry.logicalBytes,
                        allocated: nil,
                        attributed: 0
                    )
                case .known(let baseBytes):
                    var attributed = baseBytes
                    // Sizes are validated before any hard-link claim so a damaged
                    // or unknown entry can never make a later valid occurrence
                    // look duplicate.
                    if isHardLinked, let identity,
                       hardLinks.claim(identity) == .duplicate {
                        flags.insert(.duplicateHardLink)
                        attributed = 0
                    }
                    if let logical = entry.logicalBytes, let allocated = entry.allocatedBytes,
                       allocated < logical {
                        flags.insert(.sparse)
                    }
                    pendingNodes.append(
                        NodeRecord(
                            id: nodeID,
                            scanID: scanID,
                            parentID: item.nodeID,
                            name: nameID,
                            kind: entry.kind,
                            flags: flags,
                            logicalBytes: entry.logicalBytes,
                            allocatedBytes: entry.allocatedBytes,
                            attributedBytes: attributed,
                            modifiedAt: entry.modifiedAt,
                            deviceID: entry.deviceID,
                            fileID: entry.fileID
                        )
                    )
                    fileCount = try ScanCounter.increment(fileCount)
                    try aggregator.addFile(
                        parent: item.nodeID,
                        logical: entry.logicalBytes,
                        allocated: entry.allocatedBytes,
                        attributed: attributed
                    )
                }
            }

            if pendingNodes.count >= configuration.batchNodeLimit {
                try await flush()
            }
        }
    }

    private func handleDirectoryFailure(
        _ item: DirectoryWorkItem,
        errno code: Int32
    ) async throws {
        inaccessibleCount = try ScanCounter.increment(inaccessibleCount)
        let category: ScanIssueCategory = code == ENOENT
            ? .changedDuringScan
            : ScanIssueClassifier.category(for: code)
        let flag: NodeFlags = code == ENOENT ? .changedDuringScan : .inaccessible
        try await recordIssue(
            category: category,
            errno: code,
            nodeID: item.nodeID,
            sampleName: nil
        )
        try await markSelfComplete(
            item.nodeID,
            isComplete: false,
            extraInaccessible: 1,
            failureFlag: flag
        )
    }

    private func markSelfComplete(
        _ nodeID: NodeID,
        isComplete: Bool,
        extraInaccessible: UInt64,
        failureFlag: NodeFlags?
    ) async throws {
        completionInfo[nodeID] = CompletionInfo(
            isComplete: isComplete,
            extraInaccessible: extraInaccessible,
            failureFlag: failureFlag
        )
        selfComplete.insert(nodeID)
        // Publish this directory's own immutable identity as soon as its own
        // enumeration has finished or failed: the name, kind and flags are
        // final here, and waiting for the whole subtree aggregate is what kept
        // an early-discovered directory invisible in its parent's bounded page
        // for the entire scan. The aggregate is still produced later by
        // `tryCompleteUpward`, so no area, weight or reclaimable amount is
        // fabricated. Each NodeID is emitted exactly once because the record is
        // removed from `pendingDirectoryNodes` here.
        if let discovered = pendingDirectoryNodes.removeValue(forKey: nodeID) {
            pendingNodes.append(
                discovered.makeRecord(scanID: scanID, extraFlags: failureFlag ?? [])
            )
        }
        try await tryCompleteUpward(from: nodeID)
    }

    private func tryCompleteUpward(from start: NodeID) async throws {
        var current: NodeID? = start
        while let nodeID = current {
            guard selfComplete.contains(nodeID),
                  (pendingChildren[nodeID] ?? 0) == 0,
                  !aggregator.isCompleted(nodeID) else {
                return
            }
            let info = completionInfo[nodeID] ?? CompletionInfo(
                isComplete: true,
                extraInaccessible: 0,
                failureFlag: nil
            )
            // The directory's own `NodeRecord` was already published by
            // `markSelfComplete`; this walk only produces the final aggregate
            // and retires the per-directory working state.
            let aggregate = try aggregator.complete(
                nodeID,
                isComplete: info.isComplete,
                extraInaccessible: info.extraInaccessible
            )
            pendingAggregates.append(aggregate)

            let parent = aggregator.parent(of: nodeID)
            if let parent, let remaining = pendingChildren[parent], remaining > 0 {
                pendingChildren[parent] = remaining - 1
            }
            // The directory's final aggregate is now an independent value and
            // has been folded into its parent, so its mutable working state is
            // no longer needed. The parent reference was captured above.
            // The root is never retired: progress and the terminal summary read
            // its live best-known totals. The aggregator keeps a lightweight
            // `completed` set as the duplicate-completion guard.
            if nodeID != rootNodeID {
                completionInfo.removeValue(forKey: nodeID)
                pendingChildren.removeValue(forKey: nodeID)
                selfComplete.remove(nodeID)
                aggregator.retire(nodeID)
            }
            current = parent
        }
    }

    // MARK: Bounded frontier

    private func enqueue(_ item: DirectoryWorkItem) throws {
        if activeQueuedCount >= configuration.maximumQueuedDirectories {
            try spoolItem(item)
        } else {
            queue.push(item)
            queueHighWater = max(queueHighWater, activeQueuedCount)
        }
        wakeWaiters()
    }

    private func spoolItem(_ item: DirectoryWorkItem) throws {
        guard item.preopened == nil else {
            throw ScanError.spoolFailed("refusing to spool a preopened work item")
        }
        if spool == nil {
            spool = DirectorySpool(directory: configuration.spoolDirectory)
        }
        try spool?.append(item)
        spoolWasUsed = true
    }

    private var activeQueuedCount: Int {
        queue.count
    }

    private func refill() throws {
        while activeQueuedCount < configuration.maximumQueuedDirectories {
            guard let spool, let item = try spool.pop() else { break }
            queue.push(item)
            queueHighWater = max(queueHighWater, activeQueuedCount)
        }
    }

    private func releaseQueuedDescriptors() {
        queue.closeAll()
    }

    private func wakeWaiters() {
        guard !waiters.isEmpty else { return }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: nil)
        }
    }

    // MARK: Events

    private func maybeFlush() async throws {
        guard !pendingNodes.isEmpty || !pendingAggregates.isEmpty || !pendingNames.isEmpty else {
            return
        }
        let elapsedMilliseconds = Date().timeIntervalSince(lastFlush) * 1000
        if pendingNodes.count >= configuration.batchNodeLimit
            || elapsedMilliseconds >= Double(configuration.batchTimeMilliseconds) {
            try await flush()
        }
    }

    private func flush() async throws {
        guard !pendingNodes.isEmpty || !pendingAggregates.isEmpty || !pendingNames.isEmpty else {
            return
        }
        try appendProgressiveAggregates()
        revision = try Self.nextRevision(from: revision)
        let batch = NodeBatch(
            scanID: scanID,
            revision: revision,
            names: pendingNames,
            nodes: pendingNodes,
            directoryAggregates: pendingAggregates
        )
        pendingNames.removeAll(keepingCapacity: true)
        pendingNodes.removeAll(keepingCapacity: true)
        pendingAggregates.removeAll(keepingCapacity: true)
        lastFlush = Date()
        let delivered = await emit(.batch(batch))
        if !delivered {
            // A cancel (or a terminated stream) suppressed this batch before
            // the consumer could persist it. Retain its directory identities
            // and names so the cancelled checkpoint can reconnect any already
            // committed descendant whose parent was in this batch.
            suppressedNames.append(contentsOf: batch.names)
            suppressedDirectories.append(contentsOf: batch.nodes.filter { $0.kind.isDirectoryLike })
        } else if let rootAggregate = batch.directoryAggregates.first(where: { $0.nodeID == rootNodeID }) {
            // Remember only emitted facts. A cancelled/suppressed batch must
            // not advance the retained live total or terminal cancel summary.
            bestKnownLiveAttributedBytes = rootAggregate.attributedBytes
        }
        try await emitProgress()
    }

    /// Only enumerated directories have published node identities. Publishing
    /// earlier would violate the store's node foreign key. An unfinished
    /// subtree can still contribute to its already-published ancestors.
    private func appendProgressiveAggregates() throws {
        let limit = configuration.progressiveDirectoryLimit
        let firstVisibleDirectory = !publishedProgressiveDescendant
            && pendingNodes.contains { $0.kind.isDirectoryLike && $0.id != rootNodeID && !aggregator.isCompleted($0.id) }
        guard limit > 0,
              firstVisibleDirectory || Date().timeIntervalSince(lastProgressivePublication) * 1000
                >= Double(configuration.progressiveIntervalMilliseconds) else { return }
        let totals = try aggregator.progressiveTotals(root: rootNodeID)
        let finalIDs = Set(pendingAggregates.map(\.nodeID))
        let eligible = totals.filter {
            selfComplete.contains($0.key) && !aggregator.isCompleted($0.key)
                && !finalIDs.contains($0.key) && $0.value.attributed > 0
        }.sorted {
            if $0.key == rootNodeID { return true }
            if $1.key == rootNodeID { return false }
            if $0.value.attributed != $1.value.attributed {
                return $0.value.attributed > $1.value.attributed
            }
            return $0.key.rawValue < $1.key.rawValue
        }
        guard !eligible.isEmpty else { return }
        lastProgressivePublication = Date()
        if eligible.contains(where: { $0.key != rootNodeID }) { publishedProgressiveDescendant = true }
        for (node, value) in eligible.prefix(limit) {
            pendingAggregates.append(DirectoryAggregateRecord(
                nodeID: node, logicalBytes: value.logical, allocatedBytes: value.allocated,
                attributedBytes: value.attributed, descendantFileCount: value.fileCount,
                descendantDirectoryCount: value.directoryCount,
                inaccessibleDescendantCount: value.inaccessible, isComplete: false
            ))
        }
    }

    private func emitProgress() async throws {
        let elapsed = Date().timeIntervalSince(startedAt)
        let entries = try ScanCounter.increment(fileCount, by: directoryCount)
        let rate = elapsed > 0 ? Double(entries) / elapsed : 0
        let rootAttributed = max(try aggregator.currentTotals(of: rootNodeID).attributed,
                                 bestKnownLiveAttributedBytes)
        let queued = UInt64(max(0, activeQueuedCount))
        let spooled = UInt64(max(0, spool?.count ?? 0))
        let pending = try ScanCounter.increment(queued, by: spooled)
        await emit(
            .progress(
                ScanProgress(
                    revision: revision,
                    status: cancelled ? .cancelling : .running,
                    fileCount: fileCount,
                    directoryCount: directoryCount,
                    attributedBytes: rootAttributed,
                    pendingDirectories: pending,
                    entriesPerSecond: rate,
                    elapsedSeconds: elapsed
                )
            )
        )
    }

    private func recordIssue(
        category: ScanIssueCategory,
        errno: Int32?,
        nodeID: NodeID?,
        sampleName: NameID?
    ) async throws {
        issueCount = try ScanCounter.increment(issueCount)
        if category == .changedDuringScan {
            return
        }
        await emit(
            .issue(
                ScanIssue(
                    scanID: scanID,
                    category: category,
                    nodeID: nodeID,
                    errnoValue: errno,
                    sampleName: sampleName,
                    count: 1
                )
            )
        )
    }

    /// Acquires the single-writer event gate, queueing behind any delivery that
    /// already holds it. The actor serializes callers, so the queue order is
    /// exactly the order in which deliveries were initiated.
    private func acquireEmitOwnership() async {
        if !emitOwnershipHeld {
            emitOwnershipHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            emitWaiters.append(continuation)
        }
        // Ownership was transferred directly by `releaseEmitOwnership`; the
        // gate is still held and no other caller can be inside it.
    }

    /// Releases the gate. Ownership is handed straight to the queue head while
    /// remaining held, so a fresh `emit` cannot slip in front of a waiter.
    private func releaseEmitOwnership() {
        if emitWaiters.isEmpty {
            emitOwnershipHeld = false
        } else {
            let next = emitWaiters.removeFirst()
            next.resume()
        }
    }

    /// True backpressure: a dropped event is retried until the consumer makes
    /// room or terminates. Once a public cancel is in effect, non-terminal
    /// events are dropped instead of published; the terminal event (including
    /// the `cancelled` summary) is always retried.
    ///
    /// Every delivery runs under the FIFO gate, so a suspended retry holds
    /// delivery ownership and later workers cannot publish ahead of it.
    ///
    /// Returns `true` when the event was handed to the stream (`.enqueued`) and
    /// `false` when it was suppressed by cancellation or a terminated stream.
    /// `flush` uses this to retain a cancelled batch's directory identities.
    @discardableResult
    private func emit(_ event: ScanEvent, isTerminal: Bool = false) async -> Bool {
        guard let continuation else { return false }
        await acquireEmitOwnership()
        defer { releaseEmitOwnership() }
        while true {
            if cancelled, !isTerminal {
                return false
            }
            switch continuation.yield(event) {
            case .enqueued:
                return true
            case .dropped:
                try? await Task.sleep(nanoseconds: 1_000_000)
            case .terminated:
                return false
            @unknown default:
                return false
            }
        }
    }

    // MARK: Summary

    private func buildSummary(status: ScanStatus) throws -> ScanSummary {
        let folded = try aggregator.currentTotals(of: rootNodeID).attributed
        let rootAttributed = status == .cancelled ? max(folded, bestKnownLiveAttributedBytes) : folded
        return ScanSummary(
            scanID: scanID,
            status: status,
            startedAt: startedAt,
            finishedAt: Date(),
            fileCount: fileCount,
            directoryCount: directoryCount,
            inaccessibleCount: inaccessibleCount,
            issueCount: issueCount,
            rootAttributedBytes: rootAttributed,
            volume: volumeFacts
        )
    }

    // MARK: Helpers

    private func allocateNodeID() throws -> NodeID {
        let rawValue = try ScanCounter.increment(nextNodeRawValue, by: 1)
        nextNodeRawValue = rawValue
        return NodeID(rawValue)
    }

    private static func nextRevision(from current: Revision) throws -> Revision {
        try ScanRevisionCounter.next(current)
    }

    private static func rootName(pathBytes: [UInt8], displayName: String) -> [UInt8] {
        if let lastSlash = pathBytes.lastIndex(of: UInt8(ascii: "/")),
           lastSlash + 1 < pathBytes.count {
            return Array(pathBytes[(lastSlash + 1)...])
        }
        if !displayName.isEmpty {
            return Array(displayName.utf8)
        }
        return pathBytes
    }

    private static func isPackage(_ pathBytes: [UInt8]) -> Bool {
        guard let path = String(bytes: pathBytes, encoding: .utf8) else { return false }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage ?? false
    }
}
