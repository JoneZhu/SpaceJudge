import Darwin
import Foundation
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore
import SpaceJudgeUseCases

/// Stage-tagged failure. The executable maps `exitCode` directly.
public enum E2EBenchError: Error, Sendable, Equatable, CustomStringConvertible {
    case argument(E2EBenchArgumentError)
    case fixture(String)
    case scanStore(String)
    case verification(String)

    public var exitCode: Int32 {
        switch self {
        case .argument: return 2
        case .fixture: return 3
        case .scanStore: return 4
        case .verification: return 5
        }
    }

    public var description: String {
        switch self {
        case .argument(let error): return error.description
        case .fixture(let message): return message
        case .scanStore(let message): return message
        case .verification(let message): return message
        }
    }
}

/// Thread-safe collector for the timing and cancellation facts observed through
/// `PersistingScanUpdate`. Every value is stamped with the same monotonic clock
/// used around `runner.run`.
final class ScanTracker: @unchecked Sendable {
    struct Timing {
        var firstStartedNanos: UInt64?
        var firstCommittedNanos: UInt64?
        var cancelRequestedNanos: UInt64?
        var cancelTerminalNanos: UInt64?
        var terminalStatus: ScanStatus?
        var committedAfterCancel: UInt64
        var progressAfterCancel: UInt64
    }

    private let lock = NSLock()
    private let cancelAfterFirstCommit: Bool
    private var scanID: ScanID?
    private var firstStartedNanos: UInt64?
    private var firstCommittedNanos: UInt64?
    private var cancelRequestedNanos: UInt64?
    private var cancelTerminalNanos: UInt64?
    private var terminalStatus: ScanStatus?
    private var committedAfterCancel: UInt64 = 0
    private var progressAfterCancel: UInt64 = 0

    init(cancelAfterFirstCommit: Bool) {
        self.cancelAfterFirstCommit = cancelAfterFirstCommit
    }

    func handle(
        _ update: PersistingScanUpdate,
        engine: FileSystemScanEngine
    ) {
        switch update {
        case .started(let metadata):
            lock.lock()
            if firstStartedNanos == nil {
                firstStartedNanos = DispatchTime.now().uptimeNanoseconds
            }
            if scanID == nil { scanID = metadata.scanID }
            lock.unlock()

        case .committed:
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            if firstCommittedNanos == nil {
                firstCommittedNanos = now
                let shouldCancel = cancelAfterFirstCommit && cancelRequestedNanos == nil
                if shouldCancel { cancelRequestedNanos = now }
                let id = scanID
                lock.unlock()
                if shouldCancel, let id {
                    Task { await engine.cancel(scanID: id) }
                }
            } else {
                if cancelRequestedNanos != nil { committedAfterCancel += 1 }
                lock.unlock()
            }

        case .progress:
            lock.lock()
            if cancelRequestedNanos != nil, cancelTerminalNanos == nil {
                progressAfterCancel += 1
            }
            lock.unlock()

        case .terminal(let summary):
            lock.lock()
            cancelTerminalNanos = DispatchTime.now().uptimeNanoseconds
            terminalStatus = summary.status
            lock.unlock()

        case .issueRecorded:
            break
        }
    }

    func timing() -> Timing {
        lock.lock()
        defer { lock.unlock() }
        return Timing(
            firstStartedNanos: firstStartedNanos,
            firstCommittedNanos: firstCommittedNanos,
            cancelRequestedNanos: cancelRequestedNanos,
            cancelTerminalNanos: cancelTerminalNanos,
            terminalStatus: terminalStatus,
            committedAfterCancel: committedAfterCancel,
            progressAfterCancel: progressAfterCancel
        )
    }
}

/// Runs the production end-to-end pipeline against a generated real-directory
/// fixture: DarwinBulkEnumerator → FileSystemScanEngine → PersistingScanRunner
/// → SQLiteSnapshotRepository → close → openReadOnly → verification.
public struct E2EBenchRunner: Sendable {
    public let metrics: SystemMetrics
    private let artifactRootProvider: @Sendable (String?) throws -> ArtifactRoot

    public init(
        metrics: SystemMetrics = .live,
        artifactRootProvider: @escaping @Sendable (String?) throws -> ArtifactRoot = {
            try ArtifactRoot.prepare(keepArtifactsAt: $0)
        }
    ) {
        self.metrics = metrics
        self.artifactRootProvider = artifactRootProvider
    }

