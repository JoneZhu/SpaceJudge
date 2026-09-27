# Phase 3 实施设计：macOS 应用壳、权限与容量接线

状态：Accepted（实现与独立验收见 `13-phase-3-baseline.md`）

设计日期：2026-09-26

## 1. 阶段目标

Phase 3 交付第一份可启动、可真实选择目录并完成扫描的 macOS 原生 App。它验证 AppKit/SwiftUI、扫描器、SQLite 与容量计量能在一个真实应用生命周期内安全协作。

必须完成：

1. Xcode macOS App target，最低 macOS 14，可在本机 Debug/Release 构建和启动。
2. `NSOpenPanel` 单目录选择；未选择时不扫描。
3. 真实 reference/bulk 内核中的 bulk 默认路径扫描、SQLite 持久化、进度、取消、错误汇总和退出清理。
4. 顶部或底部一行紧凑显示总容量、已用、剩余和计量来源。
5. 扫描中显示文件数、目录数、已归属字节、速率和“正在扫描”，不显示伪百分比。
6. 完成后用独立只读 SQLite connection 显示 root 下最大的前 100 项，验证真实快照可浏览。
7. 访问受限时给出可理解提示和系统设置入口，不把权限不足伪装成空磁盘。
8. App 退出时取消扫描、等待 runner 收尾、关闭数据库和 security scope。

本阶段不实现最终 treemap、单击展开/双击进入、面包屑、Finder 右键、FSEvents、删除、AI、签名公证或 Mac App Store 上架。最终高性能空间图属于 Phase 4。

## 2. 构建与目录

保留根目录 Swift Package 作为核心与测试入口，新增：

```text
App/
  SpaceJudge.xcodeproj
  SpaceJudgeApp/
    SpaceJudgeApp.swift
    AppDelegate.swift
    ContentView.swift
    Assets.xcassets
    PrivacyInfo.xcprivacy

Sources/SpaceJudgeAppSupport/
  AppModel.swift
  AppState.swift
  ByteFormatting.swift
  DirectoryAccess.swift
  SnapshotLoader.swift

Tests/SpaceJudgeAppSupportTests/
```

`SpaceJudge.xcodeproj` 通过 local Swift package reference 引用仓库根目录产品。App target 只负责 bundle、SwiftUI scene、AppKit picker/lifecycle 和资源；可测试的状态机放在 `SpaceJudgeAppSupport`。

依赖方向：

```text
SpaceJudgeApp -> SpaceJudgeAppSupport
SpaceJudgeAppSupport -> Domain + Scan + Store + UseCases
UseCases -> Domain
Store -> Domain + system SQLite3
Scan -> Domain + Darwin/Foundation
```

不得把 AppKit/SwiftUI 引入 Domain、Store、Scan 或 Treemap。

## 3. 权限模型

遵守 [ADR-0006](adr/0006-direct-distribution-session-access.md)：

- App Sandbox 暂不启用；没有写文件 entitlement。
- 用户通过 `NSOpenPanel` 选择一个目录或卷，`canChooseDirectories=true`、`canChooseFiles=false`、单选。
- 选择结果只在当前 App 进程持有。security scope 必须严格成对；重复选择、取消、失败和退出都不能泄漏 scope。
- 不持久化 root path/bookmark；SQLite 仍只保存 display name。
- Full Disk Access 没有可靠的公开“已授权”查询。本阶段从实际 `EACCES` / `EPERM` 证据推导 `permissionLimited`，文案使用“部分位置无法访问”，不能声称精确权限状态。
- “打开系统设置”只导航到隐私设置；应用不会代替用户授权，也不会循环弹窗。

## 4. 容量计量

新增 `VolumeFactsProviding` 协议和 `FoundationVolumeFactsProvider`：

```swift
public protocol VolumeFactsProviding: Sendable {
    func facts(forFileSystemPath path: String) -> VolumeFacts
}
```

实现顺序：

1. `volumeTotalCapacityKey`
2. `volumeAvailableCapacityForImportantUsageKey`
3. important usage 不可用时 fallback 到 `volumeAvailableCapacityKey`
4. 负值、转换溢出、`available > total` 或读取失败不 trap；保留能确认的值，来源为 `.unavailable` 或对应 fallback。

