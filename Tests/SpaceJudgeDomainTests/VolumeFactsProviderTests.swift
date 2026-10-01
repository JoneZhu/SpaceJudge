import Foundation
import Testing
import SpaceJudgeDomain

@Suite("Volume capacity resolution")
struct VolumeFactsProviderTests {
    @Test("Important-usage availability wins when present")
    func importantUsageWins() {
        let facts = VolumeCapacityResolver.facts(
            total: 1000,
            availableForImportantUsage: 250,
            standardAvailable: 900
        )
        #expect(facts.totalCapacityBytes == 1000)
        #expect(facts.availableCapacityBytes == 250)
        #expect(facts.capacitySource == .importantUsage)
        #expect(facts.usedBytes == 750)
    }

    @Test("Standard availability is the fallback")
    func standardFallback() {
        let facts = VolumeCapacityResolver.facts(
            total: 1000,
            availableForImportantUsage: nil,
            standardAvailable: 900
        )
        #expect(facts.totalCapacityBytes == 1000)
        #expect(facts.availableCapacityBytes == 900)
        #expect(facts.capacitySource == .standardAvailable)
    }

    @Test("Negative important value falls back instead of trapping")
    func negativeImportantFallsBack() {
        let facts = VolumeCapacityResolver.facts(
            total: 2048,
            availableForImportantUsage: -1,
            standardAvailable: 1024
        )
        #expect(facts.availableCapacityBytes == 1024)
        #expect(facts.capacitySource == .standardAvailable)
    }

    @Test("All-negative input resolves to unknown without a fabricated zero")
    func allNegativeIsUnknown() {
        let facts = VolumeCapacityResolver.facts(
            total: -5,
            availableForImportantUsage: -1,
            standardAvailable: -1
        )
        #expect(facts.totalCapacityBytes == nil)
        #expect(facts.availableCapacityBytes == nil)
        #expect(facts.capacitySource == .unavailable)
        #expect(facts.usedBytes == nil)
    }

    @Test("available > total keeps total and degrades source")
    func inconsistentValues() {
        let facts = VolumeCapacityResolver.facts(
            total: 100,
            availableForImportantUsage: 500,
            standardAvailable: 500
        )
        #expect(facts.totalCapacityBytes == 100)
        #expect(facts.availableCapacityBytes == nil)
        #expect(facts.capacitySource == .unavailable)
        #expect(facts.usedBytes == nil)
    }

    @Test("UInt64 boundary values survive the conversion")
    func boundaryValues() {
        let facts = VolumeCapacityResolver.facts(
            total: Int.max,
            availableForImportantUsage: Int64.max,
            standardAvailable: nil
        )
        #expect(facts.totalCapacityBytes == UInt64(Int.max))
        #expect(facts.availableCapacityBytes == UInt64(Int64.max))
        #expect(facts.capacitySource == .importantUsage)
    }

    @Test("Foundation provider reports unknown for a missing path")
    func foundationMissingPath() {
        let provider = FoundationVolumeFactsProvider()
        let facts = provider.facts(
            forFileSystemPath: "/spacejudge-nonexistent-\(UUID().uuidString)"
        )
        #expect(facts.totalCapacityBytes == nil)
        #expect(facts.availableCapacityBytes == nil)
        #expect(facts.capacitySource == .unavailable)
    }

    @Test("Foundation provider meters a real directory")
    func foundationRealPath() {
        let provider = FoundationVolumeFactsProvider()
        let facts = provider.facts(forFileSystemPath: NSTemporaryDirectory())
        // The temp directory of a running Mac always lives on a local volume.
        #expect(facts.totalCapacityBytes != nil)
        #expect(facts.availableCapacityBytes != nil)
        #expect(facts.capacitySource != .unavailable)
    }

    @Test("A contradictory zero important value falls back to a positive standard value")
    func zeroImportantFallsBackToStandard() {
        // The shared-APFS-container misreport: important=0 while standard is
        // large must never be read as a full disk.
        let facts = VolumeCapacityResolver.facts(
            total: 64_000,
            availableForImportantUsage: 0,
            standardAvailable: 57_000
        )
        #expect(facts.totalCapacityBytes == 64_000)
        #expect(facts.availableCapacityBytes == 57_000)
        #expect(facts.capacitySource == .standardAvailable)
        #expect(facts.usedBytes == 7_000)
    }

    @Test("A zero important value with no standard value falls back to statfs evidence")
    func zeroImportantFallsBackToStatFS() {
        let facts = VolumeCapacityResolver.facts(
            total: 64_000,
            availableForImportantUsage: 0,
            standardAvailable: nil,
            fileSystemAvailable: 40_000
        )
        #expect(facts.availableCapacityBytes == 40_000)
        #expect(facts.capacitySource == .standardAvailable)
    }

