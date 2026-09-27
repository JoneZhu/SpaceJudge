import Foundation
import SpaceJudgeDomain

/// Tunables for `FileSystemScanEngine`.
///
/// The defaults follow `docs/08-phase-1-design.md`: at most four workers, a
/// 2,000-node or 50 ms batch window and a bounded event buffer.
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

    public init(
        enumerator: any DirectoryEnumerator = DarwinBulkEnumerator(),
        workerCount: Int? = nil,
        batchNodeLimit: Int = 2000,
        batchTimeMilliseconds: Int = 50,
        eventBufferSize: Int = 256,
        maximumQueuedDirectories: Int = 65_536,
        spoolDirectory: URL? = nil,
        volumeFactsProvider: any VolumeFactsProviding = FoundationVolumeFactsProvider()
    ) {
        self.enumerator = enumerator
        self.workerCount = workerCount
        self.batchNodeLimit = max(1, batchNodeLimit)
        self.batchTimeMilliseconds = max(1, batchTimeMilliseconds)
        self.eventBufferSize = max(1, eventBufferSize)
        self.maximumQueuedDirectories = max(1, maximumQueuedDirectories)
        self.spoolDirectory = spoolDirectory
        self.volumeFactsProvider = volumeFactsProvider
    }

    /// Effective worker count, clamped to at least one.
    public var resolvedWorkerCount: Int {
        if let workerCount {
            return max(1, workerCount)
        }
        return max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
    }
}
