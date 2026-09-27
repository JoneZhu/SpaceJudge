# 系统架构

状态：Accepted

## 1. 技术选择

- 语言：Swift 6，启用严格并发检查。
- 最低系统：macOS 14。
- 应用层：SwiftUI，负责窗口、工具栏、弹窗、状态组合与可访问性。
- 空间图：AppKit `NSView` + Core Graphics。使用单个绘制面而不是为每个节点创建 SwiftUI View。
- 扫描热路径：Darwin `getattrlistbulk`、`openat`/`open`、`close` 和必要的 `fstatat`。
- 持久化：系统 SQLite3，无第三方 ORM。
- 日志与性能：Unified Logging、`OSSignposter`。
- 构建：Xcode app 工程 + Swift Package 模块；核心模块可由 `swift test` 独立验证。

选择单绘制面是因为 treemap 可能同时存在成千上万的可见矩形；SwiftUI `Canvas` 对大量绘制很合适，但它不为每个元素提供独立交互和可访问性。MVP 采用 `NSView`，统一完成绘制、命中测试、鼠标追踪和局部失效；外层仍由 SwiftUI 管理。

## 2. 模块边界

```text
SpaceJudgeApp
  ├── SpaceJudgeUI
  │     ├── AppState / ViewState
  │     ├── TreemapContainer (SwiftUI -> NSViewRepresentable)
  │     └── 权限、弹窗、菜单、Finder 适配
  ├── SpaceJudgeUseCases
  │     ├── StartScan
  │     ├── CancelScan
  │     ├── ObserveSnapshot
  │     └── ResolveNodePath
  ├── SpaceJudgeScan
  │     ├── DirectoryEnumerator 协议
  │     ├── DarwinBulkEnumerator
  │     ├── ScanCoordinator
  │     └── AggregateBuilder
  ├── SpaceJudgeStore
  │     ├── SnapshotRepository 协议
  │     └── SQLiteSnapshotRepository
  ├── SpaceJudgeTreemap
  │     ├── SquarifiedLayout
  │     ├── VisibilityReducer
  │     └── HitIndex
  └── SpaceJudgeDomain
        ├── Node / Scan / Volume / Issue
        └── 共享协议、事件与值类型

SpaceJudgeBench
  ├── 夹具生成
  ├── 扫描 CLI
  └── JSON 基准报告

SpaceJudgeVolumePlanKit
  ├── 非递归 root probe（生产 enumerator/parser）
  └── spacejudge-volume-plan 命令
```

依赖只能向下。`Domain` 不依赖 Foundation 之外的 UI、数据库或 Darwin 实现；`Scan` 不依赖 UI；`Treemap` 是纯函数模块；App 通过协议组合具体实现。

## 3. 核心协议

建议接口，Pi 实现时可在不改变语义的前提下调整命名：

```swift
public struct ScanRequest: Sendable, Equatable {
    public let root: ScanRoot
    public let sizeMetric: SizeMetric
    public let boundaryPolicy: BoundaryPolicy
    public let packagePolicy: PackagePolicy
    // Session-only, bounded (<= 8) snapshot workspace exclusions; never persisted.
    public let workspaceExclusions: [SnapshotWorkspaceExclusion]
}

public protocol ScanEngine: Sendable {
    func events(for request: ScanRequest) -> AsyncThrowingStream<ScanEvent, Error>
    func cancel(scanID: ScanID) async
}

public enum BoundaryPolicy: Sendable, Equatable {
    case selectedTree
    case stayOnRootFileSystem
    case visibleStartupVolumeGroup
}

public struct VolumeScanPlan: Sendable, Equatable {
    public let kind: VolumeScanPlanKind
    public let root: ScanRoot
    public let boundaryPolicy: BoundaryPolicy
    public let evidence: VolumeScanPlanEvidence
}

public protocol VolumeScanPlanning: Sendable {
    func plan(for selection: DirectorySelection) -> VolumeScanPlan
}

public enum ScanEvent: Sendable, Equatable {
    case started(ScanMetadata)
    case batch(NodeBatch)
    case progress(ScanProgress)
    case issue(ScanIssue)
    case completed(ScanSummary)
    case cancelled(ScanSummary)
}

public protocol SnapshotRepository: Sendable {
    func begin(_ metadata: ScanMetadata) async throws
    func write(_ batch: NodeBatch) async throws
    func finish(_ summary: ScanSummary) async throws
    func children(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord]
}

public protocol TreemapLayingOut: Sendable {
    func layout(_ input: TreemapInput, in bounds: CGRect) -> TreemapOutput
}
```

