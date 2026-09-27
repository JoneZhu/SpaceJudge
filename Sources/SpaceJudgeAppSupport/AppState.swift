import Foundation
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore

/// Coarse app lifecycle phase for the Phase 3 shell.
///
/// This mirrors the state machine in `docs/12-phase-3-design.md` but is a flat
/// enum: transitions are driven by `AppModel` and only one scan is active at a
/// time.
public enum AppPhase: Sendable, Equatable, CaseIterable {
    /// Launched, nothing chosen yet. Never scans automatically.
    case idle
    /// The open panel is visible.
    case choosingRoot
    /// A root was chosen but no scan has started.
    case ready
    /// Root opened; waiting for the first persisted batch.
    case preparing
    /// The engine is publishing facts.
    case scanning
    /// Cancel requested, waiting for the runner to settle.
    case cancelling
    /// Terminal state: the scan was cancelled by the user.
    case cancelled
    /// Terminal state: the scan finished normally.
    case completed
    /// Terminal or browsing state where at least one location was unreadable.
    /// Available results are still shown.
    case permissionLimited
    /// Unrecoverable root, store or fatal failure.
    case failed

    /// Whether a scan task may still be running.
    public var isActive: Bool {
        switch self {
        case .preparing, .scanning, .cancelling:
            return true
        case .idle, .choosingRoot, .ready, .cancelled, .completed,
             .permissionLimited, .failed:
            return false
        }
    }

    /// Short status text for the toolbar/status line. No paths, no secrets.
    public var statusText: String {
        switch self {
        case .idle: return "未选择位置"
        case .choosingRoot: return "正在选择位置"
        case .ready: return "已选择位置"
        case .preparing: return "正在准备扫描"
        case .scanning: return "正在扫描"
        case .cancelling: return "正在取消"
        case .cancelled: return "已取消"
        case .completed: return "扫描完成"
        case .permissionLimited: return "部分位置无法访问"
        case .failed: return "扫描失败"
        }
    }
}

/// A reason the app cannot show complete results, phrased for the user and
/// intentionally free of absolute paths.
public enum AppUserError: Sendable, Equatable {
    case rootPermissionDenied
    case rootUnavailable
    case storageFailed
    case insufficientStorage
    case scanRootInsideSnapshotWorkspace
    case unexpected

    public var message: String {
        switch self {
        case .rootPermissionDenied:
            return "部分位置无法访问。可在“系统设置 > 隐私与安全性 > 完全磁盘访问权限”中为此应用授权后重试。"
        case .rootUnavailable:
            return "无法打开所选位置。它可能已被移动、卸载或不可用。"
        case .storageFailed:
            return "无法保存扫描快照。请确认磁盘空间充足后重试。"
        case .insufficientStorage:
            return "可用空间过少，SpaceJudge 已停止写入扫描缓存。请先释放少量磁盘空间后重试。"
        case .scanRootInsideSnapshotWorkspace:
            return "不能扫描 SpaceJudge 自己的工作缓存，请选择其他位置。"
        case .unexpected:
            return "扫描过程中发生错误，已保留可用结果。"
        }
    }

    /// Maps an arbitrary error to a short, path-free user message.
    public static func classify(_ error: any Error) -> AppUserError {
        if let scanError = error as? ScanError {
            switch scanError {
            case .rootOpenFailed(let code) where code == EACCES || code == EPERM:
                return .rootPermissionDenied
            case .rootOpenFailed:
                return .rootUnavailable
            case .scanRootInsideSnapshotWorkspace:
                return .scanRootInsideSnapshotWorkspace
            case .tooManyWorkspaceExclusions:
                return .unexpected
            case .duplicateScan, .cancelled:
                return .unexpected
            case .directoryOpenFailed, .enumerationFailed, .parseFailed,
                 .aggregationOverflow, .counterOverflow,
                 .attributionExceedsAllocation, .spoolFailed:
                return .unexpected
            }
        }
        if let storeError = error as? SnapshotStoreError {
            switch storeError {
            case .insufficientStorage, .storageCapacityUnavailable:
                return .insufficientStorage
            case .sqlite where storeError.isStorageExhaustion:
                return .insufficientStorage
            default:
                return .storageFailed
            }
        }
        let nsError = error as NSError
        if nsError.domain == "SpaceJudgeStore" || nsError.domain.contains("sqlite") {
            return .storageFailed
        }
        return .unexpected
    }
}
