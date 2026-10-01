import Foundation
import SpaceJudgeDomain

/// Tunables for `FileSystemScanEngine`.
///
/// The defaults follow `docs/08-phase-1-design.md`: at most four workers, a
/// 2,000-node or 50 ms batch window and a bounded event buffer.
///
/// The event buffer is bounded at 64 by default: each buffered event holds a
/// complete `NodeBatch`, and the SQLite consumer can be slower than enumeration,
/// so a smaller buffer bounds how many batches can pile up in memory. The
/// producer retries on dropped yields, so a smaller buffer only increases
/// backpressure; it never drops, reorders or coalesces events.
///
/// Note: feedback-4 measured the million-node CLI rescan and showed the event
/// buffer is *not* the dominant peak-RSS contributor (256 vs 64 vs 1 differed by
/// only a few MB, and even buffer 1 stayed above the 250 MB gate). The 64
/// default is a bounded worst-case limit, not a claim that it fixes the memory
/// gate; the main contributors were consumed work-item path storage and
/// per-directory aggregation working state. Callers may still set any positive
/// value explicitly.
public struct ScanConfiguration: Sendable {
    /// Directory enumeration strategy. Injecting a stub makes error, cancel and
    /// ordering tests independent of the real disk.
    public var enumerator: any DirectoryEnumerator
    /// `nil` selects `min(4, activeProcessorCount)`.
    public var workerCount: Int?
    /// Maximum nodes per emitted `NodeBatch`.
    public var batchNodeLimit: Int
    /// Maximum age of an open batch, in milliseconds.
    public var batchTimeMilliseconds: Int
    /// Bounded event buffer size for the `AsyncThrowingStream` continuation.
    /// Defaults to 64 to bound batch memory under slow persistence.
    public var eventBufferSize: Int
    /// Soft bound for the directory frontier kept in memory.
    public var maximumQueuedDirectories: Int
    /// Directory for the bounded directory spool. `nil` uses the process
    /// temporary directory; production passes the managed snapshot workspace
    /// so one scan boundary covers the database and the queue.
    public var spoolDirectory: URL?
    /// Capacity metering for the root's file system. Injected so tests can
    /// script important/fallback/unknown values without touching a real disk.
    public var volumeFactsProvider: any VolumeFactsProviding
    /// Opt-in bounded live aggregates for the GUI. CLI defaults to final-only.
    public var progressiveDirectoryLimit: Int
    public var progressiveIntervalMilliseconds: Int

    public init(
        enumerator: any DirectoryEnumerator = DarwinBulkEnumerator(),
        workerCount: Int? = nil,
        batchNodeLimit: Int = 2000,
        batchTimeMilliseconds: Int = 50,
        eventBufferSize: Int = 64,
        maximumQueuedDirectories: Int = 65_536,
        spoolDirectory: URL? = nil,
        volumeFactsProvider: any VolumeFactsProviding = FoundationVolumeFactsProvider(),
        progressiveDirectoryLimit: Int = 0,
        progressiveIntervalMilliseconds: Int = 500
    ) {
        self.enumerator = enumerator
        self.workerCount = workerCount
        self.batchNodeLimit = max(1, batchNodeLimit)
        self.batchTimeMilliseconds = max(1, batchTimeMilliseconds)
        self.eventBufferSize = max(1, eventBufferSize)
        self.maximumQueuedDirectories = max(1, maximumQueuedDirectories)
        self.spoolDirectory = spoolDirectory
        self.volumeFactsProvider = volumeFactsProvider
        self.progressiveDirectoryLimit = max(0, min(512, progressiveDirectoryLimit))
        self.progressiveIntervalMilliseconds = max(100, progressiveIntervalMilliseconds)
    }

    /// Effective worker count, clamped to at least one.
    public var resolvedWorkerCount: Int {
        if let workerCount {
            return max(1, workerCount)
        }
        return max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
    }
}