`AsyncThrowingStream` 只承担有界事件流，不让每个文件成为一次 UI 事件。`NodeBatch` 默认 1,000–5,000 条或 50 ms 刷新一次，以先到条件为准。

## 4. 并发模型

- `ScanCoordinator` 是 actor，拥有扫描生命周期、取消令牌和目录工作队列。
- 目录枚举在受控 worker 上执行同步系统调用；默认 worker 数取 `min(4, activeProcessorCount)`，基准后再调整。
- 每个 worker 独占目录 FD 与属性缓冲区，不跨任务共享裸指针。
- 解析后的记录转换成 `Sendable` 值类型后才能离开 worker。
- `AggregateBuilder` 串行维护父子计数与硬链接去重，避免共享可变字典竞争。
- SQLite 使用单 writer actor；读连接独立、只读。
- UI 只在 MainActor 上接收节流后的 `ScanViewSnapshot`。
- 取消使用 Swift cooperative cancellation 加扫描级原子标志；系统调用返回后立即检查。

不使用“每个目录一个 Task”的无界并发，也不从主线程调用 `FileManager` 递归枚举。

## 5. 数据流

```text
用户选择根目录
  -> VolumeScanPlanning 解析 VolumeScanPlan（公共卷事实）
  -> 权限与卷信息预检
  -> ScanCoordinator 建立扫描
  -> bounded directory workers
  -> Darwin 属性批量解析
  -> NodeBatch
       ├── SQLite writer 持久化
       ├── AggregateBuilder 更新目录总量
       └── SnapshotCoalescer (<= 10 Hz)
              -> MainActor AppState
              -> Treemap layout 后台计算
              -> NSView 绘制与命中索引
```

事件流中的批次是 append-only 的事实记录。目录聚合值在扫描期间可以增长，完成后固化。UI 通过 `revision` 丢弃过期布局结果。

## 6. UI 状态机

```text
idle
  -> choosingRoot
  -> preparing
  -> scanning <-> browsingWhileScanning
  -> completed

preparing/scanning -> permissionLimited
scanning -> cancelling -> cancelled
任意状态 -> failed（仅不可恢复的根级错误）
```

单个子目录错误产生 `ScanIssue`，不进入全局 `failed`。重新扫描创建新 `ScanID`，不在旧快照上原地覆盖。

## 7. Treemap 渲染架构

- 布局算法为确定性的 squarified treemap。
- 输入只包含当前焦点节点、需要展示的后代、权重和稳定排序键。
- 排序键：`allocatedBytes` 降序，再按规范化名称和 `NodeID`，保证增量刷新尽量稳定。
- 后台生成 `[TileGeometry]`；主线程只交换不可变数组并调用 `setNeedsDisplay`。
- 命中测试用分层数组或轻量 R-tree；不遍历全库节点。
- 可见性裁剪：小于 2×2 pt 不绘制；不足文字宽度不绘制标签；极小兄弟可聚合成“其他”。
- 缩放、窗口变化和详情级别变化都会产生新布局 revision；旧任务允许被取消。
- 鼠标悬停只重绘旧/新高亮区域，不重算整棵树。

## 8. 权限与发行决策

MVP 优先直接签名与公证分发，不把 Mac App Store 作为第一阶段约束。应用保持只读，并要求用户通过 `NSOpenPanel` 明确选择根目录。若用户希望扫描受 TCC 保护的全盘位置，再引导授予“完全磁盘访问权限”。

