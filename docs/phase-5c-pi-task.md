# Phase 5C Pi 实施任务单

目标：完整实现 [Phase 5C 设计](20-phase-5c-design.md) 和 [ADR-0009](adr/0009-session-snapshot-cache.md)，使快照缓存不会扫描自身、不会跨扫描/启动无界增长，并在低磁盘空间时安全停止。

工作位置：`/Users/hongdazhu/Documents/ChatGPT/SpaceJudge`，当前 checkout 与工作树。仓库当前大量文件尚未提交，全部视为用户成果。

分工：Pi 负责产品代码、测试、必要文档同步、自测和普通修复；Codex 负责既定设计、独立审查和验收。不要 commit、push、签名、公证、发布或更改 Pi/Codex 全局配置。

## 必须先读

1. `docs/20-phase-5c-design.md`
2. `docs/adr/0009-session-snapshot-cache.md`
3. `docs/19-phase-5b-baseline.md`
4. `docs/04-data-and-storage.md`
5. `App/SpaceJudgeApp/AppDelegate.swift`
6. `Sources/SpaceJudgeDomain/ScanModel.swift`
7. `Sources/SpaceJudgeScan/FileSystemScanEngine.swift`
8. `Sources/SpaceJudgeScan/DirectorySpool.swift`
9. `Sources/SpaceJudgeStore/SQLiteSnapshotRepository.swift`
10. `Sources/SpaceJudgeAppSupport/AppModel.swift` 与 `AppState.swift`

## 已冻结决策

- 单会话、单扫描缓存；下一次 begin 替换旧 scan，下次启动清理受管缓存。
- 生产位置是 Foundation 返回的 `Caches/SpaceJudge`，不是硬编码路径。
- 白名单清理，不递归删除工作区或父目录；不跟随 symlink。
- SQLite、WAL、SHM 和 spool 同属一个排除工作区。
- session-only 有界排除集合；工作区节点保留为 `snapshotStorageBoundary = 1 << 10` 叶子。
- 根落在工作区内时，在 `.started` 前失败。
- 开始门 512 MiB，运行门 256 MiB；有效可用量包含可复用 SQLite 页；unknown 不伪造。
- 新库在建表前启用 incremental auto-vacuum；禁止普通 `VACUUM`。
- 关闭顺序 reader 在 writer 前，writer 做有界 checkpoint。
- 不新增删除用户文件、AI、网络、历史、书签、签名或发布功能。

## 可自主决定

- 类型和文件命名、测试 double 组织、checkpoint/incremental vacuum 的小批页数；
- 在不改变阈值与语义的前提下，将 workspace 放在 Store 或 AppSupport；
- 排除匹配的内部数据结构，只要 identity 优先、路径 fallback、有界且不增加每节点常驻字段。

## 特别安全边界

- 不得运行清理真实用户 Caches/Application Support 的手工命令；所有清理测试使用任务专属临时目录。
- 不得用 `rm -rf`、宽泛 glob、`killall` 或 `pkill -f`。
- 删除测试必须证明相邻文件、目录和 symlink 未受影响。
- 错误、日志、报告不得写入真实完整用户路径。
- 只管理本任务创建且 PID 已知的进程。

## 必须完成的验证

- Phase 5C 设计第 8 节全部自动测试；
- `arch -arm64 swift test`；
- Release build；
- Store/runner/AppModel/scan exclusion 的 TSan 过滤测试；
- Xcode Debug/Release `CODE_SIGNING_ALLOWED=NO`；
- 10 万与 100 万 mixed 端到端基准，100 万 RSS < 250,000,000 B；
- 连续两次同规模扫描证明 `scan_count == 1` 且数据库不线性翻倍；
- 任务专属 Debug App `/` smoke，查询工作区边界 direct children 为 0，且数据库中没有 sqlite/wal/shm/spool 子节点；
- 所有任务 PID 停止，临时产物可由 Codex安全回收。

若完整 `/` smoke 耗时过长，可在工作区边界已出现并持久化后取消，不必等待全盘完成。若 100 万门失败，不得降低规模或阈值；报告真实数字和瓶颈。

## 文档与交付

- 更新 `docs/02-system-architecture.md`、`03-scan-engine.md`、`04-data-and-storage.md`、`05-testing-and-acceptance.md` 中受影响内容。
- 交付 `docs/phase-5c-pi-report.md`，包含修改、命令、退出码、测试数、基准、真实 smoke、限制、服务/PID、Git 状态。
- 原始日志放任务专属 `/tmp`，报告只引用路径；完成整个阶段并修复普通错误后统一交付。
