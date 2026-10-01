# Phase 6 大目录事件乱序修复 Pi 报告

状态：Pi 实现与自测完成；Codex 已独立验收通过

日期：2026-09-28

基线：`master`，起始 HEAD `43f55d8bc80e`（`feat: establish SpaceJudge MVP baseline`），工作树保留 Phase 6 CLI/MCP 既有未提交成果。

环境：Apple M1 Max / 64 GiB / macOS 26.6.2（25G83），宿主 shell `uname -m = x86_64`（Rosetta），Swift 6.3.3（target `arm64-apple-macosx26.0`），Node v22.23.2。

设计依据：[Phase 6 真实大目录可靠性修复设计](27-phase-6-scale-reliability-fix.md)、[Phase 6 真实整机扫描观察](26-phase-6-real-machine-scan.md)、[Phase 1 设计](08-phase-1-design.md)、[测试与验收](05-testing-and-acceptance.md)。

Codex 最终验收与修复版安装、主目录及 `/` 真实扫描证据见 [Phase 6 大目录事件顺序修复验收基线](28-phase-6-scale-fix-baseline.md)。

## 1. 结论

`FileSystemScanEngine` 在满 event buffer 下的 actor 重入乱序已修复。所有 `ScanEvent` 投递现在经过 `ScanCoordinator` 内的单写者 FIFO 事件门：投递在第一次 `continuation.yield` 前取得唯一所有权，满缓冲重试期间持续持有，release 时把所有权直接交给队首等待者，不留插队窗口。

确定性回归在修复前稳定复现乱序（revision `[1, 2, 6, 5, 8, …]`）与持久化 `revisionNotContiguous`，修复后 targeted 测试连续 20 次通过、全量 Swift 与 Node/MCP 回归通过、Release `spacejudge-persist-smoke` 对真实 `/Users/example/workspace` 用 bulk 与 reference engine 均 `completed` 且可重开查询。

## 2. 根因

`ScanCoordinator.emit` 在 `continuation.yield` 返回 `.dropped`（有界 `bufferingOldest` 缓冲已满）时执行 `try? await Task.sleep(...)` 后重试。`ScanCoordinator` 是 actor，该 `await` 打开重入窗口：另一个 worker 可以进入 `flush()` 分配更高的 `revision` 并成功 `yield`，于是消费者先看到较晚 batch，再看到较早 batch。`SQLiteSnapshotRepository.write` 严格校验 revision 连续，随即以 `revisionNotContiguous(expected: 284, found: 286)` 拒绝写入。

缺口仅存在于事件投递顺序，与目录枚举、权限、聚合或 SQLite 完整性无关；失败库 `integrity_check = ok`。

## 3. 修复结构

在 `ScanCoordinator` 增加仅保存等待 continuation 的门状态（不复制 batch、不新增事件队列）：

- `emitOwnershipHeld: Bool`、`emitWaiters: [CheckedContinuation<Void, Never>]`。
- `acquireEmitOwnership()`：门空闲则直接取得；否则把自己按到达顺序挂到队尾等待。actor 串行化保证入队顺序即投递发起顺序。
- `releaseEmitOwnership()`：队空则置空闲；否则**保持持锁**并把所有权直接 `resume` 给队首。新到的 `emit` 只能排到已有等待者之后，不存在“先置空闲再唤醒”的插队窗口。
- `emit` 以 `await acquireEmitOwnership(); defer { releaseEmitOwnership() }` 包裹原有重试循环。

保持的不变量：

1. 门只序列化投递，不改变 `flush()` 内 revision 分配（在同一同步段内分配后立即 `emit`），因此 revision 发射顺序等于分配顺序。
2. `.dropped` 重试期间持有所有权；`.terminated` 或 cancel 丢弃非 terminal 事件时经 `defer` 释放，后续等待者依次快速观察终止并退出，不死锁、不泄漏 continuation。
3. 非 terminal 事件取得门后再次检查 `cancelled`；terminal 不受 `cancelled` 跳过。
4. 等待队列上界受并发 producer 数约束（默认 worker ≤ 4），不缓存 batch，stream 仍为 `.bufferingOldest(configuration.eventBufferSize)`。
5. 未放宽 SQLite revision 连续性校验，未改公开 CLI/MCP schema、DB schema、计量/边界/权限，未固定单 worker。

