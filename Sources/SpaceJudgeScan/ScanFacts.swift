import Foundation
import SpaceJudgeDomain

/// Pure, testable counting helpers. Every increment uses reporting overflow so
/// a real scan never traps and never silently saturates.
enum ScanCounter {
    static func increment(_ value: UInt64, by amount: UInt64 = 1) throws -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(amount)
        guard !overflow else {
            throw ScanError.counterOverflow(context: "increment")
        }
        return sum
    }

    static func sum(_ values: [UInt64]) throws -> UInt64 {
        var total: UInt64 = 0
        for value in values {
            total = try increment(total, by: value)
        }
        return total
    }
}

/// Pure block-count to byte conversion used by `ReferenceEnumerator`.
enum ReferenceSizing {
    /// Converts `st_blocks` (512-byte units) to bytes.
    ///
    /// Returns `nil` for a negative block count or a value that cannot be
    /// represented as `UInt64`, so the caller can report unknown allocation
    /// instead of wrapping or trapping.
    static func allocatedBytes(fromBlockCount blocks: Int64) -> UInt64? {
        guard blocks >= 0 else { return nil }
        let (bytes, overflow) = UInt64(blocks).multipliedReportingOverflow(by: 512)
        guard !overflow else { return nil }
        return bytes
    }
}

/// Pure hard-link / attribution resolution.
///
/// `candidate` is the amount that would be attributed before the duplicate
/// policy is applied. `allocated == nil` is a legitimate incomplete fact, not
/// corruption: it resolves to `.unknown` and must not be reported as an error.
/// A candidate larger than a *known* allocation is `.invalid`.
enum FileAttribution {
    enum Resolution: Equatable, Sendable {
        /// Allocation is known and the candidate is representable.
        case known(attributedBytes: UInt64)
        /// Allocation is unknown (returned bitmap gap or unrepresentable block
        /// count). The fact may be published with `allocated = nil` and
        /// `attributed = 0`; it must not claim a hard-link identity.
        case unknown
        /// Allocation is known but the candidate exceeds it. This is a
        /// damaged fact: report an issue and do not publish or aggregate it.
        case invalid
    }

    static func resolve(
        candidate: UInt64,
        allocated: UInt64?,
        duplicate: Bool
    ) -> Resolution {
        guard let allocated else {
            return .unknown
        }
        guard candidate <= allocated else {
            return .invalid
        }
        return .known(attributedBytes: duplicate ? 0 : candidate)
    }
}

/// Scanner-local revision counter. The scanner must not use the wrapping
/// `Revision.next`; an exhausted revision space is an explicit error.
enum ScanRevisionCounter {
    static func next(_ current: Revision) throws -> Revision {
        Revision(try ScanCounter.increment(current.rawValue, by: 1))
    }
}
