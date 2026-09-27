# Phase 5C Pi 交付报告：快照缓存自保护与异常恢复

状态：Pi 实施与自测完成；Codex 已独立验收，最终结论见 [Phase 5C 验收基线](21-phase-5c-baseline.md)。
日期：2026-09-27
工作位置：`/Users/hongdazhu/Documents/ChatGPT/SpaceJudge`（工作树，未 commit）
原始日志目录：`/tmp/spacejudge-phase5c-pi.4KC9UY`
真实 smoke 目录：`/tmp/spacejudge-phase5c-smoke.JkeEXh`（最终一次；此前一次为 `d3O18F`）

## 1. 实现范围

实现 [Phase 5C 设计](20-phase-5c-design.md) 与 [ADR-0009](adr/0009-session-snapshot-cache.md)：快照缓存不再扫描自身，不跨扫描/启动无界增长，低空间时安全停止。未加入删除用户文件、AI、网络、历史、书签、签名、公证或发布功能。

### 1.1 新增

- `Sources/SpaceJudgeDomain/SnapshotWorkspaceExclusion.swift`：session-only、单值可 Codable 的排除项、原因枚举，以及纯路径规范化/包含判定。
- `Sources/SpaceJudgeScan/SnapshotWorkspaceExclusionSet.swift`：有界匹配器（identity 优先、规范化路径兜底、根包含判定）。
- `Sources/SpaceJudgeStore/StorageSpace.swift`：512/256 MiB 门策略、`StorageCapacityProviding`、生产 Foundation provider（带短 TTL 缓存）、纯饱和算术与门决策。
- `Sources/SpaceJudgeAppSupport/SnapshotWorkspace.swift`：工作区路径/生命周期、白名单两阶段清理、`0700` 收紧、session-only 排除项、无路径错误 `SnapshotWorkspaceError`。
- 测试：`SnapshotWorkspaceTests`、`SnapshotRetentionSpaceTests`、`SnapshotWorkspaceBoundaryTests`、`Phase5CAppTests`。

### 1.2 修改

- `ScanModel.swift`：`ScanRequest` 新增 `workspaceExclusions`（上限 8）与相关常量；`NodeModel.swift` 新增 `NodeFlags.snapshotStorageBoundary = 1 << 10`。
- `VolumeScanPlan.makeScanRequest` 透传排除集合。
- `ScanConfiguration`：新增 `spoolDirectory`；`DirectorySpool` 支持指定目录并公开 `ManagedSpoolNaming` 白名单命名。
- `FileSystemScanEngine`：根等于/位于工作区内时在 `.started` 前失败；排除数量超限失败；枚举到工作区目录时保留 `snapshotStorageBoundary` 叶子且不入队；使用配置的 spool 目录。
- `SQLiteSnapshotRepository`：新库 `auto_vacuum=INCREMENTAL`；`begin` 在同一事务内 `DELETE FROM scans` 后做开始门并插入新 header（失败回滚保留旧快照、无伪 running 行）；`write` 每批运行门；终态/关闭做有界 `wal_checkpoint(TRUNCATE→PASSIVE)` 与单次 256 页 `incremental_vacuum`；空间探测与 SQLITE_FULL/IOERR 分类。
- `AppState.swift`：`AppUserError` 新增 `insufficientStorage`、`scanRootInsideSnapshotWorkspace` 与分类逻辑。
- `AppModel.swift`：携带并传入工作区排除集合。
- `AppDelegate.swift`：改为 Foundation `Caches/SpaceJudge` 工作区；启动清理；engine 使用工作区 spool 目录；模型注入工作区排除项；Debug override 只控制指定数据库；关闭顺序为 reader 先于 writer。
- 文档：`02-system-architecture.md`、`03-scan-engine.md`、`04-data-and-storage.md`、`05-testing-and-acceptance.md`。
- 既有测试 `SnapshotChildPageTests` 的跨扫描共存用例改为符合单扫描保留契约（旧快照在下次 begin 后消失）。

### 1.3 Pi 返修（第一轮反馈）

1. **工作区根 symlink 不再被跟随**：`SnapshotWorkspace.ensureRootDirectory()` 改用不跟随的 `lstat`；root symlink 报 `workspaceRootSymbolicLink`，非目录报 `workspaceRootNotDirectory`，类型无法确认或权限属性不可读写报 `workspaceUnavailable`/`workspacePermissionsUnavailable`，均在任何枚举/删除之前失败。目录权限属性无法读取不再静默成功。
2. **工作区内部 symlink 别名被拒绝**：`SnapshotWorkspacePath.canonical` 在根预检时解析一次 canonical 路径；`SnapshotWorkspaceExclusionSet` 在构建时一次性解析各排除项路径。根等于工作区或位于其后代（含通过 symlink 别名间接指向）都会在 `.started` 前以 `scanRootInsideSnapshotWorkspace` 失败。解析不进每节点热路径；`SnapshotWorkspaceExclusion` 自身仍是词法路径，路径 fallback 语义不变。
3. **受管数据库文件 0600**：新增 `SnapshotWorkspace.prepareDatabaseFiles()`（在 repository 打开前以 0600 预创建/收紧三件套，使 SQLite 采用而非自行创建 WAL/SHM）与 `tightenDatabaseFilePermissions()`（打开后安全网）。已存在但不是普通文件时 fail-closed；App bootstrap 在 detached I/O 路径调用两者，不使用进程全局 umask。