    /// Executes one benchmark. On failure the temporary artifact root is still
    /// removed after every repository handle has been closed; a cleanup failure
    /// on the success path is a hard error instead of a silent success.
    public func run(
        _ options: E2EBenchOptions,
        log: @Sendable (String) -> Void
    ) async throws -> E2EBenchResult {
        let artifact: ArtifactRoot
        do {
            artifact = try artifactRootProvider(options.keepArtifactsPath)
        } catch let error as FixtureError {
            throw E2EBenchError.fixture(error.description)
        } catch {
            throw E2EBenchError.fixture("\(error)")
        }

        var writer: SQLiteSnapshotRepository?
        var reader: SQLiteSnapshotRepository?
        var removedArtifacts = false
        do {
            let result = try await execute(
                options,
                artifact: artifact,
                writer: &writer,
                reader: &reader,
                log: log
            )
            if artifact.isTemporary {
                guard artifact.cleanup() else {
                    throw E2EBenchError.fixture(
                        "temporary artifacts could not be removed; refusing to report success"
                    )
                }
                removedArtifacts = true
                log("removed temporary artifacts")
            } else {
                log("kept artifacts at \(artifact.rootPath)")
            }
            return result
        } catch {
            await writer?.close()
            await reader?.close()
            if artifact.isTemporary, !removedArtifacts {
                if artifact.cleanup() {
                    log("removed temporary artifacts")
                } else {
                    log("warning: could not remove temporary artifacts at \(artifact.rootPath)")
                }
            }
            throw error
        }
    }

    private func execute(
        _ options: E2EBenchOptions,
        artifact: ArtifactRoot,
        writer: inout SQLiteSnapshotRepository?,
        reader: inout SQLiteSnapshotRepository?,
        log: @Sendable (String) -> Void
    ) async throws -> E2EBenchResult {
        // 1. Deterministic fixture generation.
        log("generating \(options.shape.rawValue) fixture with \(options.requestedNodes) nodes")
        let generationStart = Date()
        let manifest: FixtureManifest
        do {
            manifest = try FixtureGenerator().generate(options: options, at: artifact.fixturePath)
        } catch let error as FixtureError {
            throw E2EBenchError.fixture(error.description)
        } catch {
            throw E2EBenchError.fixture("\(error)")
        }
        let generationSeconds = Date().timeIntervalSince(generationStart)
        log(
            "fixture ready: nodes=\(manifest.actualNodes) dirs=\(manifest.directoryCount) "
                + "files=\(manifest.fileCount) in \(format(generationSeconds))s"
        )

        // 2. Baseline descriptors before production components open handles.
        let fdBaseline = metrics.openFileDescriptorCount()

        // 3. Open the writable snapshot repository.
        let repository: SQLiteSnapshotRepository
        do {
            repository = try SQLiteSnapshotRepository(path: artifact.databasePath)
        } catch {
            throw E2EBenchError.scanStore("cannot open store: \(error)")
        }
        writer = repository

        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(enumerator: DarwinBulkEnumerator())
        )
        let runner = PersistingScanRunner(engine: engine, repository: repository)
        let request = ScanRequest(
            root: ScanRoot(fileSystemPath: artifact.fixturePath, displayName: "fixture")
        )
        let tracker = ScanTracker(cancelAfterFirstCommit: options.cancelAfterFirstCommit)

        // 4. Run the real scanner through the persisting runner.
        let startNanos = DispatchTime.now().uptimeNanoseconds
        let summary: ScanSummary
        do {
            summary = try await runner.run(request) { update in
                tracker.handle(update, engine: engine)
            }
        } catch {
            throw E2EBenchError.scanStore("scan/store failed: \(error)")
        }
        let endNanos = DispatchTime.now().uptimeNanoseconds
        let scanSeconds = seconds(from: startNanos, to: endNanos)
        let timing = tracker.timing()
        guard timing.firstCommittedNanos != nil else {
            throw E2EBenchError.verification("no successful commit was observed")
        }
        guard timing.firstStartedNanos != nil else {
            throw E2EBenchError.verification("no started event was observed")
        }

        // 5. Read the persisted counts while the writer is still open.
        let state: ScanSnapshotState
        let statistics: SnapshotStatistics
        do {
            guard let persistedState = try await repository.scanState(summary.scanID) else {
                throw E2EBenchError.verification("persisted scan state is missing")
            }
            state = persistedState
            statistics = try await repository.statistics(summary.scanID)
        } catch let error as E2EBenchError {
            throw error
        } catch {
            throw E2EBenchError.scanStore("cannot read persisted counts: \(error)")
        }