## 4. 修改文件

- `Sources/SpaceJudgeScan/FileSystemScanEngine.swift`（+42 行）：单写者 FIFO 事件门。
- `Tests/SpaceJudgeScanTests/FollowupRegressionTests.swift`（+138 行）：两个新回归。
  - `concurrentWorkerBackpressureKeepsRevisionOrder`：4 workers、`eventBufferSize = 1`、`batchNodeLimit = 20`、8 个子目录 × 300 文件、消费者暂停 600 ms；断言 revision 精确 `1...N`、节点 2409 个、name 原子可见、唯一 terminal、terminal 后无 batch。
  - `cancelWithFullBuffer`：缓冲已满且有 emitter 等待时 cancel；断言 2 s 内唯一 `cancelled` terminal、terminal 最后、无 batch 越界、FD/spool 回收、diagnostics 可消费。
- `Tests/SpaceJudgeUseCaseTests/ScanPersistenceIntegrationTests.swift`（新增）：真实 `FileSystemScanEngine` + `PersistingScanRunner` + `SQLiteSnapshotRepository`，4 workers / buffer 1 / 2000 文件；未加入任何人工 delay——一条 buffer 槽配合 SQLite 持久化消费者本身即形成背压。测试记录成功写入的 batch revision 并断言 `1...N`，随后用 `SQLiteSnapshotRepository.openReadOnly(path:)` 只读连接重开，核对 status、`lastRevision`、节点/名字/聚合计数、根 children 与根 aggregate。

## 5. 测试证据

所有命令在 `/Users/example/Documents/ChatGPT/SpaceJudge` 下执行；日志见 `/tmp/spacejudge-scale-fix-pi.8jahAE/logs/`。

### 5.1 修复前复现（临时移除门，随后已还原）

- 引擎回归：`swift test --filter concurrentWorkerBackpressureKeepsRevisionOrder`，5/5 次失败。示例 `revisions = [1, 2, 6, 5, 8, 9, …]`，并出现 60 个 name 原子性违规（后续 batch 引用尚未发布的 name）。
- 持久化回归：`swift test --filter concurrentBackpressurePersistsContiguousSnapshot`，3/3 次失败，错误 `.revisionNotContiguous(expected: 1, found: 5)`，与生产 `expected: 284, found: 286` 同类。

### 5.2 修复后 targeted 连续 20 次

命令：

```
swift test --filter "concurrentWorkerBackpressureKeepsRevisionOrder|cancelWithFullBuffer|concurrentBackpressurePersistsContiguousSnapshot|slowConsumerBackpressure"
```

结果：`PASS=20 FAIL=0`（4 个测试 × 20 轮全部通过），日志 `logs/targeted-20x.log`。

### 5.3 全量 Swift

```
arch -arm64 swift test
```

结果：`Test run with 437 tests in 60 suites passed`，退出码 0，日志 `logs/swift-test-full-arm64.log`。

注：宿主 shell 报 `x86_64`，直接 `swift test` 时 SwiftPM 的 xctest `dlopen_preflight` 因架构（bundle `arm64` vs 宿主 `x86_64`）打印一次警告并返回 1，但同一轮所有 437 个测试仍全部通过（日志 `logs/swift-test-full.log`）。按仓库/设计约定使用 `arch -arm64 swift test` 得到退出码 0。

### 5.4 Node / MCP

```
cd AgentMCP && npm test
```

结果：`# tests 31 / # pass 31 / # fail 0`，退出码 0，日志 `logs/agentmcp-npm-test.log`。

### 5.5 Release 真实 `workspace` 持久化

```
arch -arm64 swift build -c release --product spacejudge-persist-smoke
.build/release/spacejudge-persist-smoke --engine <bulk|reference> --database <tmp>/workspace-smoke[-ref].sqlite /Users/example/workspace
```