### 1.4 关键设计取舍

- 工作区放在 `SpaceJudgeAppSupport`，只持有路径和文件生命周期；SQLite/Spool 各自仍由 Store/Scan 负责。
- 排除匹配集合最多 8 项，仅存在于 coordinator，不增加每节点常驻字段。
- 生产卷容量 provider 使用 2 秒 TTL 缓存。运行门仍然每批评估（复用页 + 缓存的卷可用量）。原因见 §5：朴素地每批调用 `URL.resourceValues` 会把 100 万扫描峰值 RSS 推高约 20 MB，超出既有门。注入测试 provider 不缓存，边界测试保持即时。

### 1.5 Pi 返修（第二轮反馈）

1. **强制取消不再记为失败**：`AppModel.cancelAndWait` 在宽限期（默认 2 秒，可注入）后取消 runner task；`PersistingScanRunner.run` 现在区分“Task 已取消 + 已 started + 无合法 terminal”与其他错误。前者基于最后进度、已持久化 issue、started metadata 合成 `cancelled` summary，调用 `repository.finish(.cancelled)` 并发布 terminal；后者（store/stream 错误、正常 EOF 无 terminal）仍调用 `repository.fail`。`AppModel.finishScan` 成功路径清空 `userError`。
2. **AppUserError 在 ContentView 可见**：footer 新增一行紧凑、可截断、可访问的 `model.userError?.message` 文本，`accessibilityIdentifier = scan-error`，与权限按钮可共存；不引入大面板或完整路径。

新增回归测试：runner 层 `HoldingEngine`（接受 cancel 但不发 terminal）+ 强制取消 consumer 验证 `finish(.cancelled)` 且无 `fail`；AppModel 层注入 `cancelGracePeriod: 0.15` 验证 phase/summary 为 cancelled、`userError == nil`；存储失败仍 `failed` 且 `userError == .insufficientStorage`。

### 1.6 Pi 返修（第三轮反馈：终态持久化后才发布）

强制取消路径原先用 `try?` 忽略 `repository.finish` 失败，仍发布 cancelled terminal，可能在 UI 显示“已取消”时数据库仍为 running。现改为严格的“先持久化、后发布”：

- 仅在 `repository.finish(summary)` 成功后 `onUpdate(.terminal(summary))` 并返回该 summary；
- 若持久化失败，不发布任何 terminal cancelled 更新，best-effort 调用 `repository.fail(scanID:)`，并抛出持久化错误，让 App 报告失败而不是谎称取消；
- class 文档已更新：普通错误仍始终 rethrow；强制用户取消是唯一例外，且仍以终态持久化为前提。

新增 `PersistingScanRunnerTests` 回归：`failFinish` repository + `HoldingEngine` + 强制取消，断言 runner 抛出持久化错误、未发布任何 `.terminal`、且已尝试 `fail(scanID:)`。

## 2. 自动测试

| 检查 | 命令 | 退出码 | 结果 |
| --- | --- | --- | --- |
| 全量 Swift 测试 | `arch -arm64 swift test` | 0 | 421 tests / 57 suites 通过 |
| Thread Sanitizer（Store/runner/AppModel/scan exclusion） | `arch -arm64 swift test --sanitize=thread --filter "PersistingScanRunnerTests\|Phase5CAppTests\|Snapshot\|Workspace\|PersistenceIntegration"` | 0 | 98 tests / 10 suites 通过，无 data race 报告 |
| Release build | `arch -arm64 swift build -c release` | 0 | Build complete |
| Xcode Debug | `xcodebuild ... -configuration Debug CODE_SIGNING_ALLOWED=NO build` | 0 | BUILD SUCCEEDED |
| Xcode Release | `xcodebuild ... -configuration Release CODE_SIGNING_ALLOWED=NO build` | 0 | BUILD SUCCEEDED |

原始日志：

- `swift-test-final4.log`、`fix1-full-test.log`、`fix2-full-test.log`、`fix2-affected.log`、`fix3-full-test.log`
- `tsan-final.log`、`fix2-tsan.log`、`fix3-tsan.log`
- `release-build-final.log`、`fix1-release.log`、`fix2-release.log`、`fix3-release.log`
- `xcode-Debug.log`、`xcode-Release.log`、`fix2-xcode-Debug.log`、`fix2-xcode-Release.log`、`fix3-xcode-Debug.log`、`fix3-xcode-Release.log`

