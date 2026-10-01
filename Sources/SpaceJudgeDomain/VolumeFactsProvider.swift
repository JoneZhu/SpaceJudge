import Darwin
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
    /// 1. a *positive* important-usage availability (kept even when it is
    ///    smaller than the standard number, so the existing semantics do not
    ///    change);
    /// 2. standard availability, including a Darwin `statfs` sample supplied
    ///    through `fileSystemAvailable`;
    /// 3. confirmed zero only when every source that answered agreed on zero.
    ///
    /// `fileSystemAvailable` is an optional extra fact: production callers pass
    /// `f_bavail * f_bsize` sampled from `statfs`, which is used when the
    /// Foundation values are missing, negative or inconsistently zero. The
    /// default keeps the original three-argument call source-compatible.
    ///
    /// A zero important-usage value is the classic APFS-shared-container
    /// misreport: when another source has a positive number it must not be
    /// treated as a full disk. When every source answers zero, the zero is real
    /// and preserved. Negative values are treated as unknown. `available >
    /// total` keeps the confirmed total but degrades availability and source to
    /// unknown.
    public static func facts(
        total: Int?,
        availableForImportantUsage: Int64?,
        standardAvailable: Int?,
        fileSystemAvailable: UInt64? = nil
    ) -> VolumeFacts {
        let totalBytes = unsigned(total)
        let importantBytes = unsigned(availableForImportantUsage)
        let standardBytes = standardEvidence(
            standard: unsigned(standardAvailable),
            fileSystem: unsigned(fileSystemAvailable)
        )

        let available: UInt64?
        let source: CapacitySource
        if let importantBytes, importantBytes > 0 {
            available = importantBytes
            source = .importantUsage
        } else if let standardBytes, standardBytes > 0 {
            available = standardBytes
            source = .standardAvailable
        } else if let importantBytes {
            // Important usage answered with a confirmed zero and no other
            // source contradicts it: keep the zero so a genuinely low volume
            // still trips the storage gate.
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

    /// Picks the standard-availability evidence that must not hide free space.
    ///
    /// A positive Foundation number always wins. When it is missing, negative
    /// or an anomalous zero, a positive Darwin `statfs` sample is used instead.
    /// Only when no source is positive does a reported zero count as confirmed
    /// (and `nil` when nobody answered).
    static func standardEvidence(standard: UInt64?, fileSystem: UInt64?) -> UInt64? {
        if let standard, standard > 0 { return standard }
        if let fileSystem, fileSystem > 0 { return fileSystem }
        if let standard { return standard }
        if let fileSystem { return fileSystem }
        return nil
    }

    /// Overflow-safe `availableBlocks * blockSize` used for the Darwin
    /// `statfs` fallback. A zero or overflowing multiply is unknown, never a
    /// fabricated zero or a wrapped value.
    public static func availableBytes(
        blockSize: UInt32,
        availableBlocks: UInt64
    ) -> UInt64? {
        guard blockSize > 0 else { return nil }
        let (product, overflow) = availableBlocks.multipliedReportingOverflow(by: UInt64(blockSize))
        return overflow ? nil : product
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

    /// Passes an unsigned capacity through unchanged.
    public static func unsigned(_ value: UInt64?) -> UInt64? { value }
}

/// Raw, unresolved capacity inputs read from one path.
///
/// Kept separate from the resolver so production providers can be tested with
/// injected lookups that throw, return zeros or disagree.
public struct RawVolumeValues: Sendable, Equatable {
    public let total: Int?
    public let important: Int64?
    public let standard: Int?

    public init(total: Int?, important: Int64?, standard: Int?) {
        self.total = total
        self.important = important
        self.standard = standard
    }
}

/// Foundation-backed capacity metering used by the real app and engine.
///
/// See `VolumeCapacityResolver.facts(total:availableForImportantUsage:standardAvailable:fileSystemAvailable:)`
/// for the fallback and consistency rules. The Foundation lookup and the Darwin
/// probe are injectable so the fallback can be tested when Foundation throws.
public struct FoundationVolumeFactsProvider: VolumeFactsProviding {
    public typealias RawLookup = @Sendable (String) -> RawVolumeValues?
    public typealias Probe = @Sendable (String) -> UInt64?

    private let lookup: RawLookup
    private let probe: Probe

    public init() {
        self.init(lookup: Self.foundationLookup, probe: FileSystemCapacityProbe.availableBytes)
    }

    public init(lookup: @escaping RawLookup, probe: @escaping Probe) {
        self.lookup = lookup
        self.probe = probe
    }

    public func facts(forFileSystemPath path: String) -> VolumeFacts {
        let values = lookup(path)
        // Always sample the exact path with Darwin `statfs`, even when the
        // Foundation lookup fails: a real directory must still get a fallback,
        // while a missing path fails the probe and stays unknown. No ancestor
        // capacity is ever inferred.
        let fileSystemAvailable = probe(path)
        return VolumeCapacityResolver.facts(
            total: values?.total,
            availableForImportantUsage: values?.important,
            standardAvailable: values?.standard,
            fileSystemAvailable: fileSystemAvailable
        )
    }

    /// Production Foundation lookup.
    public static func foundationLookup(_ path: String) -> RawVolumeValues? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return RawVolumeValues(
            total: values.volumeTotalCapacity,
            important: values.volumeAvailableCapacityForImportantUsage,
            standard: values.volumeAvailableCapacity
        )
    }
}

/// Darwin `statfs` capacity evidence.
///
/// Used only as a fallback and cross-check for the Foundation volume keys. It
/// is a *filesystem-available* number: it is never presented as exclusive or
/// reclaimable space and never equalized with a shared APFS container's total.
public enum FileSystemCapacityProbe {
    /// Samples `fstatfs` for the directory at `path` and returns
    /// `f_bavail * f_bsize` with overflow safety. Returns `nil` when the path
    /// cannot be opened, the syscall fails, the block size is zero, or the
    /// multiply would overflow. The descriptor is always closed.
    public static func availableBytes(forFileSystemPath path: String) -> UInt64? {
        let descriptor = path.withCString { pointer in
            open(pointer, O_RDONLY | O_DIRECTORY)
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0 else { return nil }
        return VolumeCapacityResolver.availableBytes(
            blockSize: info.f_bsize,
            availableBlocks: info.f_bavail
        )
    }
}