| 指标 | bulk | reference |
| --- | ---: | ---: |
| 退出码 / status | 0 / `completed` | 0 / `completed` |
| fileCount | 639,383 | 639,383 |
| directoryCount | 55,444 | 55,444 |
| issueCount / inaccessible | 0 / 0 | 0 / 0 |
| persistedNodes | 694,827 | 694,827 |
| persistedNames | 287,523 | 287,523 |
| persistedAggregates | 55,444 | 55,444 |
| rootChildCount | 14 | 14 |
| rootAttributedBytes | 146,673,266,688 | 146,673,266,688 |
| lastRevision（重开查询） | 351 | 352 |
| databaseBytes | 211,984,384 | 211,890,176 |
| wall (real) | 9.88 s | 10.90 s |
| user / sys | 5.13 / 8.46 s | 5.68 / 15.25 s |
| 峰值 RSS | 187,842,560 B（≈179 MiB） | 137,838,592 B（≈131 MiB） |
| peak memory footprint | 177,193,632 B | 未单列 |

重开查询（全新进程，`build/release/spacejudge-agent-cli`）：

- `status`：`status=completed`、`nodeCount=694827`、`fileCount=639383`、`directoryCount=55444`、`lastRevision=351/352`、`rootAttributedBytes=146673266688`、`issueCount=0`。
- `children --node-id 1 --limit 5`：`totalCount=14`、`snapshotRevision` 与 lastRevision 一致。
- `issues`：`categories=[]`、`samples=[]`。
- `PRAGMA integrity_check`：两个库均为 `ok`。

对照原始故障（同一 workspace，修复前 `expected: 284, found: 286`），修复后两种 engine 都形成唯一持久化终态且无 revision gap。

## 6. 资源与性能

- Release bulk 端到端（扫描 + SQLite + 重开查询）：9.88 s，峰值 RSS ≈179 MiB，DB ≈202 MiB，137 GB workspace、69.5 万节点。
- 内存未见随规模异常增长；等待队列只保存 continuation，未复制 batch，未引入第二事件缓冲。
- 修复只增加每个投递一次门获取/释放与可能的 continuation 挂起，热路径无额外 I/O；两台 engine 与既有 Phase 6 基线同量级。
- 未控制冷/热缓存；以上为本机单次 Release 观测，不是跨机器承诺。

## 7. 限制与未验证项

- 真实 `/` 与用户主目录整盘扫描、重新构建并临时安装 CLI/MCP、以及修复前后速度/精度对比属于 Codex 独立验收范围，本次未执行。
- 未运行 Thread Sanitizer；本任务只做 Release 观测与确定性并发回归。
- 本次真实 workspace 未在“修复前代码”上重跑整盘失败以复刻 `expected: 284, found: 286`（原始证据由 handoff 提供）；改用确定性合成回归证明修复前可稳定复现同类错误。
- 未测固定 `workerCount = 1` 之外的极端调度饥饿；门等待队列上界由“每 worker 同时最多一个未完成 emit”保证。

## 8. 临时产物与后台服务

- 临时大库 `workspace-smoke.sqlite` 与 `workspace-smoke-ref.sqlite`（各约 202 MiB）在取证后已删除；`/tmp` 上无遗留 `spacejudge-spool-*`。
- 无遗留 `spacejudge` / `SpaceJudge` 进程；无后台服务、无监听端口。
- 运行日志保留在任务目录 `/tmp/spacejudge-scale-fix-pi.8jahAE/logs/`，未提交进仓库。
- 为复现临时移出的门代码随后从任务目录备份精确还原（`grep -c acquireEmitOwnership = 2`）。

## 9. Git 改动范围

本任务仅改动/新增：

- `M Sources/SpaceJudgeScan/FileSystemScanEngine.swift`
- `M Tests/SpaceJudgeScanTests/FollowupRegressionTests.swift`
- `?? Tests/SpaceJudgeUseCaseTests/ScanPersistenceIntegrationTests.swift`

未提交、未打 tag、未 push、未发布、未修改用户全局 MCP 配置。工作树中其余 `M`/`??`（`.gitignore`、`Package.swift`、`docs/05`、`docs/06`、`docs/README`、`docs/references`、`AgentMCP/`、`Sources/SpaceJudgeAgentCLI*`、`Tests/SpaceJudgeAgentCLITests/`、`docs/24-27`、`docs/phase-6-*`、`docs/adr/0011`、`docs/runbooks/local-agent-mcp.md`）均为 Phase 6 既有未提交成果，语义未改。
