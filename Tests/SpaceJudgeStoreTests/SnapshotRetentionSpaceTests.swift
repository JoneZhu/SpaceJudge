import Darwin
import Foundation
import SQLite3
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeStore

/// Thread-safe, scriptable capacity provider so gate tests can change the
/// reported free space between calls.
final class MutableCapacityProvider: StorageCapacityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64?

    init(bytes: UInt64?) {
        self.value = bytes
    }

    func set(_ bytes: UInt64?) {
        lock.lock()
        value = bytes
        lock.unlock()
    }

    func availableForImportantUsageBytes() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("Snapshot retention and space gates", .serialized)
struct SnapshotRetentionSpaceTests {
    @Test("GUI refresh retains its displayed snapshot across retries, bounded to two scans")
    func refreshRetention() async throws {
        let database = try TempDatabase()
        let repository = try SQLiteSnapshotRepository(path: database.path, maximumRetainedScans: 2)
        let first = sampleScanID(71), second = sampleScanID(72), third = sampleScanID(73)
        try await repository.begin(sampleMetadata(scanID: first))
        try await writeMinimal(repository, scanID: first)
        await repository.retainForRefresh(first)
        try await repository.begin(sampleMetadata(scanID: second))
        #expect(try await repository.scanState(first) != nil)
        try await repository.begin(sampleMetadata(scanID: third))
        #expect(try await repository.scanState(first) != nil)
        #expect(try await repository.scanState(second) == nil)
        #expect(try await repository.scanState(third) != nil)
        // Changing the chosen location clears refresh retention.
        await repository.retainForRefresh(nil)
        try await repository.begin(sampleMetadata(scanID: sampleScanID(74)))
        #expect(try await repository.scanState(first) == nil)
        #expect(try await repository.scanState(third) == nil)
        await repository.close()
    }