### 2.1 设计第 8 节覆盖

- 8.1 Workspace：白名单三件套 + 合法 spool 删除、相邻文件/子目录/符号链接/近似名 fail-closed、幂等、Debug override 不删父目录、`0700`。
- 8.2 Store：第二次 begin 级联清空四张子表、终态在下一次 begin 前可查询、被拒 begin 保留旧快照、`auto_vacuum=INCREMENTAL`、开始/运行门下等于上边界、unknown、乘加溢出、SQLITE_FULL/IOERR 分类、低空间失败后 scan 仍 running。
- 8.3 Scanner/App：工作区叶子直系子为 0、同名不同路径不误排除、identity 缺失路径 fallback、根等于/位于工作区在 `.started` 前失败、超限失败、工作区 spool 生命周期、两个新错误文案无路径。
- 8.4 回归：见 §3、§4。连续两次同规模扫描 `scan_count == 1` 且主库不增长。
- 返修补充：root symlink/非目录/类型或权限不可确认 fail-closed 且不删目标；真实 SQLite writer+reader 后三件套无 group/other bits；被加宽的文件可被收紧；受管成员为 symlink 时 fail-closed；真实 symlink 指向 `ws/inner` 的扫描在 `.started` 前被拒绝且保留祖先扫描在工作区叶子截断的既有行为。
- 第二轮返修：无 terminal 的强制取消写入 `cancelled` 且不 `fail`；普通 store/stream 错误仍 failed；AppModel 注入短宽限期后 phase/summary 为 cancelled 且无残留 `userError`；存储失败时 `userError` 为路径-free 文案。
- 第三轮返修：强制取消只有在 `finish(.cancelled)` 成功后才会发布/返回 terminal；持久化失败时抛出错误、不发布 terminal、best-effort `fail`。

## 3. 端到端基准（Release，本机 SSD，混合树，缓存未控制）

| 场景 | scan+persist | 峰值 RSS | 主库 | WAL | fdDelta | persisted |
| --- | --- | --- | --- | --- | --- | --- |
| 100,000 mixed | 0.7244 s | 61,374,464 B | 27,729,920 B | 0 | 0 | 100,000 |
| 1,000,000 mixed | 14.0174 s | 238,747,648 B | 276,316,160 B | 0 | 0 | 1,000,000 |
| 100,000 cancel after first commit | — | — | — | — | 0 | 10,000，取消延迟 57.72 ms，status cancelled |

- 100 万峰值 RSS `238,747,648 B < 250,000,000 B` 门，余量约 11.3 MB。Phase 5B 基线为 243,892,224 B，未回退。
- WAL 在关闭后为 0，说明有界 checkpoint 生效。
- 原始 JSON：`final-bench-100k-b.json`、`final-bench-1m-b.json`、`final-bench-cancel.json`。

### 3.1 单扫描保留与页复用

Store 级两次同规模扫描（各 20,000 节点）测量：

```text
phase5c two-scan main bytes: first=6918144 second=6918144
```

`scan_count == 1`，主库未翻倍。

## 4. 真实 Debug App `/` smoke

- 任务专属 Debug App：Xcode derived data `dd-Debug`（最终构建，返回修后）；任务专属数据库 `/tmp/spacejudge-phase5c-smoke.EL02LD/ws/snapshots.sqlite`。
- 环境：`SPACEJUDGE_TEST_ROOT_PATH=/`、`SPACEJUDGE_TEST_DATABASE_PATH=<task dir>`。
- 启动 PID：71490。
- 查询结果（`boundary.json`）：

```json
{"scanID":"41B01611-DCAF-452E-AC54-76644D0F8AE7","boundaryNodeID":11251,"boundaryDirectChildren":0,"forbiddenChildNodes":0,"status":0}
```

- scan header：`root_display_name='/'`、`boundary_policy=2`（visibleStartupVolumeGroup）、status=running。
- 边界节点名 `ws`，direct children 为 0；数据库中不存在其 `snapshots.sqlite`、`-wal`、`-shm`、`spool` 子节点。
- 受管文件权限：`snapshots.sqlite`、`snapshots.sqlite-wal`、`snapshots.sqlite-shm` 均为 `-rw-------`（0600），工作区目录 `drwx------`（0700）。
- 未等待全盘完成：在工作区边界出现并持久化后即按精确 PID 终止。PID 71490 已停止，无残留 SpaceJudge 进程。

### 4.1 真实 `/` 点击取消（第二轮返修验证）

