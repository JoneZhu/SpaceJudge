import Foundation
import SpaceJudgeDomain

/// Coarse, testable UI state derived from the model's live values.
///
/// This is a *presentation* classification only: it never changes what the
/// model does, and the view still reads the underlying `AppModel` for real
/// numbers. Keeping it in `SpaceJudgeAppSupport` means the empty/zero/error
/// distinctions can be asserted in unit tests instead of only via screenshots.
public enum AppPresentationState: Sendable, Equatable {
    /// Launched, no root chosen.
    case idle
    /// The open panel is visible.
    case choosingRoot
    /// Root chosen, the first persisted batch has not arrived.
    case preparing
    /// A scan is active but has not published counting progress yet.
    case awaitingFirstBatch
    /// A scan is active and publishing counters.
    case scanning
    /// Cancel requested, waiting for the runner to settle.
    case cancelling
    /// Terminal successful scan with drawable content.
    case completed
    /// The map for the current focus is being read. Shown when the first read
    /// has not returned yet, or when a previously shown map belongs to another
    /// focus and a new read is in flight.
    case loading
    /// Terminal scan the user cancelled; committed partial results are shown.
    case cancelled
    /// Terminal scan whose current focus has no children at all. This must not
    /// be presented as "no files" without explanation.
    case emptyScope
    /// Terminal scan whose current focus has children but none has a positive
    /// allocated weight (for example sparse or zero-length files). No area is
    /// invented for them.
    case zeroAllocation
    /// The newest snapshot read failed; the previous map is still on screen.
    case sceneError
    /// Unrecoverable root or store failure.
    case failed

    /// Resolver kept pure so every branch is a unit test.
    ///
    /// `scene` is the best-known map (possibly `nil` before the first read),
    /// `sceneError` is true when the last read failed, `isLoading` is true when
    /// a read for the current focus is in flight, and `sceneMatchesFocus` is
    /// true when `scene.focusNodeID` is the current focus.
    ///
    /// Empty/zero classification uses the *current focus* page and aggregate,
    /// never the whole scan's byte total. A failed read is visible even when no
    /// map was ever loaded.
    public static func resolve(
        phase: AppPhase,
        progress: ScanProgress?,
        scene: TreemapSceneData?,
        sceneError: Bool,
        attribution: UInt64,
        isLoading: Bool = false,
        sceneMatchesFocus: Bool = true
    ) -> AppPresentationState {
        switch phase {
        case .idle, .ready:
            return .idle
        case .choosingRoot:
            return .choosingRoot
        case .failed:
            return .failed
        case .preparing:
            return sceneError && !isLoading ? .sceneError : .preparing
        case .scanning:
            if sceneError, !isLoading { return .sceneError }
            if scene != nil, isLoading, !sceneMatchesFocus { return .loading }
            return progress == nil ? .awaitingFirstBatch : .scanning
        case .cancelling:
            return sceneError && !isLoading ? .sceneError : .cancelling
        case .cancelled:
            // A user cancellation is a real, honest terminal state even when no
            // map was ever read; it is never presented as completion.
            return sceneError && !isLoading ? .sceneError : .cancelled
        case .completed, .permissionLimited:
            if sceneError, !isLoading { return .sceneError }
            if isLoading, scene == nil || !sceneMatchesFocus { return .loading }
            // With no map, no in-flight read and no error, the content is still
            // unknown; never claim completion without content.
            guard let scene else { return .loading }
            let hasOmitted = scene.hiddenOmittedCount > 0
            let focusEmpty = scene.focusPage.items.isEmpty
                && scene.focusPage.totalCount == 0
                && (scene.focusAggregate?.attributedBytes ?? 0) == 0
                && !hasOmitted
            if focusEmpty { return .emptyScope }
            let hasPositiveWeight = scene.focusPage.items.contains { $0.effectiveBytes > 0 }
            if !hasPositiveWeight, !hasOmitted {
                return .zeroAllocation
            }
            return .completed
        }
    }

    /// Short, path-free status title for the toolbar/status area.
    public var title: String {
        switch self {
        case .idle: return "未选择位置"
        case .choosingRoot: return "正在选择位置"
        case .preparing: return "正在准备扫描"
        case .awaitingFirstBatch: return "正在扫描"
        case .scanning: return "正在扫描"
        case .cancelling: return "正在取消"
        case .completed: return "扫描完成"
        case .loading: return "正在读取位置"
        case .cancelled: return "已取消"
        case .emptyScope: return "此位置为空"
        case .zeroAllocation: return "无可显示占用"
        case .sceneError: return "快照读取失败"
        case .failed: return "扫描失败"
        }
    }

    /// Whether a scan worker may still be running (cancel is meaningful).
    public var isBusy: Bool {
        switch self {
        case .preparing, .awaitingFirstBatch, .scanning, .cancelling:
            return true
        case .idle, .choosingRoot, .completed, .loading, .cancelled, .emptyScope,
             .zeroAllocation, .sceneError, .failed:
            return false
        }
    }

    /// Explanatory sentence shown in the canvas when content is absent or
    /// stale. Never fabricates files or area.
    public var explanation: String? {
        switch self {
        case .loading:
            return "正在读取当前位置的快照…"
        case .emptyScope:
            return "此位置没有可显示的子项目。"
        case .zeroAllocation:
            return "此位置的子项目占用为 0（例如空文件或稀疏文件）。"
        case .sceneError:
            // Honest for both cases: a first read with no retained map and a
            // failed refresh after navigation. It must not claim an old map
            // exists when none was ever loaded.
            return "无法读取当前位置的快照，请重试。"
        default:
            return nil
        }
    }
}

/// Compact, testable capacity presentation used by the capacity strip.
public struct CapacityPresentation: Sendable, Equatable {
    public let totalBytes: UInt64?
    public let usedBytes: UInt64?
    public let availableBytes: UInt64?
    /// Provenance label, localized for display.
    public let sourceLabel: String
    /// Used fraction in `0...1` when total and used are both known, else `nil`.
    /// The bar must not be drawn when this is `nil`.
    public let usedFraction: Double?
    /// One compact line; unknown values are em dashes, never fabricated zeros.
    public let line: String

    public init(volume: VolumeFacts?) {
        let total = volume?.totalCapacityBytes
        let used = volume?.usedBytes
        self.totalBytes = total
        self.usedBytes = used
        self.availableBytes = volume?.availableCapacityBytes
        switch volume?.capacitySource {
        case .importantUsage:
            sourceLabel = "重要用途可用"
        case .standardAvailable:
            sourceLabel = "普通可用（含 statfs 回退）"
        case .unavailable:
            sourceLabel = "容量未知"
        case .none:
            sourceLabel = "容量未知"
        }
        if let total, total > 0, let used {
            usedFraction = min(1, max(0, Double(used) / Double(total)))
        } else {
            usedFraction = nil
        }
        line = "已用 \(ByteFormatting.bytes(used)) / 总 \(ByteFormatting.bytes(total))"
            + " · 剩余 \(ByteFormatting.bytes(volume?.availableCapacityBytes))"
    }

    /// Accessible description including the provenance label.
    public var accessibilityLabel: String {
        "\(line)，来源：\(sourceLabel)"
    }
}