        // 6. Close, then measure on-disk size and peak RSS.
        await repository.close()
        writer = nil
        let sizes = FileSizes.measure(at: artifact.databasePath)
        let peakResidentBytes = metrics.peakResidentBytes()

        // 7. Reopen read-only and verify the committed snapshot.
        let reopened: SQLiteSnapshotRepository
        do {
            reopened = try SQLiteSnapshotRepository.openReadOnly(path: artifact.databasePath)
        } catch {
            throw E2EBenchError.verification("read-only reopen failed: \(error)")
        }
        reader = reopened

        let expectedStatus: ScanStatus = options.cancelAfterFirstCommit ? .cancelled : .completed
        var rootAggregateComplete = false
        do {
            try await verify(
                summary: summary,
                expectedStatus: expectedStatus,
                manifest: manifest,
                writtenState: state,
                writtenStatistics: statistics,
                reopened: reopened,
                rootAggregateComplete: &rootAggregateComplete
            )
        } catch let error as E2EBenchError {
            throw error
        } catch {
            throw E2EBenchError.verification("verification failed: \(error)")
        }
        await reopened.close()
        reader = nil

        // 8. Descriptor delta after every handle is closed.
        let fdAfterClose = metrics.openFileDescriptorCount()
        let fdDelta: Int? = {
            guard let fdBaseline, let fdAfterClose else { return nil }
            return fdAfterClose - fdBaseline
        }()

        // 9. Assemble the stable JSON-facing result. Throughput always uses the
        // nodes successfully persisted by this run, not the fixture total, so a
        // cancelled run cannot inflate nodes/s.
        let nodesPerSecond: Double = {
            guard scanSeconds > 0, statistics.nodeCount > 0 else { return 0 }
            return Double(statistics.nodeCount) / scanSeconds
        }()

        func millis(_ nanos: UInt64?) -> Double? {
            guard let nanos else { return nil }
            return seconds(from: startNanos, to: nanos) * 1000
        }

        let cancelRequestedMillis = options.cancelAfterFirstCommit
            ? millis(timing.cancelRequestedNanos)
            : nil
        let cancelTerminalMillis = options.cancelAfterFirstCommit
            ? millis(timing.cancelTerminalNanos)
            : nil
        let cancelLatencyMillis: Double? = {
            guard let requested = timing.cancelRequestedNanos,
                  let terminal = timing.cancelTerminalNanos,
                  terminal >= requested else { return nil }
            return seconds(from: requested, to: terminal) * 1000
        }()
        let updatesAfterCancel: UInt64? = options.cancelAfterFirstCommit
            ? timing.committedAfterCancel + timing.progressAfterCancel
            : nil

        log(
            "scan finished: status=\(summary.status) persisted=\(statistics.nodeCount) "
                + "fixture=\(manifest.actualNodes) in \(format(scanSeconds))s "
                + "(\(format(nodesPerSecond)) persisted nodes/s)"
        )

