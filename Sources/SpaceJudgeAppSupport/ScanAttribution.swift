import Foundation
import SpaceJudgeDomain

/// Best-known attribution state for the current scan root.
///
/// Terminal facts always win over in-flight progress; the model derives this
/// value from existing state instead of storing a second, drift-prone copy.
public enum ScanAttributionState: Sendable, Equatable {
    /// The scan is still running and only a best-known attributed total exists.
    case scanning(attributedBytes: UInt64)
    /// The scan reached a terminal state. `isComplete` is `false` for a
    /// cancelled or otherwise unfinished scan.
    case terminal(attributedBytes: UInt64, isComplete: Bool)
}

extension ByteFormatting {
    /// One compact reconciliation line for the footer.
    ///
    /// The value is purely derived from scan facts plus volume facts. It never
    /// claims that the remainder is reclaimable:
    ///
    /// - scanning: `已扫描并归属 X`;
    /// - terminal with unknown used: `当前范围 X`;
    /// - terminal with `used >= attributed`: `当前范围 X · 卷内其他/未纳入 Y`;
    /// - terminal with `attributed > used`: `当前范围 X · 与卷用量差异 +Y`;
    /// - unfinished terminal inserts `（未完成）`.
    ///
    /// The difference is computed only after a saturation-safe comparison, so
    /// `UInt64.max` and `0` never underflow.
    public static func attributionLine(
        _ state: ScanAttributionState?,
        volume: VolumeFacts?
    ) -> String? {
        guard let state else { return nil }
        switch state {
        case .scanning(let attributedBytes):
            return "已扫描并归属 \(bytes(attributedBytes))"

        case .terminal(let attributedBytes, let isComplete):
            let scope = isComplete ? "当前范围" : "当前范围（未完成）"
            guard let used = volume?.usedBytes else {
                return "\(scope) \(bytes(attributedBytes))"
            }
            if attributedBytes > used {
                return "\(scope) \(bytes(attributedBytes))"
                    + " · 与卷用量差异 +\(bytes(attributedBytes - used))"
            }
            return "\(scope) \(bytes(attributedBytes))"
                + " · 卷内其他/未纳入 \(bytes(used - attributedBytes))"
        }
    }
}