    @Test("Exact-name lookup reaches small items beyond the top 500, preserving raw bytes")
    func exactNameLookup() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scan = sampleScanID(75)
        try await repository.begin(sampleMetadata(scanID: scan))
        let rawName = Data([0xff, 0xfe, 0x61])
        var names = [sampleName(1, "root")]
        var nodes = [sampleNode(id: 1, parent: nil, name: 1, scanID: scan, kind: .directory, attributed: 0)]
        for id: UInt64 in 2...602 {
            names.append(id == 602 ? NameRecord(id: NameID(id), utf8: rawName) : sampleName(id, "item-\(id)"))
            nodes.append(sampleNode(id: id, parent: 1, name: id, scanID: scan, attributed: id == 602 ? 1 : 100))
        }
        try await repository.write(NodeBatch(scanID: scan, revision: Revision(1), names: names, nodes: nodes))
        let page = try await repository.childPage(of: NodeID(1), in: scan, limit: 500)
        #expect(!page.items.contains { $0.node.id == NodeID(602) })
        #expect(try await repository.child(named: rawName, of: NodeID(1), in: scan)?.id == NodeID(602))
        #expect(try await repository.child(named: Data("absent".utf8), of: NodeID(1), in: scan) == nil)
        await repository.close()
    }
    private func writeMinimal(
        _ repository: SQLiteSnapshotRepository,
        scanID: ScanID,
        revision: UInt64 = 1
    ) async throws {
        try await repository.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(revision),
                names: [sampleName(revision, "node-\(revision)")],
                nodes: [
                    sampleNode(
                        id: revision, parent: nil, name: revision, scanID: scanID,
                        kind: .directory, logical: nil, allocated: nil, attributed: 0
                    )
                ]
            )
        )
    }

    private func rowCount(
        _ table: String,
        keyColumn: String = "scan_id",
        scanID: ScanID,
        path: String
    ) throws -> Int {
        let database = try SQLiteDatabase.openReadOnly(path: path)
        defer { database.close() }
        let statement = try database.prepare("SELECT COUNT(*) FROM \(table) WHERE \(keyColumn) = ?")
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)
        guard try statement.step() else { return 0 }
        return Int(statement.columnInt64(0))
    }

    // MARK: Single-scan retention

    @Test("A second begin cascades every old scan row away")
    func secondBeginCascades() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanA = sampleScanID(1)
        let scanB = sampleScanID(2)
        try await repository.begin(sampleMetadata(scanID: scanA))
        try await writeMinimal(repository, scanID: scanA)
        try await repository.record(
            ScanIssue(scanID: scanA, category: .io, errnoValue: EIO, count: 1)
        )
        try await repository.finish(
            ScanSummary(
                scanID: scanA, status: .completed,
                startedAt: Date(timeIntervalSince1970: 1_000),
                fileCount: 0, directoryCount: 1, inaccessibleCount: 0,
                issueCount: 1, rootAttributedBytes: 0
            )
        )

        try await repository.begin(sampleMetadata(scanID: scanB))

        #expect(try await repository.scanState(scanA) == nil)
        #expect(try await repository.scanSummary(scanA) == nil)
        #expect(try await repository.name(id: NameID(1), in: scanA) == nil)
        #expect(try await repository.children(of: NodeID(1), in: scanA).isEmpty)
        for table in ["names", "nodes", "directory_aggregates", "issues"] {
            #expect(try rowCount(table, scanID: scanA, path: database.path) == 0, "\(table)")
        }
        #expect(try rowCount("scans", keyColumn: "id", scanID: scanA, path: database.path) == 0)
        #expect(try rowCount("scans", keyColumn: "id", scanID: scanB, path: database.path) == 1)
        await repository.close()
    }

    @Test("A terminal snapshot stays queryable until the next begin")
    func terminalSurvivesUntilNextBegin() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await writeMinimal(repository, scanID: scanID)
        try await repository.finish(
            ScanSummary(
                scanID: scanID, status: .cancelled,
                startedAt: Date(timeIntervalSince1970: 1_000),
                fileCount: 0, directoryCount: 1, inaccessibleCount: 0,
                issueCount: 0, rootAttributedBytes: 0
            )
        )
        let afterFinish = try await repository.scanState(scanID)
        #expect(afterFinish?.status == .cancelled)
        #expect(try await repository.name(id: NameID(1), in: scanID) != nil)
        await repository.close()
    }

    @Test("A refused begin keeps the previous snapshot and leaves no running row")
    func refusedBeginKeepsPrevious() async throws {
        let database = try TempDatabase()
        let gate = StorageSpacePolicy(startGateBytes: 1_000, runtimeGateBytes: 500)
        let provider = MutableCapacityProvider(bytes: 5_000)
        let repository = try database.open(capacityProvider: provider, spacePolicy: gate)
        let scanA = sampleScanID(1)
        try await repository.begin(sampleMetadata(scanID: scanA))
        try await writeMinimal(repository, scanID: scanA)
        try await repository.finish(
            ScanSummary(
                scanID: scanA, status: .completed,
                startedAt: Date(timeIntervalSince1970: 1_000),
                fileCount: 0, directoryCount: 1, inaccessibleCount: 0,
                issueCount: 0, rootAttributedBytes: 0
            )
        )

        provider.set(10)
        let scanB = sampleScanID(2)
        await #expect(throws: SnapshotStoreError.self) {
            try await repository.begin(sampleMetadata(scanID: scanB))
        }
        #expect(try await repository.scanState(scanB) == nil)
        #expect(try await repository.scanState(scanA)?.status == .completed)
        await repository.close()
    }

    // MARK: Vacuum mode

    @Test("A new database selects incremental auto-vacuum")
    func incrementalAutoVacuum() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let raw = try SQLiteDatabase.openReadOnly(path: database.path)
        let statement = try raw.prepare("PRAGMA auto_vacuum")
        #expect(try statement.step())
        // 2 == INCREMENTAL
        #expect(statement.columnInt64(0) == 2)
        statement.finalize()
        raw.close()
        await repository.close()
    }

    // MARK: Start gate

    @Test("Start gate boundary: below, equal and above")
    func startGateBoundaries() async throws {
        let gate = StorageSpacePolicy(startGateBytes: 1_000, runtimeGateBytes: 500)

        let below = try TempDatabase()
        let belowProvider = MutableCapacityProvider(bytes: 999)
        let belowRepo = try below.open(capacityProvider: belowProvider, spacePolicy: gate)
        await #expect(
            throws: SnapshotStoreError.insufficientStorage(requiredBytes: 1_000, availableBytes: 999)
        ) {
            try await belowRepo.begin(sampleMetadata(scanID: sampleScanID()))
        }
        await belowRepo.close()

        let equal = try TempDatabase()
        let equalProvider = MutableCapacityProvider(bytes: 1_000)
        let equalRepo = try equal.open(capacityProvider: equalProvider, spacePolicy: gate)
        try await equalRepo.begin(sampleMetadata(scanID: sampleScanID()))
        await equalRepo.close()

        let above = try TempDatabase()
        let aboveProvider = MutableCapacityProvider(bytes: 1_001)
        let aboveRepo = try above.open(capacityProvider: aboveProvider, spacePolicy: gate)
        try await aboveRepo.begin(sampleMetadata(scanID: sampleScanID()))
        await aboveRepo.close()
    }

    @Test("Unknown start capacity refuses to begin")
    func unknownStartCapacity() async throws {
        let database = try TempDatabase()
        let repository = try database.open(
            capacityProvider: MutableCapacityProvider(bytes: nil),
            spacePolicy: StorageSpacePolicy(startGateBytes: 1, runtimeGateBytes: 1)
        )
        await #expect(throws: SnapshotStoreError.storageCapacityUnavailable) {
            try await repository.begin(sampleMetadata(scanID: sampleScanID()))
        }
        await repository.close()
    }

    // MARK: Runtime gate

    @Test("Runtime gate boundary: below stops, equal and above proceed")
    func runtimeGateBoundaries() async throws {
        let gate = StorageSpacePolicy(startGateBytes: 1_000, runtimeGateBytes: 500)
        let provider = MutableCapacityProvider(bytes: 10_000)
        let database = try TempDatabase()
        let repository = try database.open(capacityProvider: provider, spacePolicy: gate)
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        try await writeMinimal(repository, scanID: scanID)
        #expect(try await repository.scanState(scanID)?.lastRevision == Revision(1))

        provider.set(499)
        await #expect(
            throws: SnapshotStoreError.insufficientStorage(requiredBytes: 500, availableBytes: 499)
        ) {
            try await writeMinimal(repository, scanID: scanID, revision: 2)
        }
        // No fake commit, the scan is still running, and fail() recovers.
        #expect(try await repository.scanState(scanID)?.lastRevision == Revision(1))
        #expect(try await repository.scanState(scanID)?.status == .running)

        provider.set(500)
        try await writeMinimal(repository, scanID: scanID, revision: 2)
        #expect(try await repository.scanState(scanID)?.lastRevision == Revision(2))

        provider.set(501)
        try await writeMinimal(repository, scanID: scanID, revision: 3)
        #expect(try await repository.scanState(scanID)?.lastRevision == Revision(3))
        await repository.close()
    }

    @Test("Unknown runtime capacity stops persistence without failing silently")
    func unknownRuntimeCapacity() async throws {
        let provider = MutableCapacityProvider(bytes: 10_000)
        let database = try TempDatabase()
        let repository = try database.open(
            capacityProvider: provider,
            spacePolicy: StorageSpacePolicy(startGateBytes: 1_000, runtimeGateBytes: 500)
        )
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        provider.set(nil)
        await #expect(throws: SnapshotStoreError.storageCapacityUnavailable) {
            try await writeMinimal(repository, scanID: scanID)
        }
        #expect(try await repository.scanState(scanID)?.status == .running)
        try await repository.fail(scanID: scanID)
        #expect(try await repository.scanState(scanID)?.status == .failed)
        await repository.close()
    }

    @Test("SQLITE_FULL and SQLITE_IOERR classify as storage exhaustion")
    func sqliteFullClassification() {
        #expect(
            SnapshotStoreError.sqlite(code: SQLITE_FULL, message: "disk full")
                .isStorageExhaustion
        )
        #expect(
            SnapshotStoreError.sqlite(code: SQLITE_IOERR, message: "io error")
                .isStorageExhaustion
        )
        #expect(
            !SnapshotStoreError.sqlite(code: SQLITE_CONSTRAINT, message: "constraint")
                .isStorageExhaustion
        )
        #expect(!SnapshotStoreError.storageCapacityUnavailable.isStorageExhaustion)
    }

    // MARK: Two-scan reuse

    @Test("Two same-size scans keep one scan and do not double the database")
    func twoScansReusePages() async throws {
        let database = try TempDatabase()
        let provider = MutableCapacityProvider(bytes: 100 * 1024 * 1024 * 1024)
        let repository = try database.open(capacityProvider: provider)
        let batchSize = 1_000
        let batchCount = 20

        func seed(_ scanID: ScanID) async throws {
            try await repository.begin(sampleMetadata(scanID: scanID))
            for batchIndex in 0..<batchCount {
                var names: [NameRecord] = []
                var nodes: [NodeRecord] = []
                if batchIndex == 0 {
                    names.append(sampleName(1, "root"))
                    nodes.append(
                        sampleNode(
                            id: 1, parent: nil, name: 1, scanID: scanID,
                            kind: .directory, logical: nil, allocated: nil, attributed: 0
                        )
                    )
                }
                for offset in 0..<batchSize {
                    let nameID = UInt64(batchIndex * batchSize + offset + 2)
                    names.append(sampleName(nameID, "n-\(nameID)"))
                    nodes.append(
                        sampleNode(
                            id: nameID, parent: 1, name: nameID, scanID: scanID
                        )
                    )
                }
                try await repository.write(
                    NodeBatch(
                        scanID: scanID,
                        revision: Revision(UInt64(batchIndex + 1)),
                        names: names,
                        nodes: nodes
                    )
                )
            }
            try await repository.finish(
                ScanSummary(
                    scanID: scanID, status: .completed,
                    startedAt: Date(timeIntervalSince1970: 1_000),
                    fileCount: UInt64(batchSize * batchCount),
                    directoryCount: 1, inaccessibleCount: 0,
                    issueCount: 0, rootAttributedBytes: 0
                )
            )
        }

        func mainBytes() -> Int64 {
            let attributes = try? FileManager.default.attributesOfItem(atPath: database.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }

        try await seed(sampleScanID(1))
        let firstBytes = mainBytes()
        try await seed(sampleScanID(2))
        let secondBytes = mainBytes()

        #expect(try rowCount("scans", keyColumn: "id", scanID: sampleScanID(2), path: database.path) == 1)
        #expect(try rowCount("scans", keyColumn: "id", scanID: sampleScanID(1), path: database.path) == 0)
        #expect(secondBytes > 0)
        #expect(secondBytes < firstBytes * 2, "expected page reuse, first=\(firstBytes) second=\(secondBytes)")
        print("phase5c two-scan main bytes: first=\(firstBytes) second=\(secondBytes)")
        await repository.close()
    }

    // MARK: Pure arithmetic

    @Test("Reusable and effective space saturate instead of wrapping")
    func spaceMathSaturation() {
        #expect(StorageSpaceMath.reusableBytes(pageSize: 4_096, freelistCount: 10) == 40_960)
        #expect(
            StorageSpaceMath.reusableBytes(pageSize: UInt64.max, freelistCount: 2)
                == UInt64.max
        )
        #expect(
            StorageSpaceMath.effectiveAvailable(volumeAvailable: UInt64.max - 1, reusableBytes: 10)
                == UInt64.max
        )
        #expect(
            StorageSpaceMath.decide(volumeAvailable: nil, reusableBytes: 1, requiredBytes: 1)
                == .unavailable
        )
        #expect(
            StorageSpaceMath.decide(volumeAvailable: 0, reusableBytes: 5, requiredBytes: 5)
                == .proceed(availableBytes: 5)
        )
        #expect(
            StorageSpaceMath.decide(volumeAvailable: 0, reusableBytes: 4, requiredBytes: 5)
                == .insufficient(requiredBytes: 5, availableBytes: 4)
        )
    }

    // MARK: Production capacity provider

    @Test("The production provider reports the same capacity as the Foundation facts resolver")
    func productionProviderMatchesFoundationFacts() {
        let directory = NSTemporaryDirectory()
        let provider = VolumeStorageCapacityProvider(directoryPath: directory)
        let providerValue = provider.availableForImportantUsageBytes()
        let foundation = FoundationVolumeFactsProvider().facts(forFileSystemPath: directory)
        #expect(providerValue != nil)
        // Both use the same resolution rules; the raw numbers can differ by a
        // few blocks because the two samples happen at slightly different
        // times, so compare with a small tolerance instead of exact equality.
        if let providerValue, let resolved = foundation.availableCapacityBytes {
            let difference = providerValue > resolved
                ? providerValue - resolved
                : resolved - providerValue
            #expect(difference < 64 * 1024 * 1024)
        }
    }

    @Test("A provider for a missing path stays unknown instead of borrowing an ancestor's capacity")
    func productionProviderMissingPath() {
        let provider = VolumeStorageCapacityProvider(
            directoryPath: "/spacejudge-nonexistent-\(UUID().uuidString)"
        )
        #expect(provider.availableForImportantUsageBytes() == nil)
    }

    @Test("The gate provider falls back to statfs when the Foundation lookup fails")
    func providerFallsBackWhenLookupThrows() {
        let provider = VolumeStorageCapacityProvider(
            directoryPath: "/existing",
            lookup: { _ in nil },
            probe: { _ in 3_000 }
        )
        #expect(provider.availableForImportantUsageBytes() == 3_000)
    }

    @Test("The gate provider rejects important > total like the resolver")
    func providerRejectsImpossibleImportant() {
        let provider = VolumeStorageCapacityProvider(
            directoryPath: "/existing",
            lookup: { _ in RawVolumeValues(total: 100, important: 500, standard: 500) },
            probe: { _ in nil }
        )
        #expect(provider.availableForImportantUsageBytes() == nil)
    }

    @Test("The gate provider keeps all-zero as a confirmed zero")
    func providerAllZero() {
        let provider = VolumeStorageCapacityProvider(
            directoryPath: "/existing",
            lookup: { _ in RawVolumeValues(total: 100, important: 0, standard: 0) },
            probe: { _ in 0 }
        )
        #expect(provider.availableForImportantUsageBytes() == 0)
    }

    @Test("The gate provider uses the probe for an anomalous zero important value")
    func providerZeroImportantUsesProbe() {
        let provider = VolumeStorageCapacityProvider(
            directoryPath: "/existing",
            lookup: { _ in RawVolumeValues(total: 1_000, important: 0, standard: nil) },
            probe: { _ in 512 }
        )
        #expect(provider.availableForImportantUsageBytes() == 512)
    }
}