- 任务专属 Debug App（`dd-Debug` 返回修后），数据库 `/tmp/spacejudge-phase5c-cancel.DKKB36/ws/snapshots.sqlite`，DEBUG 启动 PID 87380。
- 通过 System Events 定位 `AXIdentifier == "cancel-scan"` 的按钮并真实点击。
- 点击后约 4 秒：SQLite `scans.status = 3 (cancelled)`，`last_revision = 975`，已提交 1,243,404 files / 451,053 dirs；进程仍存活且可浏览。
- accessibility 事实：`scan-status = 已取消`；footer 无 `scan-error` 元素；attribution 行显示“当前范围（未完成）”。
- AppleEvent quit 后 PID 87380 已停止，无残留。

### 4.2 真实工作区根拒绝文案（第二轮返修验证）

- 任务专属 Debug App，`SPACEJUDGE_TEST_ROOT_PATH` 设为工作区根 `ws`（与 `SPACEJUDGE_TEST_DATABASE_PATH` 同目录），PID 88534，`/tmp/spacejudge-phase5c-error.x1J5zX`。
- accessibility 事实：`scan-status = 扫描失败`，`scan-error = 不能扫描 SpaceJudge 自己的工作缓存，请选择其他位置。`
- 数据库 `scans` 行数为 0，证明在 `.started` 前拒绝。
- quit 后 PID 88534 已停止，无残留。

## 5. 内存瓶颈与修复记录

- 初次 100 万基准峰值 264,257,536 B，超出 250 MB 门。
- 分段测量显示 fixture 生成后约 8 MB，scan+persist 峰值约 242 MB；`close()` 维护不是主因。
- 关闭 per-batch 的 Foundation 卷查询后，100k 峰值从约 65 MB 回到约 60 MB，1M 回到约 240 MB。结论：每批调用 `URL.resourceValues` 会累积约 5 MB/100k、约 20 MB/1M 常驻内存（`autoreleasepool` 不能消除）。
- 修复：仅生产 `VolumeStorageCapacityProvider` 对卷查询加 2 秒单调时钟 TTL；运行门仍每批评估，复用页每批重算；注入 provider 不缓存。最终 1M RSS 238,747,648 B。

## 6. 已知限制

- 首次超大扫描仍可能因缓存增长触及 256 MiB 运行门并提前失败；保留已提交部分，状态为失败并提示“缓存空间不足”。这是保护行为，不伪装完成。
- 增量 auto-vacuum 只在新建数据库时选择；Phase 5C 不迁移旧库的 auto_vacuum 模式（不执行全量 VACUUM）。
- 启动清理 fail-closed：工作区根为符号链接、工作区内出现未知文件/目录/符号链接时拒绝启动，而不是扩大删除范围或静默跳过。
- 受管三件套在 repository 打开前以 0600 预创建并在打开后收紧；进程内不删除 WAL/SHM，因此权限不会在会话中恢复为更宽。若外部进程删除了它们，下次扫描新建时由 repository 常规写入创建，App 下次启动 bootstrap 会再次预创建并收紧。
- 旧开发位置 `Application Support/SpaceJudge` 未自动递归清理；按设计中“已知限制”处理。
- workspace 清理测试与真实 smoke 均使用任务专属临时目录，未触碰真实用户 Caches/Application Support。

## 7. 服务、进程与临时产物

- 无后台服务、端口或常驻进程。
- 本任务创建并停止的 App PID：87380、88534、71490、63940、53456（五次 smoke）。
- 临时产物：`/tmp/spacejudge-phase5c-pi.4KC9UY`（日志、derived data、基准 JSON）、`/tmp/spacejudge-phase5c-smoke.EL02LD`、`/tmp/spacejudge-phase5c-smoke.JkeEXh`、`/tmp/spacejudge-phase5c-smoke.d3O18F`、`/tmp/spacejudge-phase5c-cancel.DKKB36`、`/tmp/spacejudge-phase5c-error.x1J5zX`（smoke 数据库与输出），可由 Codex 安全回收。
- 未使用 `rm -rf`、宽泛 glob、`killall` 或 `pkill -f`。

## 8. Git 状态

- 仓库 `master` 无任何 commit；工作树全部文件为未跟踪（`??`）。
- 未 commit、未 push、未签名、未公证、未发布。
- 未修改 Pi/Codex 全局配置。

## 9. 交付清单

- 代码与测试：见 §1。
- 文档同步：`docs/02-system-architecture.md`、`docs/03-scan-engine.md`、`docs/04-data-and-storage.md`、`docs/05-testing-and-acceptance.md`。
- 本报告：`docs/phase-5c-pi-report.md`。
- 原始日志：`/tmp/spacejudge-phase5c-pi.4KC9UY`。
- [Phase 5C 设计](20-phase-5c-design.md) 与 [ADR-0009](adr/0009-session-snapshot-cache.md) 已在 Codex 独立验收后转为 Accepted。
