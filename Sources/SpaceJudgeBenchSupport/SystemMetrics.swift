import Darwin
import Foundation

/// Injectable OS measurements so failure branches can be tested without faking
/// values in the JSON. Providers must return `nil` when the OS API fails; they
/// never substitute a fabricated `0`.
public struct SystemMetrics: Sendable {
    /// Peak resident set size in bytes, or `nil` when unavailable.
    public var peakResidentBytes: @Sendable () -> Int64?
    /// Number of currently open file descriptors, or `nil` when unavailable.
    public var openFileDescriptorCount: @Sendable () -> Int?

    public init(
        peakResidentBytes: @escaping @Sendable () -> Int64?,
        openFileDescriptorCount: @escaping @Sendable () -> Int?
    ) {
        self.peakResidentBytes = peakResidentBytes
        self.openFileDescriptorCount = openFileDescriptorCount
    }

    /// Provider backed by the real process.
    ///
    /// `ru_maxrss` is documented in bytes on Darwin/macOS (Linux uses KiB);
    /// we keep the Darwin value and never rescale it. Open descriptors are read
    /// from `/dev/fd`, a bounded public interface — the benchmark never walks
    /// toward the system maximum.
    public static let live = SystemMetrics(
        peakResidentBytes: {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
            let bytes = Int64(usage.ru_maxrss)
            return bytes > 0 ? bytes : nil
        },
        openFileDescriptorCount: {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else {
                return nil
            }
            return entries.count
        }
    )
}
