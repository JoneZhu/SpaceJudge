# Phase 5C 验收基线：快照缓存自保护与异常恢复

状态：Accepted

日期：2026-09-27

## 1. 结论

Phase 5C 已完成 Codex 设计、真实本机 Pi 实施与三轮集中返修、以及 Codex 独立静态和动态验收。

SpaceJudge 的 SQLite 快照现在是单会话、单扫描的可再生成缓存：生产位置在 Foundation 返回的 `Caches/SpaceJudge`，下一次启动只清理严格白名单成员，新扫描在一个事务中替换旧扫描。扫描器会把自己的数据库与 spool 工作区保留为带标记的叶子边界，不枚举其中内容；根目录等于或经符号链接别名落入工作区时，在发布 `.started` 前拒绝。

缓存卷开始扫描前至少需要 512 MiB 有效可用空间，运行中至少需要 256 MiB；有效值包含 SQLite 可复用页。低空间、SQLite FULL/IOERR 和工作区异常都有路径脱敏的失败状态。取消超过宽限期时，runner 只会在 cancelled 终态成功落盘后通知 UI；落盘失败则 best-effort 标记 failed 并把错误交给界面，不会出现“界面已取消、数据库仍 running”的假状态。

实现没有加入扫描历史、书签、删除、清理建议、AI、网络、FSEvents、Sandbox、签名、公证或发布。

验收结果：通过。

## 2. 最终实现

### 2.1 受管工作区

- `SnapshotWorkspace.production()` 通过 Foundation 取得 Caches 位置；Debug override 只能指定绝对 `.sqlite` 测试路径。
- 根目录必须是真实目录，不能是符号链接；类型、权限或白名单成员无法安全确认时 fail-closed。
- 启动清理只处理 `snapshots.sqlite`、`snapshots.sqlite-wal`、`snapshots.sqlite-shm` 与严格命名的 spool 普通文件，不递归删除父目录或未知成员。
- 工作区收紧为 `0700`，数据库三件套预创建并复核为 `0600`；spool 也使用 owner-only 权限。
- 旧开发位置 `Application Support/SpaceJudge` 不做递归迁移或清理，避免扩大删除范围。

### 2.2 扫描自身排除

- `ScanRequest.workspaceExclusions` 是 session-only、有界且不持久化的集合，上限 8。
- 匹配优先使用 `(deviceID,fileID)`，事实缺失时使用规范化绝对路径；同名的其他目录不会被误排除。
- 工作区节点带 `NodeFlags.snapshotStorageBoundary = 1 << 10`，节点本身可见但 direct children 必须为 0。
- 工作区与 spool 共用同一边界；数据库、WAL、SHM 和队列文件不会进入扫描结果。
- 根目录预检同时比较词法路径与一次 canonical 解析，因此不能通过指向工作区后代的符号链接别名绕过。

### 2.3 单扫描保留与空间保护

- `SQLiteSnapshotRepository.begin` 在同一个事务里删除旧 `scans` 并插入新 header；空间门或插入失败会整体回滚，保留上一快照。
- 外键级联删除 names、nodes、directory aggregates 与 issues；任意时刻只保留一个 ScanID。
- 新库在建表前启用 `auto_vacuum=INCREMENTAL`；重扫优先复用 freelist 页面，不执行普通 `VACUUM`。
- 终态与关闭执行有界 checkpoint 和最多 256 页的 incremental vacuum；reader 阻塞 TRUNCATE 时允许退化，不把已完成扫描改成失败。
- 空间门使用饱和乘加；生产容量查询有 2 秒 TTL，避免每批 Foundation resource-values 查询在百万节点扫描中累积常驻内存，注入式测试 provider 保持即时。

### 2.4 取消一致性与错误可见性

- 普通 engine/store/stream 错误仍取消 engine、best-effort 标记 scan failed 并抛出原错误。
- 只有“Task 已取消、scan 已 started、尚无合法 terminal”才允许合成 cancelled summary。
- 合成 summary 先执行 `repository.finish`；只有成功后才能发布 `.terminal` 并返回成功。
- cancelled 持久化失败时不发布 terminal，尝试 `repository.fail` 并抛出持久化错误。
- `AppModel` 的 2 秒取消宽限期可注入测试；成功取消会清除旧 `userError`。
- footer 用一行、可截断、无路径文案展示 `AppUserError`，代码中的 accessibility identifier 为 `scan-error`。

## 3. Codex 审查与三轮返修

### 第一轮：文件系统边界与权限

Codex 静态审查发现三项阻断问题：工作区根符号链接会被跟随、指向工作区内部的符号链接扫描根能绕过预检、真实 SQLite 文件沿用默认权限而成为 `0644`。Pi 在原会话中改为 `lstat` 根、加入 canonical 根预检，并在 SQLite 打开前后把受管文件固定为 `0600`，补齐真实文件测试。

### 第二轮：真实取消与 UI 错误

Codex 启动真实 Debug App 扫描 `/` 后发现：engine 被阻塞时，AppModel 的强制 task cancel 会让数据库和界面进入 failed，而不是用户请求的 cancelled；同时 `AppUserError` 没有实际渲染。Pi 增加强制取消合成终态、可注入宽限期和 footer 错误行，并用真实 `/` 取消与工作区根拒绝复现验证。

### 第三轮：先持久化、后发布

