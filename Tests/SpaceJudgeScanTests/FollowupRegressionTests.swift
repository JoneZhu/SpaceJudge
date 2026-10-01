import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

/// Enumerator that returns scripted responses in call order.
private final class FollowupScriptedEnumerator: DirectoryEnumerator, @unchecked Sendable {
    typealias Step = ScriptedCursor.Step

    private let lock = NSLock()
    private var steps: [Step]

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func makeCursor(
        in directory: DirectoryHandle,
        request: EnumerationRequest
    ) throws -> any DirectoryCursor {
        lock.lock()
        let step: Step = steps.isEmpty ? .entries([]) : steps.removeFirst()
        lock.unlock()
        return ScriptedCursor(step)
    }
}

/// Enumerator whose second `makeCursor` blocks until the test releases it.
private final class BlockingEnumerator: DirectoryEnumerator, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let firstEntries: [RawDirectoryEntry]
    private let reachedBlock = DispatchSemaphore(value: 0)
    private let releaseBlock = DispatchSemaphore(value: 0)

    init(firstEntries: [RawDirectoryEntry]) {
        self.firstEntries = firstEntries
    }

    func makeCursor(
        in directory: DirectoryHandle,
        request: EnumerationRequest
    ) throws -> any DirectoryCursor {
        lock.lock()
        let index = callCount
        callCount += 1
        lock.unlock()
        if index == 0 {
            return ScriptedCursor(.entries(firstEntries))
        }
        reachedBlock.signal()
        _ = releaseBlock.wait(timeout: .now() + 15)
        return ScriptedCursor(.entries([]))
    }

    func waitUntilBlocking(timeout: DispatchTime = .now() + 10) -> Bool {
        reachedBlock.wait(timeout: timeout) == .success
    }

    func release() {
        releaseBlock.signal()
    }
}

@Suite("Phase 1 follow-up regressions", .serialized)
struct FollowupRegressionTests {
    private func request(for path: String) -> ScanRequest {
        ScanRequest(root: ScanRoot(fileSystemPath: path, displayName: path))
    }

    /// Polls for a finished scan's one-shot diagnostics. Taking removes them.
    private func awaitDiagnostics(
        _ engine: FileSystemScanEngine,
        scanID: ScanID,
        attempts: Int = 400
    ) async -> ScanDiagnostics? {
        for _ in 0..<attempts {
            if let diagnostics = engine.takeDiagnostics(for: scanID) {
                return diagnostics
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    // MARK: Issue 1 - true backpressure

    @Test("Slow consumer applies backpressure without losing events", .timeLimit(.minutes(2)))
    func slowConsumerBackpressure() async throws {
        let fixture = try TempFixture()
        for index in 0..<1200 {
            try fixture.file("f\(index)", contents: "x")
        }
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1,
                batchNodeLimit: 25,
                batchTimeMilliseconds: 100_000,
                eventBufferSize: 1
            )
        )
        let stream = engine.events(for: request(for: fixture.url.path))

        var knownNames: Set<NameID> = []
        var nodeCount = 0
        var nameViolations = 0
        var revisions: [UInt64] = []
        var terminalCount = 0
        var paused = false

        for try await event in stream {
            switch event {
            case .batch(let batch):
                revisions.append(batch.revision.rawValue)
                for name in batch.names {
                    knownNames.insert(name.id)
                }
                for node in batch.nodes {
                    nodeCount += 1
                    if !knownNames.contains(node.name) {
                        nameViolations += 1
                    }
                }
                if !paused {
                    paused = true
                    // Hold the consumer for >1.2 s so the producer must retry
                    // instead of dropping.
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                }
            case .completed, .cancelled:
                terminalCount += 1
            default:
                break
            }
        }

        #expect(paused)
        #expect(nameViolations == 0)
        #expect(nodeCount == 1201)
        #expect(terminalCount == 1)
        #expect(!revisions.isEmpty)
        #expect(revisions == Array(1...UInt64(revisions.count)))
    }

    // MARK: Issue 1b - concurrent workers under a full buffer

    /// Several workers produce batches while the consumer deliberately stalls
    /// on a one-slot buffer. Every producer ends up blocked retrying a dropped
    /// `yield`; without a single-writer FIFO gate a later worker can win the
    /// freed slot and publish a higher revision before an earlier one.
    @Test(
        "Concurrent workers keep batch revisions contiguous under backpressure",
        .timeLimit(.minutes(2))
    )
    func concurrentWorkerBackpressureKeepsRevisionOrder() async throws {
        let fixture = try TempFixture()
        for directory in 0..<8 {
            for file in 0..<300 {
                try fixture.file("d\(directory)/f\(file)", contents: "x")
            }
        }
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 4,
                batchNodeLimit: 20,
                batchTimeMilliseconds: 100_000,
                eventBufferSize: 1
            )
        )
        let stream = engine.events(for: request(for: fixture.url.path))