`FileSystemScanEngine` 在 root 成功打开后、发出 `.started` 前读取一次容量，并把同一份不可变 `VolumeFacts` 放入 `ScanMetadata` 和 terminal `ScanSummary`。Store 已有 schema，必须验证关闭重开后容量与 source 无损。

UI 数字：

- 总容量：`total`
- 剩余：`available`
- 已用：仅在 `total >= available` 时显示 `total - available`
- 任一值未知显示 `—`，不得显示 0 B
- 浏览范围不影响这行卷容量；容量属于所选 root 所在卷

App bundle 包含 `PrivacyInfo.xcprivacy`：

- `NSPrivacyAccessedAPICategoryDiskSpace` / `85F4.1`：向用户显示磁盘空间。
- `NSPrivacyAccessedAPICategoryFileTimestamp` / `3B52.1`：访问用户明确授权目录的时间、大小和元数据。
- `NSPrivacyTracking=false`、收集数据为空；容量、路径和文件事实不上报。

## 5. 持久化 Runner 的观察接口

现有 `PersistingScanRunner.run` 只返回终态，App 无法显示进度。新增不携带大 batch 的轻量观察值：

```swift
public enum PersistingScanUpdate: Sendable, Equatable {
    case started(ScanMetadata)
    case committed(scanID: ScanID, revision: Revision)
    case progress(scanID: ScanID, value: ScanProgress)
    case issueRecorded(scanID: ScanID, totalCount: UInt64)
    case terminal(ScanSummary)
}
```

`run(_:onUpdate:)` 保持现有持久化顺序：

- `started` 仅在 `repository.begin` 成功后观察到。
- `committed` 仅在 batch transaction commit 后观察到。
- issue update 仅在 `repository.record` 成功后观察到。
- terminal 仅在 `repository.finish` 成功后观察到。
- observer 不接收 `NodeBatch`，不持有 SQLite statement/connection。
- 原 `run(_:)` 保留并调用新入口的 no-op observer，兼容 CLI/tests。
- observer 必须快速返回；AppSupport 在自身 actor/MainActor 边界合并更新，不能在 runner 中执行布局或全量查询。

原有无终态、status mismatch、scanID mismatch、cancel+fail 语义保持不变。

## 6. 有界 UI 查询

现有 `children(of:)` 返回完整直接子项，不适合 UI 预览超宽 root。新增领域值：

```swift
public struct SnapshotChildItem: Sendable, Equatable {
    public let node: NodeRecord
    public let name: NameRecord
    /// 目录取 directory_aggregates 的 best-known attributed bytes，
    /// 无 aggregate 时回退到 node.attributedBytes；不改写 NodeRecord。
    public let effectiveAttributedBytes: UInt64
}

public struct SnapshotChildPage: Sendable, Equatable {
    public let items: [SnapshotChildItem]
    public let totalCount: UInt64
}
```

`SnapshotRepository.childPage(of:in:limit:)`：

- limit 必须在 1...500，App 使用 100。
- SQL 用 `nodes_by_parent` 做 scan-local 直接子项过滤，再 LEFT JOIN `directory_aggregates` 与 scan-local `names`；只 materialize 前 limit 项，同时返回直接子项总数。结果/内存有界于 limit，但有效权重排序可能需要扫描全部直接子项（不是常数时间）。
- 顺序为 effective attributed bytes（目录优先取 aggregate）DESC、NodeID ASC；invalid UTF-8 保留原始 bytes，UI 用替换字符显示但不改数据库。
- App 使用独立 `openReadOnly` repository；writer actor 不承担 UI 查询。

## 7. App 状态机

```text
idle
  -> choosingRoot
  -> ready(root display name)
  -> preparing
  -> scanning
  -> completed

scanning -> cancelling -> cancelled
preparing/scanning/completed -> permissionLimited（仍保留可用结果）
preparing/scanning -> failed（仅 root/store/fatal）
任意稳定状态 -> choosingRoot / new scan
```

`AppModel` 为 `@MainActor @Observable`，只公开轻量值：