即使关闭 App Sandbox，也不能绕过 TCC、POSIX 权限或 ACL。权限失败必须进入错误汇总。若未来选择 App Sandbox，需要为用户选择目录启用 read-only entitlement，并用 security-scoped bookmark 持久化访问；该变更单独立 ADR。

读取容量 API属于 required-reason API，App target 必须包含 `PrivacyInfo.xcprivacy` 与有效理由。

## 9. 不可替换的架构约束

- 任何普通文件内容都不进入扫描器。
- UI 不直接持有 SQLite 连接、FD 或裸路径拼接逻辑。
- 不通过递归函数持有与目录深度相同的调用栈。
- 不把一个文件映射成一个 SwiftUI View。
- 不把完整绝对路径重复存储到每个节点。
- 不以扫描到的节点总量估算完成百分比；未知总量时显示计数与速率。
- 不把目录已归属大小描述为“删除后必然释放空间”。

## 10. 目录结构目标

```text
SpaceJudge/
  App/
  Packages/SpaceJudgeCore/
    Sources/
      SpaceJudgeDomain/
      SpaceJudgeScan/
      SpaceJudgeStore/
      SpaceJudgeTreemap/
    Tests/
  Benchmarks/
  docs/
  Prototype/
```

现有 HTML 原型在迁移前保留原位置；原生工程建立后再统一移动，不在第一阶段破坏当前预览入口。

## 11. 快照缓存工作区与自保护（Phase 5C）

快照是可重建的工作缓存，不是用户文档。Phase 5C 把它收敛为单会话、单扫描缓存（见 [ADR-0009](adr/0009-session-snapshot-cache.md)）：

- 生产工作区是 Foundation 返回的 `<user Caches>/SpaceJudge`，绝不硬编码用户主目录；Debug 的 `SPACEJUDGE_TEST_DATABASE_PATH` 只控制本轮测试数据库。
- 工作区成员固定为 `snapshots.sqlite{,-wal,-shm}` 和 `spool/spacejudge-spool-<UUID>.bin`。工作区根用不跟随的 `lstat` 校验：根为符号链接、非目录或类型/权限无法确认时 fail-closed，绝不枚举或删除目标。启动清理只按白名单删除这些成员，不跟随符号链接、不删父目录、不递归；遇到未知成员则 fail-closed 并拒绝启动。
- 受管数据库三件套在 repository 打开前以 `0600` 预创建并在打开后收紧；已存在但不是普通文件的成员 fail-closed。目录权限目标 `0700`。
- `SnapshotWorkspace`（`SpaceJudgeAppSupport`）只负责路径与文件生命周期；`SQLiteSnapshotRepository` 只负责 SQLite 生命周期。
- `ScanRequest` 携带一个 session-only 的有界排除集合（生产中恰好一个工作区根）。扫描器在发布 `.started` 之前拒绝“根等于或位于工作区内”，并把根与排除路径各做一次 canonical 解析，因此 symlink 别名指向工作区或其任意后代也会被拒绝；解析不进每节点热路径。遇到工作区目录时保留一个带 `NodeFlags.snapshotStorageBoundary = 1 << 10` 的叶子节点，不入队、不读取其子项。匹配以 `(deviceID,fileID)` 优先、规范化绝对路径兜底，因此同名目录不会被误伤，也不为每个节点增加常驻字段。
- App 启动顺序固定：取得工作区 -> 创建并收紧权限（目录 `0700`）-> 白名单清理 -> 建新库 -> 打开只读连接。关闭顺序固定：停止扫描 -> 关闭 reader -> writer 做有界 checkpoint/回收。

因此扫描不会把自己的数据库、WAL、SHM 或队列文件重新计入结果，缓存也不会跨扫描、跨启动无界增长。

存储与根拒绝错误通过 `AppUserError` 映射为无路径文案，并在现有 footer 内以一行紧凑、可截断、可访问（`accessibilityIdentifier = scan-error`）的文本展示；不引入大面板、不显示完整路径。权限引导按钮可与该文本同时存在。