        var knownNames: Set<NameID> = []
        var revisions: [UInt64] = []
        var nodeCount = 0
        var nameViolations = 0
        var terminalCount = 0
        var batchesAfterTerminal = 0
        var paused = false

        for try await event in stream {
            switch event {
            case .batch(let batch):
                if terminalCount > 0 { batchesAfterTerminal += 1 }
                revisions.append(batch.revision.rawValue)
                for name in batch.names { knownNames.insert(name.id) }
                for node in batch.nodes {
                    nodeCount += 1
                    if !knownNames.contains(node.name) { nameViolations += 1 }
                }
                if !paused {
                    paused = true
                    // Hold the consumer while four producers race for the one
                    // free slot, forcing repeated dropped-yield retries.
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
            case .completed, .cancelled:
                terminalCount += 1
            default:
                break
            }
        }

        #expect(paused)
        #expect(terminalCount == 1)
        #expect(batchesAfterTerminal == 0)
        #expect(!revisions.isEmpty)
        #expect(revisions == Array(1...UInt64(revisions.count)))
        // Root + 8 directories + 2400 files.
        #expect(nodeCount == 2409)
        #expect(nameViolations == 0)
    }

    @Test(
        "Cancel while the event buffer is full yields one last cancelled terminal",
        .timeLimit(.minutes(1))
    )
    func cancelWithFullBuffer() async throws {
        let fixture = try TempFixture()
        // Dedicated spool root outside the scanned tree so the count cannot be
        // polluted by other parallel suites.
        let spoolRoot = try TempFixture(prefix: "spacejudge-spool-cancel-full")
        for directory in 0..<8 {
            for file in 0..<200 {
                try fixture.file("d\(directory)/f\(file)", contents: "x")
            }
        }
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 4,
                batchNodeLimit: 20,
                batchTimeMilliseconds: 100_000,
                eventBufferSize: 1,
                spoolDirectory: spoolRoot.url
            )
        )
        let scanID = ScanID()
        let spoolBefore = spoolFiles(in: spoolRoot.url).count
        let fdsBefore = settledFileDescriptorCount()
        let stream = engine.events(for: request(for: fixture.url.path), scanID: scanID)
        var iterator = stream.makeAsyncIterator()

        var events: [ScanEvent] = []
        if let first = try await iterator.next() { events.append(first) }
        // With one slot, the producer fills it and every worker piles up on a
        // dropped-yield retry while the consumer is not reading.
        try? await Task.sleep(nanoseconds: 300_000_000)
        await engine.cancel(scanID: scanID)
        let cancelStart = Date()
        while let event = try await iterator.next() { events.append(event) }
        let terminalDelay = Date().timeIntervalSince(cancelStart)

        var cancelledCount = 0
        var completedCount = 0
        var batchesAfterTerminal = 0
        var sawTerminal = false
        var terminalIsLast = false
        for (index, event) in events.enumerated() {
            if sawTerminal, case .batch = event { batchesAfterTerminal += 1 }
            switch event {
            case .completed:
                completedCount += 1
                sawTerminal = true
                terminalIsLast = index == events.count - 1
            case .cancelled:
                cancelledCount += 1
                sawTerminal = true
                terminalIsLast = index == events.count - 1
            default:
                break
            }
        }

        #expect(cancelledCount == 1)
        #expect(completedCount == 0)
        #expect(batchesAfterTerminal == 0)
        #expect(terminalIsLast)
        #expect(terminalDelay < 2.0)
        let diagnostics = await awaitDiagnostics(engine, scanID: scanID)
        #expect(diagnostics != nil)
        #expect(engine.debugDiagnosticsCount() == 0)
        #expect(spoolFiles(in: spoolRoot.url).count <= spoolBefore)
        #expect(settledFileDescriptorCount() <= fdsBefore + 8)
    }

    // MARK: Issue 2 - hard frontier bound and spool

    @Test("A two-item frontier spools overflow and stays complete", .timeLimit(.minutes(2)))
    func narrowFrontierSpools() async throws {
        let fixture = try TempFixture()
        let spoolRoot = try TempFixture(prefix: "spacejudge-spool-narrow")
        for index in 0..<300 {
            try fixture.directory("d\(index)/inner")
        }
        let broadEngine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1,
                maximumQueuedDirectories: 100_000
            )
        )
        let broadScanID = ScanID()
        let narrowEngine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1,
                maximumQueuedDirectories: 2,
                spoolDirectory: spoolRoot.url
            )
        )

        let broad = try await collectScan(
            engine: broadEngine,
            request: request(for: fixture.url.path),
            scanID: broadScanID
        )
        let narrowScanID = ScanID()
        let fdsBefore = settledFileDescriptorCount()
        let spoolBefore = spoolFiles(in: spoolRoot.url).count
        let narrow = try await collectScan(
            engine: narrowEngine,
            request: request(for: fixture.url.path),
            scanID: narrowScanID
        )
        let fdsAfter = settledFileDescriptorCount()
        let spoolAfter = spoolFiles(in: spoolRoot.url).count

        #expect(broad.status == .completed)
        #expect(narrow.status == .completed)
        #expect(broad.canonicalRows() == narrow.canonicalRows())
        #expect(broad.canonicalAggregates() == narrow.canonicalAggregates())
        #expect(broad.rootAggregate()?.attributedBytes == narrow.rootAggregate()?.attributedBytes)
        #expect(broad.fileCount == narrow.fileCount)
        #expect(broad.directoryCount == narrow.directoryCount)

        let narrowDiagnostics = await awaitDiagnostics(narrowEngine, scanID: narrowScanID)
        let broadDiagnostics = await awaitDiagnostics(broadEngine, scanID: broadScanID)
        #expect(narrowDiagnostics != nil)
        #expect((narrowDiagnostics?.queueHighWater ?? .max) <= 2)
        #expect(narrowDiagnostics?.spoolUsed == true)
        #expect(broadDiagnostics?.spoolUsed == false)
        #expect(narrowEngine.debugDiagnosticsCount() == 0)
        #expect(broadEngine.debugDiagnosticsCount() == 0)
        #expect(spoolAfter <= spoolBefore)
        #expect(spoolFiles(in: spoolRoot.url).isEmpty)
        #expect(fdsAfter <= fdsBefore + 8)
    }

    @Test("Consumer termination releases workers and cleans the spool", .timeLimit(.minutes(1)))
    func consumerTermination() async throws {
        let fixture = try TempFixture()
        let spoolRoot = try TempFixture(prefix: "spacejudge-spool-consumer")
        for index in 0..<400 {
            try fixture.directory("d\(index)/inner")
        }
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1,
                maximumQueuedDirectories: 2,
                spoolDirectory: spoolRoot.url
            )
        )
        let scanID = ScanID()
        let spoolBefore = spoolFiles(in: spoolRoot.url).count
        do {
            let stream = engine.events(for: request(for: fixture.url.path), scanID: scanID)
            var seen = 0
            for try await event in stream {
                _ = event
                seen += 1
                if seen >= 1 {
                    break
                }
            }
        }
        // Stream deallocation triggers consumer termination and therefore the
        // same cancel path; the coordinator must finish and be observable.
        let diagnostics = await awaitDiagnostics(engine, scanID: scanID)
        #expect(diagnostics != nil)
        #expect(engine.debugDiagnosticsCount() == 0)
        #expect(spoolFiles(in: spoolRoot.url).count <= spoolBefore)
    }

    // MARK: Issue 3 - cancel discards pending batches

    @Test("Cancel before a batch threshold publishes only the cancelled terminal")
    func cancelPendingBatch() async throws {
        let fixture = try TempFixture()
        try fixture.directory("blocked")
        let fileEntry = RawDirectoryEntry(
            nameBytes: Array("pending.txt".utf8),
            kind: .regularFile,
            logicalBytes: 5,
            allocatedBytes: 4096,
            deviceID: 1,
            fileID: 1,
            linkCount: 1
        )
        let blockedEntry = RawDirectoryEntry(
            nameBytes: Array("blocked".utf8),
            kind: .directory
        )
        let enumerator = BlockingEnumerator(firstEntries: [fileEntry, blockedEntry])
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: enumerator,
                workerCount: 1,
                batchNodeLimit: 10,
                batchTimeMilliseconds: 100_000,
                eventBufferSize: 16
            )
        )
        let scanID = ScanID()
        let stream = engine.events(for: request(for: fixture.url.path), scanID: scanID)

        let consumer = Task { () throws -> [ScanEvent] in
            var events: [ScanEvent] = []
            for try await event in stream {
                events.append(event)
            }
            return events
        }

        #expect(enumerator.waitUntilBlocking())
        await engine.cancel(scanID: scanID)
        enumerator.release()
        let events = try await consumer.value

        var batchCount = 0
        var progressCount = 0
        var issueCount = 0
        var cancelledCount = 0
        var completedCount = 0
        for event in events {
            switch event {
            case .batch: batchCount += 1
            case .progress: progressCount += 1
            case .issue: issueCount += 1
            case .cancelled: cancelledCount += 1
            case .completed: completedCount += 1
            case .started: break
            }
        }
        #expect(batchCount == 0)
        #expect(progressCount == 0)
        #expect(issueCount == 0)
        #expect(cancelledCount == 1)
        #expect(completedCount == 0)
        if case .cancelled = events.last {} else {
            Issue.record("last event was not cancelled: \(String(describing: events.last))")
        }
    }

    @Test("Cancelling a spooled scan removes the spool file", .timeLimit(.minutes(2)))
    func cancelSpooledScan() async throws {
        let fixture = try TempFixture()
        let spoolRoot = try TempFixture(prefix: "spacejudge-spool-cancel")
        for index in 0..<400 {
            try fixture.directory("d\(index)/inner")
        }
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1,
                batchNodeLimit: 10,
                eventBufferSize: 4,
                maximumQueuedDirectories: 2,
                spoolDirectory: spoolRoot.url
            )
        )
        let scanID = ScanID()
        let spoolBefore = spoolFiles(in: spoolRoot.url).count
        let collected = try await collectScan(
            engine: engine,
            request: request(for: fixture.url.path),
            scanID: scanID,
            cancelAfterFirstBatch: true
        )
        #expect(collected.status == .cancelled)
        #expect(collected.terminalCount == 1)
        let diagnostics = await awaitDiagnostics(engine, scanID: scanID)
        #expect(diagnostics?.spoolUsed == true)
        #expect((diagnostics?.queueHighWater ?? .max) <= 2)
        #expect(engine.debugDiagnosticsCount() == 0)
        #expect(spoolFiles(in: spoolRoot.url).count <= spoolBefore)
        #expect(spoolFiles(in: spoolRoot.url).isEmpty)
    }

    // MARK: Issue 6 - damaged hard link does not pollute a later claim

    @Test("An unknown allocation does not poison a later known hard-link claim")
    func unknownAllocationDoesNotPoisonHardLinkClaim() async throws {
        let fixture = try TempFixture()
        let unknown = RawDirectoryEntry(
            nameBytes: Array("unknown".utf8),
            kind: .regularFile,
            logicalBytes: 100,
            allocatedBytes: nil,
            deviceID: 7,
            fileID: 99,
            linkCount: 2
        )
        let known = RawDirectoryEntry(
            nameBytes: Array("known".utf8),
            kind: .regularFile,
            logicalBytes: 100,
            allocatedBytes: 4096,
            deviceID: 7,
            fileID: 99,
            linkCount: 2
        )
        let enumerator = FollowupScriptedEnumerator([.entries([unknown, known])])
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(enumerator: enumerator, workerCount: 1)
        )
        let collected = try await collectScan(
            engine: engine,
            request: request(for: fixture.url.path)
        )

        #expect(collected.status == .completed)
        // Unknown allocation is legitimate, not an I/O error.
        #expect(collected.summary?.issueCount == 0)
        #expect(collected.issueCount == 0)
        for node in collected.nodes.values {
            if let allocated = node.allocatedBytes {
                #expect(node.attributedBytes <= allocated)
            }
        }
        let unknownNode = collected.nodes.values.first {
            collected.relativePath(of: $0.id) == "unknown"
        }
        #expect(unknownNode?.allocatedBytes == nil)
        #expect(unknownNode?.attributedBytes == 0)

        let knownNode = collected.nodes.values.first {
            collected.relativePath(of: $0.id) == "known"
        }
        #expect(knownNode?.attributedBytes == 4096)
        #expect(knownNode?.flags.contains(.duplicateHardLink) == false)
        // The unknown entry still counts as a file and contributes its logical bytes.
        #expect(collected.fileCount == 2)
        #expect(collected.rootAggregate()?.logicalBytes == 200)
        #expect(collected.rootAggregate()?.attributedBytes == 4096)
    }

    // MARK: Issue 7 - aggregate overflow is fatal, not saturated

    @Test("Aggregate overflow fails the stream without a false terminal")
    func aggregateOverflowFails() async throws {
        let fixture = try TempFixture()
        let first = RawDirectoryEntry(
            nameBytes: Array("a".utf8),
            kind: .regularFile,
            logicalBytes: UInt64.max,
            allocatedBytes: UInt64.max,
            deviceID: 1,
            fileID: 1,
            linkCount: 1
        )
        let second = RawDirectoryEntry(
            nameBytes: Array("b".utf8),
            kind: .regularFile,
            logicalBytes: UInt64.max,
            allocatedBytes: UInt64.max,
            deviceID: 1,
            fileID: 2,
            linkCount: 1
        )
        let enumerator = FollowupScriptedEnumerator([.entries([first, second])])
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(enumerator: enumerator, workerCount: 1)
        )

        var sawTerminal = false
        do {
            for try await event in engine.events(for: request(for: fixture.url.path)) {
                switch event {
                case .completed, .cancelled:
                    sawTerminal = true
                default:
                    break
                }
            }
            Issue.record("expected an aggregation failure")
        } catch let error as ScanError {
            if case .aggregationOverflow = error {
                // expected
            } else {
                Issue.record("unexpected ScanError \(error)")
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(!sawTerminal)
    }

    // MARK: Issue 2 - diagnostics do not accumulate

    @Test("Completion diagnostics are consumable and do not accumulate")
    func diagnosticsDoNotAccumulate() async throws {
        let fixture = try TempFixture()
        try fixture.file("a", contents: "x")
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1
            )
        )
        for index in 0..<6 {
            let scanID = ScanID()
            _ = try await collectScan(
                engine: engine,
                request: request(for: fixture.url.path),
                scanID: scanID
            )
            let diagnostics = await awaitDiagnostics(engine, scanID: scanID)
            #expect(diagnostics != nil, "scan \(index) did not produce diagnostics")
            // Taking must remove the record immediately.
            #expect(engine.takeDiagnostics(for: scanID) == nil)
        }
        #expect(engine.debugDiagnosticsCount() == 0)
    }

    @Test("Unconsumed completion diagnostics have a hard retention limit")
    func unconsumedDiagnosticsAreBounded() {
        let registry = CoordinatorRegistry()
        var scanIDs: [ScanID] = []
        for index in 0..<(CoordinatorRegistry.maximumRetainedDiagnostics + 10) {
            let scanID = ScanID()
            scanIDs.append(scanID)
            registry.recordDiagnostics(
                ScanDiagnostics(queueHighWater: index, spoolUsed: index.isMultiple(of: 2)),
                for: scanID
            )
        }

        #expect(registry.diagnosticsCount == CoordinatorRegistry.maximumRetainedDiagnostics)
        #expect(registry.takeDiagnostics(for: scanIDs.first!) == nil)
        #expect(registry.takeDiagnostics(for: scanIDs.last!) != nil)
        #expect(registry.diagnosticsCount == CoordinatorRegistry.maximumRetainedDiagnostics - 1)
    }

    // MARK: Issue 4 - terminal decision race

    @Test("Cancel racing a locked terminal yields one consistent terminal", .timeLimit(.minutes(1)))
    func terminalRaceSingleConsistentTerminal() async throws {
        let fixture = try TempFixture()
        try fixture.file("only", contents: "x")
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1,
                batchNodeLimit: 100_000,
                batchTimeMilliseconds: 100_000,
                eventBufferSize: 2
            )
        )
        let scanID = ScanID()
        let stream = engine.events(for: request(for: fixture.url.path), scanID: scanID)
        var iterator = stream.makeAsyncIterator()
        var events: [ScanEvent] = []
        if let first = try await iterator.next() {
            events.append(first)
        }
        // With a two-slot buffer the producer now fills batch+progress and is
        // blocked trying to emit the terminal, whose decision is already locked.
        try? await Task.sleep(nanoseconds: 200_000_000)
        await engine.cancel(scanID: scanID)
        while let event = try await iterator.next() {
            events.append(event)
        }

        var terminalCount = 0
        var sawCompleted = false
        var sawCancelled = false
        var inconsistent = false
        for event in events {
            switch event {
            case .completed(let summary):
                terminalCount += 1
                sawCompleted = true
                if summary.status != .completed { inconsistent = true }
            case .cancelled(let summary):
                terminalCount += 1
                sawCancelled = true
                if summary.status != .cancelled { inconsistent = true }
            default:
                break
            }
        }
        #expect(terminalCount == 1)
        #expect(!(sawCompleted && sawCancelled))
        #expect(!inconsistent)
    }
}