- phase、rootDisplayName、scanID/rootNodeID
- latest progress/summary/volume
- issue count 与 permission-limited 标志
- `SnapshotChildPage`（最多 100 项）
- user-facing error，不含完整绝对路径

约束：

- 一个 AppModel 同时最多一个 scan task。
- 开始新扫描前必须取消并等待旧扫描结束。
- progress/committed 合并到最多 10 Hz；terminal、fatal、cancelled 立即发布。
- committed refresh 使用 revision token；较旧 read/layout 结果不得覆盖较新状态。
- 主线程不打开目录、不写 SQLite、不执行全量 children query。

## 8. 数据库位置与生命周期

Phase 3 使用：

```text
~/Library/Application Support/SpaceJudge/snapshots.sqlite
```

- 目录创建权限采用默认用户私有目录，不写扫描 root。
- 数据库保存多个 scan；本阶段不自动删除历史，也不展示历史入口。
- App 启动打开 writer 时按 Phase 2 规则把遗留 `running` 标为 `interrupted`。
- 同一路径只创建一个 writable repository；UI reader 用独立 read-only repository。
- App 退出时先停止 scan，再显式 close reader/writer。
- 测试只使用 `mktemp`/临时 Application Support 替身，不触碰真实用户数据库。

## 9. App UI 形态

Phase 3 是接线壳，不冒充最终 treemap：

```text
┌ 选择文件夹/磁盘 | 重新扫描 | 取消 ───────── 当前状态 ┐
│ Macintosh HD                                      │
│ 总容量 512 GB · 已用 412.6 GB · 剩余 99.4 GB       │
├───────────────────────────────────────────────────┤
│ 正在扫描  85,240 文件 · 8,120 目录 · 24.1万项/秒   │
│                                                   │
│ 最大项目（真实快照，最多 100 项）                   │
│ 名称                         已归属       类型       │
│ Users                        312.6 GB     目录       │
│ Applications                  42.0 GB     目录       │
│ …                                                 │
├───────────────────────────────────────────────────┤
│ 部分位置无法访问（如有） · Phase 4 接入空间图        │
└───────────────────────────────────────────────────┘
```

- 微信式浅灰白背景、克制绿色强调、圆角和紧凑间距；不复制品牌素材。
- 容量只是一行小字，不恢复大卡片。
- 未选择时显示明确空状态和“选择文件夹或磁盘”。
- 正在扫描时允许取消和查看已提交的前 100 项。
- “最大项目”是 Phase 3 诊断浏览，不是最终视觉；文案明确 Phase 4 将替换为空间图。
- VoiceOver 能访问按钮、状态、容量、错误和列表行；不使用仅靠颜色表达状态。

## 10. 退出与取消

- AppModel 保存 scan `Task` 与 started ScanID。
- 用户取消：先请求 engine.cancel；同时 cancel 消费 task，等待 runner 结束并保留 cancelled snapshot。
- 如果尚未收到 started，则 task cancellation 触发 stream termination，不能遗留 worker。
- `applicationShouldTerminate` 在扫描中返回 `.terminateLater`，异步执行 cancel-and-wait、关闭 repositories、释放 security scope 后调用 reply。
- 退出等待设 2 秒工程目标；超时仍不得启动新的后台工作。测试验证普通取消/退出路径无悬挂 Task、DB running 或 scope leak。

## 11. 错误与隐私

- 根选择取消不是错误，返回之前稳定状态。
- 根打开 `EACCES` / `EPERM`：permission-limited + 解决说明。
- 子目录 permission issue：扫描继续，状态可 completed 但显示 issue 数。
- SQLite/fatal：failed，保留简短可操作信息；日志中用 scanID 和 errno，不记录完整路径。
- UI 不展示 bookmark，不提供复制全部路径按钮；本阶段列表只显示名称和根 display name。
- Unified Logging 只记录生命周期、计数、耗时与错误类别；不记录 name bytes 或 path。

## 12. 测试与验收

### Swift Package

