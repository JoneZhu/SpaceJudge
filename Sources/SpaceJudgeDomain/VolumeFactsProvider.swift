import Foundation

/// Collects volume capacity facts for the file system that contains a path.
///
/// The protocol is intentionally non-throwing: capacity metering is advisory
/// and must never turn a successful root open into a fatal scan error. An
/// implementation returns `capacitySource == .unavailable` (and `nil` values)
/// when the platform cannot confirm a number; it must never fabricate `0`.
public protocol VolumeFactsProviding: Sendable {
    func facts(forFileSystemPath path: String) -> VolumeFacts
}

/// Pure, overflow-safe resolution of the raw Foundation capacity values.
///
/// Split out from the URL lookup so negative, missing and inconsistent inputs
/// can be unit tested without touching a real volume.
public enum VolumeCapacityResolver {
    /// Resolves capacity facts in the documented order:
    ///
    /// 1. `total`
    /// 2. important-usage availability
    /// 3. standard availability fallback
    ///
    /// Negative values are treated as unknown. `available > total` keeps the
    /// confirmed total but degrades availability and source to unknown.
    public static func facts(
        total: Int?,
        availableForImportantUsage: Int64?,
        standardAvailable: Int?
    ) -> VolumeFacts {
        let totalBytes = unsigned(total)
        let importantBytes = unsigned(availableForImportantUsage)
        let standardBytes = unsigned(standardAvailable)

        let available: UInt64?
        let source: CapacitySource
        if let importantBytes {
            available = importantBytes
            source = .importantUsage
        } else if let standardBytes {
            available = standardBytes
            source = .standardAvailable
        } else {
            available = nil
            source = .unavailable
        }

        if let totalBytes, let available, available > totalBytes {
            return VolumeFacts(
                totalCapacityBytes: totalBytes,
                availableCapacityBytes: nil,
                capacitySource: .unavailable
            )
        }

        return VolumeFacts(
            totalCapacityBytes: totalBytes,
            availableCapacityBytes: available,
            capacitySource: source
        )
    }

    /// Converts a signed 32-bit capacity to `UInt64`, rejecting negatives.
    public static func unsigned(_ value: Int?) -> UInt64? {
        guard let value, value >= 0 else { return nil }
        return UInt64(value)
    }

    /// Converts a signed 64-bit capacity to `UInt64`, rejecting negatives.
    public static func unsigned(_ value: Int64?) -> UInt64? {
        guard let value, value >= 0 else { return nil }
        return UInt64(value)
    }
}

/// Foundation-backed capacity metering used by the real app and engine.
///
/// See `VolumeCapacityResolver.facts(total:availableForImportantUsage:standardAvailable:)`
/// for the fallback and consistency rules.
public struct FoundationVolumeFactsProvider: VolumeFactsProviding {
    public init() {}

    public func facts(forFileSystemPath path: String) -> VolumeFacts {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return VolumeFacts(
                totalCapacityBytes: nil,
                availableCapacityBytes: nil,
                capacitySource: .unavailable
            )
        }
        return VolumeCapacityResolver.facts(
            total: values.volumeTotalCapacity,
            availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage,
            standardAvailable: values.volumeAvailableCapacity
        )
    }
}
