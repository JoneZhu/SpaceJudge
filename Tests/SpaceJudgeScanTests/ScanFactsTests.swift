import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

@Suite("Scan fact helpers")
struct ScanFactsTests {
    @Test("Counter increment reports overflow instead of trapping")
    func counterOverflow() throws {
        #expect(try ScanCounter.increment(0) == 1)
        #expect(try ScanCounter.increment(UInt64.max - 1) == UInt64.max)
        #expect(throws: ScanError.counterOverflow(context: "increment")) {
            _ = try ScanCounter.increment(UInt64.max, by: 1)
        }
        #expect(try ScanCounter.sum([1, 2, 3]) == 6)
        #expect(throws: ScanError.self) {
            _ = try ScanCounter.sum([UInt64.max, 1])
        }
    }

    @Test("Block count conversion rejects negatives and overflow")
    func blockConversion() {
        #expect(ReferenceSizing.allocatedBytes(fromBlockCount: -1) == nil)
        #expect(ReferenceSizing.allocatedBytes(fromBlockCount: 0) == 0)
        #expect(ReferenceSizing.allocatedBytes(fromBlockCount: 1) == 512)
        #expect(ReferenceSizing.allocatedBytes(fromBlockCount: 8) == 4096)
        #expect(ReferenceSizing.allocatedBytes(fromBlockCount: Int64.max) == nil)
    }

    @Test("Attribution distinguishes known, unknown and invalid")
    func attributionResolution() {
        #expect(
            FileAttribution.resolve(candidate: 50, allocated: 50, duplicate: false)
                == .known(attributedBytes: 50)
        )
        #expect(
            FileAttribution.resolve(candidate: 50, allocated: 50, duplicate: true)
                == .known(attributedBytes: 0)
        )
        // Unknown allocation is a legitimate incomplete fact, not corruption.
        #expect(
            FileAttribution.resolve(candidate: 0, allocated: nil, duplicate: false)
                == .unknown
        )
        #expect(
            FileAttribution.resolve(candidate: 0, allocated: nil, duplicate: true)
                == .unknown
        )
        // Known allocation smaller than the candidate is genuinely invalid.
        #expect(
            FileAttribution.resolve(candidate: 100, allocated: 50, duplicate: false)
                == .invalid
        )
    }

    @Test("Revision counter reports overflow instead of wrapping")
    func revisionCounter() throws {
        #expect(try ScanRevisionCounter.next(Revision(0)) == Revision(1))
        #expect(throws: ScanError.counterOverflow(context: "increment")) {
            _ = try ScanRevisionCounter.next(Revision(UInt64.max))
        }
    }

    @Test("Spool arithmetic rejects Int overflow")
    func spoolArithmetic() throws {
        #expect(try SpoolArithmetic.advanced(0, by: 4) == 4)
        #expect(try SpoolArithmetic.incremented(0) == 1)
        #expect(throws: ScanError.self) {
            _ = try SpoolArithmetic.incremented(Int.max)
        }
        #expect(throws: ScanError.self) {
            _ = try SpoolArithmetic.advanced(Int.max, by: 1)
        }
        #expect(throws: ScanError.self) {
            _ = try SpoolArithmetic.advanced(0, by: -1)
        }
    }

    @Test("Name interner reuses identifiers and never wraps")
    func nameInterner() throws {
        var interner = NameInterner()
        let first = try interner.intern([0x61])
        let second = try interner.intern([0x62])
        let repeated = try interner.intern([0x61])
        #expect(first.isNew)
        #expect(second.isNew)
        #expect(!repeated.isNew)
        #expect(first.id == repeated.id)
        #expect(first.id != second.id)
        #expect(interner.count == 2)
    }
}