Codex 再审查发现合成取消使用 `try? repository.finish`，持久化失败后仍可能向 UI 发布 cancelled。Pi 改为严格 persistence-before-publication，并新增 finish 失败回归测试。该轮之后没有剩余阻断级或高优先级问题。

## 4. Codex 独立自动验收

最终独立验收未复用 Pi 构建产物；大型 scratch 已在验收后回收，保留的测试、构建与基准日志位于 `/tmp/spacejudge-phase5c-pi.UeDfDw/codex-acceptance`。

| 检查 | 结果 |
| --- | --- |
| `arch -arm64 swift test` | 421 tests / 57 suites，通过 |
| Thread Sanitizer 关键过滤组 | 99 tests / 10 suites，通过，无 data race 报告 |
| Swift Release build | 通过 |
| Xcode Debug，`CODE_SIGNING_ALLOWED=NO` | `BUILD SUCCEEDED` |
| Xcode Release，`CODE_SIGNING_ALLOWED=NO` | `BUILD SUCCEEDED` |

TSan 覆盖 Store、runner、AppModel、snapshot/workspace 与 persistence integration。全量测试包含工作区白名单、symlink fail-closed、路径别名、单扫描级联、空间门边界、SQLite 错误映射、spool 生命周期、真实文件权限、强制取消和取消终态持久化失败。

## 5. Codex 独立规模与资源基准

环境与前序阶段相同：Apple Silicon，本机 SSD，Release，缓存状态未控制。基准在第一轮返修后独立运行；第二、三轮只修改 runner 取消收口和 UI 错误展示，没有改变 scanner、每节点模型或正常批次 Store 热路径。

| 场景 | scan + persist | 峰值 RSS | 主库 | WAL | fdDelta | persisted |
| --- | --- | --- | --- | --- | --- | --- |
| 100,000 mixed | 0.729484 s | 61,177,856 B | 27,725,824 B | 0 | 0 | 100,000 |
| 1,000,000 mixed | 13.363135 s | 240,222,208 B | 276,226,048 B | 0 | 0 | 1,000,000 |
| 100,000 cancel after first commit | 57.1675 ms cancel latency | 23,379,968 B | — | — | 0 | 10,000 |

100 万峰值低于 `250,000,000 B` 工程门，余量 `9,777,792 B`，约 9.8 MB。仍属于较小余量，后续增加任何每节点字段都必须重跑百万节点门。

Pi 的独立两次 20,000 节点重扫测得主库 `6,918,144 B -> 6,918,144 B` 且 `scan_count == 1`，证明旧页被复用而非按扫描次数线性翻倍。

## 6. Codex 真实 App 验收

使用最终 Debug 构建、任务专属数据库和 `SPACEJUDGE_TEST_ROOT_PATH=/` 启动真实 App：

- UI 显示根 `/`、`正在扫描`，总容量 994.66 GB、已用 949.08 GB、剩余 45.59 GB；
- SQLite 中找到 1 个 `snapshotStorageBoundary` 节点，direct children 为 0；
- 工作区为 `drwx------`，SQLite、WAL、SHM 均为 `-rw-------`；
- 点击真实 `cancel-scan` 按钮后约 3 秒，UI 变为 `已取消`，没有残留扫描错误，SQLite `scans.status = 3 (cancelled)`；
- 取消后进程仍可浏览，随后按精确 PID 终止，无残留进程。

第二次启动把扫描根设为工作区本身：

- UI 显示 `扫描失败` 与“不能扫描 SpaceJudge 自己的工作缓存，请选择其他位置。”；
- `scans` 行数为 0，证明在 `.started` 前拒绝；
- 测试进程按精确 PID 停止。

## 7. 已知限制

- 首次超大扫描仍可能触发 256 MiB 运行门；应用会停止并保留已提交部分，不承诺任何磁盘都能完整扫描。
- 生产容量查询使用 2 秒 TTL；极端快速的外部空间消耗可能在刷新间隔内发生，SQLite 自身错误仍是最终保护。
- incremental auto-vacuum 只对新库启用；不对旧开发库执行需要额外空间的全量迁移。
- 快照不是历史：重启后需要重新选择并扫描，新扫描会替换取消或失败的当前结果。
- 旧 `Application Support/SpaceJudge` 开发缓存不会自动递归清理。
- Debug 数据库 override 假设使用任务专属父目录；未知邻居会 fail-closed，不能把任意共享目录当测试工作区。
- 仍没有 App Sandbox、签名、公证和正式分发恢复证据；这些属于 Phase 5D。
- APFS clone/snapshot 独占空间、云占位文件、权限不可见空间仍不能被解释为“可清理”。

## 8. 文档与阶段状态

- [Phase 5C 实施设计](20-phase-5c-design.md)：Accepted。
- [ADR-0009](adr/0009-session-snapshot-cache.md)：Accepted。
- Pi 原始交付：[Phase 5C Pi 交付报告](phase-5c-pi-report.md)。
- 原始 Pi 会话：`/tmp/spacejudge-phase5c-pi.UeDfDw/sessions/2026-09-27T04-44-01-759Z_01a0e12d-5d5d-7751-b17e-f910eeca2a08.jsonl`。
- 未 commit、未 push、未签名、未公证、未发布。
- 下一阶段：Phase 5D，先决定直接分发方式与开发者身份，再设计签名、公证、权限引导和发布级恢复；仍不自动加入删除或 AI。
