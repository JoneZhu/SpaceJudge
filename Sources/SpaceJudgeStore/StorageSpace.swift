import Foundation
import SpaceJudgeDomain

/// Product protection thresholds for the snapshot cache.
///
/// These are not predictions of scan size; they only stop SpaceJudge from
/// filling the user's disk with a rebuildable cache. `startGateBytes` is checked
/// before a scan header is written, `runtimeGateBytes` before every batch
/// commit.
public struct StorageSpacePolicy: Sendable, Equatable {
    /// Minimum effective free space required to begin a scan.
    public var startGateBytes: UInt64
    /// Minimum effective free space required to keep persisting a running scan.
    public var runtimeGateBytes: UInt64

    public init(
        startGateBytes: UInt64 = 512 * 1024 * 1024,
        runtimeGateBytes: UInt64 = 256 * 1024 * 1024
    ) {
        self.startGateBytes = startGateBytes
        self.runtimeGateBytes = runtimeGateBytes
    }

    /// The default 512 MiB / 256 MiB product gates.
    public static let standard = StorageSpacePolicy()
}

/// Supplies the cache volume's available-for-important-usage bytes.
///
/// Injectable so low-space behavior is testable without touching a real
/// machine. `nil` means the fact could not be established; it must never be
/// coerced to zero.
public protocol StorageCapacityProviding: Sendable {
    func availableForImportantUsageBytes() -> UInt64?
}

/// Production provider backed only by the public Foundation volume key for the
/// directory that holds the database.
///
/// The runtime gate asks for the fact before every committed batch, but the
/// Foundation volume query is comparatively allocation-heavy. A short
/// monotonic-clock TTL keeps the number of queries bounded during a long scan
/// while still reacting to a shrinking volume within a couple of seconds. The
/// cache is only in this production provider; injected test providers stay
/// immediate and uncached.
public final class VolumeStorageCapacityProvider: StorageCapacityProviding, @unchecked Sendable {
    private let directoryPath: String
    private let ttlSeconds: Double
    private let lock = NSLock()
    private var cached: (value: UInt64?, at: ContinuousClock.Instant)?

    public init(directoryPath: String, ttlSeconds: Double = 2) {
        self.directoryPath = directoryPath
        self.ttlSeconds = max(0, ttlSeconds)
    }

    public func availableForImportantUsageBytes() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        if let cached, ttlSeconds > 0 {
            let elapsed = cached.at.duration(to: now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            if seconds < ttlSeconds {
                return cached.value
            }
        }
        let value = read()
        cached = (value, now)
        return value
    }

    private func read() -> UInt64? {
        let url = URL(fileURLWithPath: directoryPath, isDirectory: true)
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else {
            return nil
        }
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return available >= 0 ? UInt64(available) : nil
    }
}

/// Fixed provider used by tests and non-production callers.
public struct FixedStorageCapacityProvider: StorageCapacityProviding {
    private let value: UInt64?

    public init(bytes: UInt64?) {
        self.value = bytes
    }

    public func availableForImportantUsageBytes() -> UInt64? { value }
}

/// Pure space arithmetic with explicit overflow handling.
public enum StorageSpaceMath {
    /// `pageSize × freelistCount`, saturating to `UInt64.max` on overflow.
    public static func reusableBytes(pageSize: UInt64, freelistCount: UInt64) -> UInt64 {
        let (product, overflow) = pageSize.multipliedReportingOverflow(by: freelistCount)
        return overflow ? UInt64.max : product
    }

    /// `volumeAvailable + reusableBytes`, saturating to `UInt64.max` on
    /// overflow. WAL/SHM live on the same volume and are already reflected in
    /// the volume number, so they are not subtracted again.
    public static func effectiveAvailable(
        volumeAvailable: UInt64,
        reusableBytes: UInt64
    ) -> UInt64 {
        let (sum, overflow) = volumeAvailable.addingReportingOverflow(reusableBytes)
        return overflow ? UInt64.max : sum
    }

    /// The outcome of a gate check.
    public enum Decision: Sendable, Equatable {
        case proceed(availableBytes: UInt64)
        case insufficient(requiredBytes: UInt64, availableBytes: UInt64)
        case unavailable
    }

    /// Evaluates one gate. Unknown capacity is `.unavailable`, never zero.
    public static func decide(
        volumeAvailable: UInt64?,
        reusableBytes: UInt64,
        requiredBytes: UInt64
    ) -> Decision {
        guard let volumeAvailable else { return .unavailable }
        let effective = effectiveAvailable(
            volumeAvailable: volumeAvailable,
            reusableBytes: reusableBytes
        )
        if effective >= requiredBytes {
            return .proceed(availableBytes: effective)
        }
        return .insufficient(requiredBytes: requiredBytes, availableBytes: effective)
    }
}
