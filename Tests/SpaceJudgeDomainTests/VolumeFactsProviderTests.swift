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
}