        return E2EBenchResult(
            requestedNodes: options.requestedNodes,
            actualNodes: manifest.actualNodes,
            shape: options.shape.rawValue,
            fixtureGenerationSeconds: generationSeconds,
            fixtureLogicalBytes: manifest.logicalBytes,
            firstStartedMillis: millis(timing.firstStartedNanos) ?? 0,
            firstCommittedMillis: millis(timing.firstCommittedNanos) ?? 0,
            scanAndPersistSeconds: scanSeconds,
            nodesPerSecond: nodesPerSecond,
            peakResidentBytes: peakResidentBytes,
            databaseBytesAfterClose: sizes.total,
            databaseMainBytesAfterClose: sizes.main,
            walBytesAfterClose: sizes.wal,
            shmBytesAfterClose: sizes.shm,
            fdBaseline: fdBaseline,
            fdAfterClose: fdAfterClose,
            fdDelta: fdDelta,
            status: Self.name(summary.status),
            persistedNodes: statistics.nodeCount,
            persistedNames: statistics.nameCount,
            persistedAggregates: statistics.aggregateCount,
            rootAggregateComplete: rootAggregateComplete,
            cacheState: "uncontrolled",
            cancelRequestedMillis: cancelRequestedMillis,
            cancelTerminalMillis: cancelTerminalMillis,
            cancelLatencyMillis: cancelLatencyMillis,
            updatesAfterCancelRequest: updatesAfterCancel
        )
    }

    // MARK: Verification

    private func verify(
        summary: ScanSummary,
        expectedStatus: ScanStatus,
        manifest: FixtureManifest,
        writtenState: ScanSnapshotState,
        writtenStatistics: SnapshotStatistics,
        reopened: SQLiteSnapshotRepository,
        rootAggregateComplete: inout Bool
    ) async throws {
        guard summary.status == expectedStatus else {
            throw E2EBenchError.verification(
                "terminal status \(summary.status) != \(expectedStatus)"
            )
        }
        guard writtenState.status == expectedStatus else {
            throw E2EBenchError.verification(
                "persisted status \(writtenState.status) != \(expectedStatus)"
            )
        }
        guard manifest.actualNodes == manifest.requestedNodes else {
            throw E2EBenchError.verification(
                "generated node count \(manifest.actualNodes) != requested \(manifest.requestedNodes)"
            )
        }

        if expectedStatus == .completed {
            // A completed scan must have persisted every generated node and
            // must agree exactly with the fixture manifest.
            guard writtenStatistics.nodeCount == UInt64(manifest.actualNodes) else {
                throw E2EBenchError.verification(
                    "persisted node count \(writtenStatistics.nodeCount) != \(manifest.actualNodes)"
                )
            }
            guard summary.fileCount == UInt64(manifest.fileCount) else {
                throw E2EBenchError.verification(
                    "summary file count \(summary.fileCount) != \(manifest.fileCount)"
                )
            }
            guard summary.directoryCount == UInt64(manifest.directoryCount) else {
                throw E2EBenchError.verification(
                    "summary directory count \(summary.directoryCount) != \(manifest.directoryCount)"
                )
            }
        } else {
            // Cancel legitimately stops before the whole fixture is persisted;
            // only boundedness and reopen consistency can be asserted.
            guard writtenStatistics.nodeCount <= UInt64(manifest.actualNodes) else {
                throw E2EBenchError.verification(
                    "persisted node count \(writtenStatistics.nodeCount) exceeds the fixture"
                )
            }
        }

        guard let reopenedState = try await reopened.scanState(summary.scanID) else {
            throw E2EBenchError.verification("reopened scan state is missing")
        }
        guard reopenedState.status == expectedStatus else {
            throw E2EBenchError.verification(
                "reopened status \(reopenedState.status) != \(expectedStatus)"
            )
        }
        guard reopenedState.lastRevision >= Revision(1) else {
            throw E2EBenchError.verification("reopened last revision is 0")
        }
        guard reopenedState.lastRevision == writtenState.lastRevision else {
            throw E2EBenchError.verification("reopened revision changed across reopen")
        }

        let reopenedStatistics = try await reopened.statistics(summary.scanID)
        guard reopenedStatistics.nodeCount == writtenStatistics.nodeCount else {
            throw E2EBenchError.verification("reopened node count changed across reopen")
        }
        guard reopenedState.fileCount == summary.fileCount,
              reopenedState.directoryCount == summary.directoryCount else {
            throw E2EBenchError.verification("reopened summary counters changed across reopen")
        }

        let rootAggregate = try await reopened.aggregate(
            of: writtenState.rootNodeID,
            in: summary.scanID
        )
        if expectedStatus == .completed {
            guard let rootAggregate, rootAggregate.isComplete else {
                throw E2EBenchError.verification(
                    "completed scan has no complete root aggregate"
                )
            }
            guard rootAggregate.attributedBytes == summary.rootAttributedBytes else {
                throw E2EBenchError.verification(
                    "root aggregate \(rootAggregate.attributedBytes) "
                        + "!= summary \(summary.rootAttributedBytes)"
                )
            }
            guard reopenedState.rootAttributedBytes == summary.rootAttributedBytes else {
                throw E2EBenchError.verification("persisted root attribution mismatch")
            }
        }
        rootAggregateComplete = rootAggregate?.isComplete ?? false
    }

    // MARK: Helpers

    private func seconds(from start: UInt64, to end: UInt64) -> Double {
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000_000
    }

    private func format(_ value: Double) -> String {
        guard value.isFinite else { return "0.000000" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func name(_ status: ScanStatus) -> String {
        switch status {
        case .running: return "running"
        case .cancelling: return "cancelling"
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .interrupted: return "interrupted"
        }
    }
}

private struct FileSizes {
    let main: Int64
    let wal: Int64
    let shm: Int64
    var total: Int64 { main + wal + shm }

    static func measure(at path: String) -> FileSizes {
        func size(_ candidate: String) -> Int64 {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate),
                  let number = attributes[.size] as? NSNumber else {
                return 0
            }
            return number.int64Value
        }
        return FileSizes(
            main: size(path),
            wal: size(path + "-wal"),
            shm: size(path + "-shm")
        )
    }
}
