import Foundation
import SpaceJudgeDomain

/// Deterministic JSON encoding shared by every agent CLI command.
///
/// All 64-bit domain values are emitted as decimal strings so a JavaScript
/// consumer cannot lose precision above `2^53`. Unknown values are `null`,
/// never a fabricated zero. Times are UTC ISO-8601. Keys are sorted so the
/// same facts produce byte-identical lines.
public enum AgentJSON {
    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    /// Encodes one JSON object without a trailing newline.
    public static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            // Encoding a dictionary of JSON-safe values cannot fail; this is a
            // defensive fallback that stays valid JSON and path-free.
            return #"{"type":"error","code":"INTERNAL","message":"An internal error occurred."}"#
        }
        return text
    }

    /// A `UInt64` as a decimal string.
    public static func uint64(_ value: UInt64) -> String {
        String(value)
    }

    /// An optional `UInt64` as a decimal string or `null`.
    public static func uint64OrNull(_ value: UInt64?) -> Any {
        guard let value else { return NSNull() }
        return String(value)
    }

    /// A `UInt64` revision as a decimal string.
    public static func revision(_ value: Revision) -> String {
        String(value.rawValue)
    }

    /// Bytes in one SI gigabyte. The contract is decimal SI, never `GiB`.
    public static let bytesPerGigabyte: UInt64 = 1_000_000_000

    /// Formats an exact byte count as a fixed two-decimal SI GB string.
    ///
    /// The rounding is half-up to the nearest `0.01 GB` and is computed with
    /// pure integer arithmetic, so it is locale-independent, never overflows
    /// and always yields ASCII digits plus one `.`. `UInt64.max` stays a plain
    /// decimal string.
    public static func gigabytes(_ bytes: UInt64) -> String {
        // `hundredths = round(bytes / 10_000_000)` without overflow: divide
        // first, then bump the quotient when the remainder is at least half.
        let (unitsOfTenMillion, remainder) = bytes.quotientAndRemainder(
            dividingBy: bytesPerGigabyte / 100
        )
        var hundredths = unitsOfTenMillion
        if remainder >= bytesPerGigabyte / 200 {
            hundredths += 1
        }
        let (whole, fraction) = hundredths.quotientAndRemainder(dividingBy: 100)
        return "\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    /// An optional byte count as a fixed two-decimal SI GB string or `null`.
    public static func gigabytesOrNull(_ bytes: UInt64?) -> Any {
        guard let bytes else { return NSNull() }
        return gigabytes(bytes)
    }

    /// A UTC ISO-8601 timestamp with fractional seconds, or `null`.
    public static func dateOrNull(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return makeFormatter().string(from: date)
    }

    /// A `Bool` or `null`.
    public static func boolOrNull(_ value: Bool?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    /// A `String` or `null`.
    public static func stringOrNull(_ value: String?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    /// A signed 32-bit value or `null`.
    public static func int32OrNull(_ value: Int32?) -> Any {
        guard let value else { return NSNull() }
        return Int(value)
    }

    /// Presentation names for node kinds in the CLI contract.
    public static func kindName(_ kind: NodeKind) -> String {
        switch kind {
        case .directory: return "directory"
        case .regularFile: return "regularFile"
        case .symbolicLink: return "symbolicLink"
        case .socket: return "socket"
        case .fifo: return "fifo"
        case .characterDevice: return "characterDevice"
        case .blockDevice: return "blockDevice"
        case .mountPoint: return "mountPoint"
        case .unknown: return "unknown"
        }
    }

    /// Presentation names for lifecycle states in the CLI contract.
    public static func statusName(_ status: ScanStatus) -> String {
        switch status {
        case .running: return "running"
        case .cancelling: return "cancelling"
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .interrupted: return "interrupted"
        }
    }

    /// Presentation names for issue categories in the CLI contract.
    public static func issueCategoryName(_ category: ScanIssueCategory) -> String {
        switch category {
        case .permissionDenied: return "permissionDenied"
        case .notFound: return "notFound"
        case .io: return "io"
        case .nameEncoding: return "nameEncoding"
        case .mountBoundary: return "mountBoundary"
        case .changedDuringScan: return "changedDuringScan"
        case .resourceLimit: return "resourceLimit"
        case .unsupported: return "unsupported"
        }
    }

    /// Stable ordered names for the node flag bits that are present.
    public static func flagNames(_ flags: NodeFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.package) { names.append("package") }
        if flags.contains(.duplicateHardLink) { names.append("duplicateHardLink") }
        if flags.contains(.inaccessible) { names.append("inaccessible") }
        if flags.contains(.mountBoundary) { names.append("mountBoundary") }
        if flags.contains(.sparse) { names.append("sparse") }
        if flags.contains(.changedDuringScan) { names.append("changedDuringScan") }
        if flags.contains(.symlinkLoop) { names.append("symlinkLoop") }
        if flags.contains(.clonedAllocation) { names.append("clonedAllocation") }
        if flags.contains(.fallbackEnumerator) { names.append("fallbackEnumerator") }
        if flags.contains(.firmlinkProjection) { names.append("firmlinkProjection") }
        if flags.contains(.snapshotStorageBoundary) { names.append("snapshotStorageBoundary") }
        return names
    }
}