    @Test("A positive statfs sample rescues an anomalous zero standard value")
    func zeroStandardUsesStatFS() {
        let facts = VolumeCapacityResolver.facts(
            total: 100,
            availableForImportantUsage: nil,
            standardAvailable: 0,
            fileSystemAvailable: 90
        )
        #expect(facts.availableCapacityBytes == 90)
        #expect(facts.capacitySource == .standardAvailable)
    }

    @Test("All sources reporting zero stays a confirmed zero")
    func allZeroStaysZero() {
        let facts = VolumeCapacityResolver.facts(
            total: 100,
            availableForImportantUsage: 0,
            standardAvailable: 0,
            fileSystemAvailable: 0
        )
        #expect(facts.totalCapacityBytes == 100)
        #expect(facts.availableCapacityBytes == 0)
        #expect(facts.capacitySource == .importantUsage)
        #expect(facts.usedBytes == 100)
    }

    @Test("A positive important value still wins even when standard is larger")
    func positiveImportantWinsOverStandard() {
        let facts = VolumeCapacityResolver.facts(
            total: 100,
            availableForImportantUsage: 10,
            standardAvailable: 90
        )
        #expect(facts.availableCapacityBytes == 10)
        #expect(facts.capacitySource == .importantUsage)
    }

    @Test("A negative statfs multiply is rejected as unknown")
    func overflowAndZeroBlockSize() {
        #expect(VolumeCapacityResolver.availableBytes(blockSize: 0, availableBlocks: 100) == nil)
        #expect(
            VolumeCapacityResolver.availableBytes(
                blockSize: 4096,
                availableBlocks: UInt64.max
            ) == nil
        )
        #expect(VolumeCapacityResolver.availableBytes(blockSize: 4096, availableBlocks: 2) == 8192)
    }

    @Test("The statfs probe is unknown for a missing path and known for a real one")
    func probePaths() {
        #expect(
            FileSystemCapacityProbe.availableBytes(
                forFileSystemPath: "/spacejudge-nonexistent-\(UUID().uuidString)"
            ) == nil
        )
        #expect(FileSystemCapacityProbe.availableBytes(forFileSystemPath: NSTemporaryDirectory()) != nil)
    }

    // MARK: Injected production provider (Foundation throw + probe)

    @Test("A thrown Foundation lookup still falls back to the exact-path statfs probe")
    func providerFallsBackWhenLookupThrows() {
        let provider = FoundationVolumeFactsProvider(
            lookup: { _ in nil },
            probe: { path in path == "/existing" ? 4_096 : nil }
        )
        let facts = provider.facts(forFileSystemPath: "/existing")
        #expect(facts.availableCapacityBytes == 4_096)
        #expect(facts.capacitySource == .standardAvailable)
    }

    @Test("A missing path stays unknown even when the lookup fails")
    func providerMissingPathNeverBorrowsAncestor() {
        let provider = FoundationVolumeFactsProvider(
            lookup: { _ in nil },
            probe: { _ in nil }
        )
        let facts = provider.facts(forFileSystemPath: "/missing/child")
        #expect(facts.totalCapacityBytes == nil)
        #expect(facts.availableCapacityBytes == nil)
        #expect(facts.capacitySource == .unavailable)
    }

    @Test("important > total is rejected by the production provider")
    func providerRejectsImpossibleImportant() {
        let provider = FoundationVolumeFactsProvider(
            lookup: { _ in RawVolumeValues(total: 100, important: 500, standard: 500) },
            probe: { _ in nil }
        )
        let facts = provider.facts(forFileSystemPath: "/existing")
        #expect(facts.availableCapacityBytes == nil)
        #expect(facts.capacitySource == .unavailable)
    }

    @Test("An anomalous zero important value uses the probe in the production provider")
    func providerZeroImportantUsesProbe() {
        let provider = FoundationVolumeFactsProvider(
            lookup: { _ in RawVolumeValues(total: 1_000, important: 0, standard: nil) },
            probe: { _ in 700 }
        )
        let facts = provider.facts(forFileSystemPath: "/existing")
        #expect(facts.availableCapacityBytes == 700)
        #expect(facts.capacitySource == .standardAvailable)
    }

    @Test("All-zero production inputs stay a confirmed zero")
    func providerAllZero() {
        let provider = FoundationVolumeFactsProvider(
            lookup: { _ in RawVolumeValues(total: 100, important: 0, standard: 0) },
            probe: { _ in 0 }
        )
        let facts = provider.facts(forFileSystemPath: "/existing")
        #expect(facts.availableCapacityBytes == 0)
        #expect(facts.capacitySource == .importantUsage)
    }
}
