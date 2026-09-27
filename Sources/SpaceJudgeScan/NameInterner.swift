import Foundation
import SpaceJudgeDomain

/// Reuses one `NameID` per distinct byte name within a single scan.
///
/// The interner only assigns identifiers; the caller is responsible for
/// emitting the matching `NameRecord` no later than the first node that
/// references it. Identifier allocation uses reporting overflow so an
/// exhausted identifier space is a fatal, explicit error rather than a trap.
public struct NameInterner: Sendable {
    private var identifiers: [[UInt8]: NameID] = [:]
    private var nextRawValue: UInt64 = 0

    public init() {}

    /// Returns the identifier for `bytes`, together with `true` when the name
    /// was newly interned and therefore needs a `NameRecord` in this batch.
    public mutating func intern(_ bytes: [UInt8]) throws -> (id: NameID, isNew: Bool) {
        if let existing = identifiers[bytes] {
            return (existing, false)
        }
        let rawValue = try ScanCounter.increment(nextRawValue, by: 1)
        nextRawValue = rawValue
        let id = NameID(rawValue)
        identifiers[bytes] = id
        return (id, true)
    }

    public func identifier(for bytes: [UInt8]) -> NameID? {
        identifiers[bytes]
    }

    public var count: Int { identifiers.count }
}
