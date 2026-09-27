import Foundation
import SpaceJudgeDomain

/// Compact, locale-aware byte formatting for the status line.
///
/// Unknown values always render as an em dash. A genuine zero renders as
/// `0 B`; the two must never be confused in the UI.
public enum ByteFormatting {
    private static func makeFormatter() -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB, .usePB]
        formatter.isAdaptive = true
        formatter.includesUnit = true
        return formatter
    }

    /// Formats an optional byte count; `nil` becomes an em dash.
    public static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return bytes(value)
    }

    /// Formats a non-optional byte count.
    ///
    /// A genuine zero is always rendered as the stable `0 B` (never a localized
    /// English `Zero KB`). Unknown is handled by the optional overload.
    public static func bytes(_ value: UInt64) -> String {
        if value == 0 { return "0 B" }
        return makeFormatter().string(fromByteCount: Int64(clamping: value))
    }

    /// One-line capacity summary: `总容量 … · 已用 … · 剩余 …`.
    ///
    /// Used is only shown when `total >= available`; otherwise it is unknown.
    /// Any missing value stays an em dash and is never shown as `0 B`.
    public static func capacityLine(_ volume: VolumeFacts?) -> String {
        guard let volume else {
            return "总容量 — · 已用 — · 剩余 —"
        }
        return "总容量 \(bytes(volume.totalCapacityBytes))"
            + " · 已用 \(bytes(volume.usedBytes))"
            + " · 剩余 \(bytes(volume.availableCapacityBytes))"
    }

    /// Renders a per-second rate such as `24.1万项/秒` using compact units.
    public static func rate(_ entriesPerSecond: Double) -> String {
        guard entriesPerSecond.isFinite, entriesPerSecond >= 0 else { return "—" }
        if entriesPerSecond >= 100_000 {
            return String(format: "%.1f万项/秒", entriesPerSecond / 10_000)
        }
        return String(format: "%.0f项/秒", entriesPerSecond)
    }

    /// Counting line shown while scanning: files, directories and rate.
    public static func progressLine(_ progress: ScanProgress?) -> String {
        guard let progress else { return "—" }
        return "\(progress.fileCount) 文件 · \(progress.directoryCount) 目录"
            + " · \(rate(progress.entriesPerSecond))"
    }
}
