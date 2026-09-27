import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

/// Capacity provider that records calls and returns a fixed value.
private final class RecordingVolumeFactsProvider: VolumeFactsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let value: VolumeFacts

    init(_ value: VolumeFacts) {
        self.value = value
    }

    func facts(forFileSystemPath path: String) -> VolumeFacts {
        lock.lock()
        calls += 1
        lock.unlock()
        return value
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@Suite("Volume metering", .serialized)
struct VolumeMeteringTests {
    private let facts = VolumeFacts(
        totalCapacityBytes: 512_000_000_000,
        availableCapacityBytes: 99_400_000_000,
        capacitySource: .importantUsage
    )

    private func request(for path: String) -> ScanRequest {
        ScanRequest(root: ScanRoot(fileSystemPath: path, displayName: "fixture"))
    }

    @Test("The same facts reach started metadata and the terminal summary")
    func factsReachMetadataAndSummary() async throws {
        let fixture = try TempFixture()
        try fixture.file("a.txt", contents: "abc")
        let provider = RecordingVolumeFactsProvider(facts)
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1,
                volumeFactsProvider: provider
            )
        )

        var metadataVolume: VolumeFacts?
        var summaryVolume: VolumeFacts?
        for try await event in engine.events(for: request(for: fixture.url.path)) {
            switch event {
            case .started(let metadata):
                metadataVolume = metadata.volume
            case .completed(let summary):
                summaryVolume = summary.volume
            case .cancelled(let summary):
                summaryVolume = summary.volume
            default:
                break
            }
        }
        #expect(metadataVolume == facts)
        #expect(summaryVolume == facts)
        #expect(provider.callCount == 1)
    }

    @Test("Unknown capacity never fails the scan and never becomes zero")
    func unknownCapacityIsNotFatal() async throws {
        let fixture = try TempFixture()
        try fixture.file("a.txt", contents: "abc")
        let unknown = VolumeFacts(
            totalCapacityBytes: nil,
            availableCapacityBytes: nil,
            capacitySource: .unavailable
        )
        let provider = RecordingVolumeFactsProvider(unknown)
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1,
                volumeFactsProvider: provider
            )
        )

        let collected = try await collectScan(engine: engine, request: request(for: fixture.url.path))
        #expect(collected.status == .completed)
        #expect(collected.summary?.volume == unknown)
        #expect(collected.summary?.volume?.totalCapacityBytes == nil)
        #expect(collected.summary?.unattributedBytes == nil)
    }

    @Test("A failed root open does not meter the volume")
    func noMeteringOnFailedRoot() async throws {
        let provider = RecordingVolumeFactsProvider(facts)
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1,
                volumeFactsProvider: provider
            )
        )
        let path = "/spacejudge-missing-\(UUID().uuidString)"
        do {
            _ = try await collectScan(engine: engine, request: request(for: path))
            Issue.record("expected root failure")
        } catch let error as ScanError {
            #expect(error == .rootOpenFailed(errno: ENOENT))
        }
        #expect(provider.callCount == 0)
    }

    @Test("A cancelled scan keeps the metered facts")
    func cancelledScanKeepsFacts() async throws {
        let fixture = try TempFixture()
        for index in 0..<500 {
            try fixture.file("f\(index)", contents: "x")
        }
        let provider = RecordingVolumeFactsProvider(facts)
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1,
                batchNodeLimit: 10,
                eventBufferSize: 4,
                volumeFactsProvider: provider
            )
        )
        let collected = try await collectScan(
            engine: engine,
            request: request(for: fixture.url.path),
            cancelAfterFirstBatch: true
        )
        #expect(collected.status == .cancelled)
        #expect(collected.summary?.volume == facts)
    }
}
