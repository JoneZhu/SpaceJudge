import Foundation

/// Shared, testable wording for progress values that may be incomplete.
///
/// A scan can stop (cancel, failure, permission limit) while an aggregate is
/// still incomplete or while the bounded query has omitted items. Those must
/// never be described as if a scan were still running. This type distinguishes
/// an *active* scan from a *terminal* one and is the single source of truth for
/// the toast, the focus-size suffix and the directory info row.
public struct AppProgressWording: Sendable, Equatable {
    /// Whether a scan worker may still be producing facts.
    public let isActive: Bool

    public init(phase: AppPhase) {
        isActive = phase.isActive
    }

    public init(isActive: Bool) {
        self.isActive = isActive
    }

    /// Generic message for children the bounded query did not load.
    ///
    /// Deliberately neutral: the omission can be a running scan, a cancelled
    /// scan, or simply zero-weight items in a completed scan, so it never
    /// claims a scan is still counting. Returns `nil` for a zero count.
    public func omittedItemsMessage(count: UInt64) -> String? {
        guard count > 0 else { return nil }
        return "还有 \(count) 项未显示"
    }

    /// Suffix for a focus size whose aggregate is not complete yet.
    ///
    /// Active scans are "正在统计"; terminal scans are "未完成". A complete
    /// aggregate has no suffix.
    public func incompleteSuffix(isComplete: Bool) -> String {
        guard !isComplete else { return "" }
        return isActive ? "（正在统计）" : "（未完成）"
    }

    /// Status text for a directory aggregate row.
    public func aggregateStatusText(isComplete: Bool) -> String {
        if isComplete { return "已完成" }
        return isActive ? "正在统计" : "未完成"
    }

    /// Label for "an aggregate is expected but not available yet".
    public var pendingAggregateLabel: String {
        isActive ? "正在统计" : "未完成"
    }
}