- Phase 0–2 的 171 tests 全部继续通过。
- Volume provider：important、fallback、unknown、negative/overflow、不一致值。
- Engine metadata/summary/store reopen 容量一致。
- Runner update：只在成功持久化后发布；失败不发布假 commit/terminal。
- childPage：limit、总数、排序、scan-local name、invalid UTF-8、查询计划。
- AppModel：状态转换、10 Hz 合并、旧 revision 丢弃、cancel、permission issue、错误脱敏、scope 成对释放。

### Xcode

```sh
xcodebuild -project App/SpaceJudge.xcodeproj \
  -scheme SpaceJudge -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project App/SpaceJudge.xcodeproj \
  -scheme SpaceJudge -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

- App bundle 含 `PrivacyInfo.xcprivacy`，`plutil -lint` 通过，理由为 85F4.1 / 3B52.1。
- `otool`/bundle 检查没有第三方动态库和网络 SDK。

### 真实端到端

1. 启动 App，确认不自动扫描。
2. 选择独立临时 fixture；出现真实容量与 scanning 状态。
3. 扫描完成后最大的项目列表与 persist smoke 核心计数一致。
4. 扫描大 fixture 后取消；2 秒内进入 cancelled，无继续增长、无 running DB。
5. 重新扫描可成功；退出时无后台进程与打开数据库锁。
6. 至少验证 900×640 与 1,280×800、浅色/深色、增大字体下无截断关键操作。

## 13. Phase 3 验收门

- Swift tests、Debug/Release Xcode build 全绿且无新增 warning。
- App 可由 Codex 实际启动、选目录、扫描、取消、重扫和退出。
- 容量取自真实卷并在 DB 重开后一致；unknown 不伪装为 0。
- UI 主线程不做扫描/SQLite I/O；UI 更新不超过 10 Hz。
- Privacy manifest、直接分发/session-only 权限决策与代码一致。
- 无第三方 package、网络请求、删除接口、AI 或遗留后台服务。

通过后新增 `13-phase-3-baseline.md`，再进入 Phase 4 的 AppKit/Core Graphics treemap。

## 14. 实现记录（Phase 3）

本节只记录实现时的具体命名、落点与真实证据，不改变第 1–13 节的语义。

- `SpaceJudgeDomain` 新增 `VolumeFactsProviding`、`FoundationVolumeFactsProvider` 与纯函数 `VolumeCapacityResolver.facts(total:availableForImportantUsage:standardAvailable:)`。解析顺序、负值、缺失、`available > total` 与 UInt64 边界都在 resolver 内处理，provider 只做 URL resource values 读取。
- `ScanConfiguration` 新增可注入 `volumeFactsProvider`；`FileSystemScanEngine` 在 root `open`+`fstat` 成功后、`.started` 前采集一次 `VolumeFacts`，同一不可变值进入 `ScanMetadata`、terminal `ScanSummary`，因而随 `ScanSummary`/`begin(metadata)` 进入 Store。
- `SpaceJudgeDomain` 新增 `SnapshotChildItem`、`SnapshotChildPage`、`SnapshotQueryError`、`SnapshotQueryLimits`；`SnapshotRepository` 新增 `childPage(of:in:limit:)`（`1...500`）。`SQLiteSnapshotRepository` 用 `nodes_by_parent` 顺序 join scan-local `names`，返回 items 与直接子项 `COUNT(*)`。
- `SpaceJudgeUseCases` 新增 `PersistingScanUpdate` 与 `run(_:onUpdate:)`；`started`/`committed`/`issueRecorded`/`terminal` 只在对应 `begin`/`write`/`record`/`finish` 成功后发布，`progress` 仅在 `.started` 后转发。observer 不接收 `NodeBatch`。`run(_:)` 保留并调用 no-op observer。
- 新增 Swift Package target/product `SpaceJudgeAppSupport` 与测试 target `SpaceJudgeAppSupportTests`：`AppPhase`/`AppUserError`、`ByteFormatting`、`DirectoryAccess`（`@MainActor`，只声明 picker 与 security scope 配对）、`SnapshotLoader`、`ScanUpdateBuffer`（按通道合并，仅 one-shot 触发即时 drain）、`@MainActor @Observable AppModel`。
- AppModel：progress/commit 走 10 Hz pump 合并，terminal/fatal/cancel 即时；refresh 用 generation 丢弃旧 revision 读结果；一个 active scan；替换/重扫前 cancel-and-wait；用户取消保留 cancelled snapshot；`shutdown()` 取消扫描、释放 scope、关闭 repositories。
- 新增 `App/SpaceJudge.xcodeproj`（local Swift package reference `..`、shared `SpaceJudge` scheme）、`SpaceJudgeApp` target、`com.hongdazhu.SpaceJudge`、最低 macOS 14、Swift 6。App target 只含 SwiftUI scene、`AppDelegate` bootstrap、`OpenPanelDirectoryAccess`、assets、`Info.plist`、`PrivacyInfo.xcprivacy`。
- App 组合：`AppDelegate` 用 detached task 打开 `~/Library/Application Support/SpaceJudge/snapshots.sqlite` 的 writer 与独立 read-only reader，再交给 MainActor model；`applicationShouldTerminate` 返回 `.terminateLater` 并在 `model.shutdown()` 后 reply。
- Debug-only 测试接缝：`SPACEJUDGE_TEST_DATABASE_PATH` 必须是绝对 `.sqlite` 路径，否则拒绝启动；Release 完全忽略该变量。测试只使用临时数据库。
- Phase 3 交付时 Swift 测试为 214 tests / 29 suites（Phase 0–2 的 171 项全部保留；round-1/round-2 修正后数量），Release `swift build` 与 Xcode Debug/Release 均成功。
- `xcodebuild` 会输出唯一一条非编译诊断：`appintentsmetadataprocessor ... warning: Metadata extraction skipped. No AppIntents.framework dependency found.`。这是 AppIntents 元数据工具的固定提示，不是 Swift/Clang 编译 warning，也不影响产物；本项目不引入 AppIntents。

### 14.1 Round-1 验收修正

- `SnapshotChildItem` 新增 `effectiveAttributedBytes`：目录子项取 `directory_aggregates.attributed_bytes`（partial 或 complete 都可），没有 aggregate 时回退到 node 值；`NodeRecord.attributedBytes` 本身不被改写。`childPage` SQL 变为 `nodes INDEXED BY nodes_by_parent LEFT JOIN directory_aggregates`，`ORDER BY COALESCE(agg, node) DESC, id ASC LIMIT ?`，因此直接子项过滤仍走 `nodes_by_parent`，排序与 limit 都基于有效权重。UI 行与 accessibility 标签改用 effective 值。
- `ByteFormatting.bytes(0)` 固定返回 `0 B`；formatter 允许 `.useBytes`，避免负数/小值落入 `Zero KB`。
- `ScanUpdateBuffer.onImmediateWake` 改为 `setImmediateWake(_:)`/`clearImmediateWake()`，安装、清除与调用捕获都在同一把锁内完成，回调在锁外调用；`AppModel` 使用安全 API。新增并发安装/清除 + one-shot 投递压力测试。

### 14.2 Round-2 验收修正

- `AppModel.chooseRoot()` 用 `isChoosingRoot` 同步标记防止重入：picker 挂起期间第二次调用是 no-op，不能打开第二个 picker 或改写第一次调用捕获的 stable phase；工具栏与菜单在选择面板打开时禁用“选择文件夹或磁盘”。
- picker 取消时 `stablePhase(fallback:)` 精确恢复到捕获的稳定阶段（`.idle`/`.ready`/`.cancelled`/`.completed`/`.permissionLimited`/`.failed`），不再因为 `rootDisplayName != nil` 把 `.failed` 伪装成 `.ready`；原错误说明与原 summary 保持不变。
- `SnapshotRepository.childPage` 协议注释与第 6 节措辞改为按 `SnapshotChildItem.effectiveAttributedBytes` 排序；明确结果/内存有界于 limit、直接子项过滤走 `nodes_by_parent`，但有效权重排序可能需要检查全部直接子项，不是常数时间。
- 新增 AppSupport 回归测试：失败后取消选择保持 `.failed` 与 path-free `rootUnavailable`；完成后取消保持 `.completed`；挂起 picker 期间的第二次 `chooseRoot()` 只调用一次 picker。
