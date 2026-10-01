# Phase 6 真实大目录可靠性修复设计

状态：Accepted（revision 乱序修复）；内存扩展性另案 Open

日期：2026-09-28

独立验收结果见 [Phase 6 大目录事件顺序修复验收基线](28-phase-6-scale-fix-baseline.md)。

## 1. 结论

真实大目录失败的直接原因已经确认：`FileSystemScanEngine` 的事件流在有界缓冲区满时会等待并重试；等待期间 `ScanCoordinator` actor 可重入，另一个 worker 能生成并成功发布更晚的 batch。结果是消费者可能先看到 revision 286，再看到 285。`SQLiteSnapshotRepository` 正确要求 revision 严格连续，因此以 `revisionNotContiguous` 拒绝写入，外层 CLI 再把它收敛为无路径的 `INTERNAL`。

这不是文件数上限、权限错误、目录聚合溢出或 SQLite 损坏。修复点位于扫描引擎的事件投递顺序。

## 2. 复现证据

同一静态目录 `/Users/example/workspace` 的对照结果：

| 路径 | 结果 |
| --- | --- |
| `spacejudge-scan-smoke`（扫描引擎，不落库） | `completed`；639,344 files、55,441 directories、0 issue |
| `spacejudge-persist-smoke`（扫描 + runner + SQLite） | 失败：`revisionNotContiguous(expected: 284, found: 286)` |
| 失败库完整性 | `PRAGMA integrity_check = ok`，last revision 为 284 |

因此失败位于 engine → runner → store 的事件顺序边界，而不是目录枚举。真实失败库在诊断完成后删除，不作为仓库资产保存。

## 3. 现有实现为何漏测

现有 `slowConsumerBackpressure` 已验证 event buffer 为 1 时不丢事件，但它使用：

- 单 worker；
- 单层文件；
- 主要由节点数阈值触发 flush。

单 worker 在等待投递时没有第二个 worker 进入 coordinator 生成后续 revision，因此无法触发 actor 重入乱序。真实目录使用最多四个 worker，并同时存在节点阈值 flush、时间窗口 flush、issue 和目录完成事件。

## 4. 必须保持的不变量

一个 scan 的所有公开 `ScanEvent` 必须满足单一、可线性化的 FIFO 顺序：

1. `started` 恰好一次且最先；
2. batch revision 严格为 `1...N`，不丢失、不重复、不乱序；
3. 与 batch 相关的 name、node、aggregate 仍在同一 batch 内原子发布；
4. issue、progress 与 batch 按 coordinator 发起投递的顺序被消费者观察；
5. terminal 恰好一次且最后；
6. cancel 后普通事件停止，terminal 仍可排到已有投递之后；
7. consumer termination 必须让所有等待投递者退出，不死锁、不残留 worker；
8. 有界 stream buffer 继续施加真实背压，不能改成无界缓冲来掩盖问题。

SQLite 的 revision 连续性检查不得放宽。它是发现本次数据丢失/乱序的正确保护，不是缺陷来源。

## 5. 修复设计

### 5.1 单写者事件门

在 `ScanCoordinator` 内为所有 continuation 投递增加一个 FIFO、可转移所有权的事件门：

- `emit` 在第一次 `continuation.yield` 前取得唯一投递权；
- 缓冲区满时，当前投递者持有投递权并重试；actor 即使重入，后续 `emit` 只能按进入顺序挂起；
- 当前事件完成、因 cancel 被丢弃或 continuation 已终止后，将所有权直接交给队首等待者；
- 队列为空时才把门设为空闲。

“直接交接所有权”是必要条件。若 release 先把门设为空闲、再唤醒等待者，其他重入调用可能插队，仍会破坏 FIFO。

### 5.2 有界性

等待队列不复制 batch，只保存等待 continuation。正常扫描中，同时阻塞的 producer 数受 worker 数和 coordinator 生命周期路径约束；默认 worker 数最多 4。实现不得把所有事件另存到第二个无界事件数组，也不得把 stream 改成 `.unbounded`。

### 5.3 取消与终止

- 非 terminal 事件取得门后再次检查 `cancelled`；若已取消，直接释放门，不再 yield。
- terminal 使用同一门，但不因 `cancelled` 被跳过。
- `.terminated` 视为当前投递完成并释放门；所有后续等待者都应迅速观察终止并返回。
- 不新增 `Task` 级全局队列，不使用 detached emitter，不扩大进程生命周期。

### 5.4 不采用的方案

- 不把 stream 改为无界：会破坏大目录内存上限。
- 不删除 store revision 检查：会把乱序静默写成不可信快照。
- 不只给 `flush()` 加布尔锁：issue、progress 和 terminal 仍可能相互越序，无法建立完整事件契约。
- 不把 worker 固定为 1：性能退化且没有修复协议错误。
- 不靠增大 `eventBufferSize`：只能降低触发概率，不能保证正确。

## 6. 实现范围

预计只需修改：

- `Sources/SpaceJudgeScan/FileSystemScanEngine.swift`；
- `Tests/SpaceJudgeScanTests/FollowupRegressionTests.swift`，必要时增加小型测试 helper；
- 本阶段 Pi 报告和相关测试文档。

不得修改公开 CLI/MCP schema、数据库 schema、计量口径、扫描边界、权限模型和清理能力。不得通过降低并发或放宽校验实现“通过”。

## 7. 回归测试

### 7.1 确定性并发背压回归

新增或增强测试，必须同时具备：

- `workerCount >= 4`；
- `eventBufferSize = 1`；
- 很小的 `batchNodeLimit` 和/或短时间 flush；
- 多个可并发完成的子目录，而非只有单层文件；
- 消费者有意暂停，让多个 producer 在满缓冲区上竞争；
- 断言 revision 精确等于 `1...N`；
- 断言节点无缺失/重复、terminal 唯一且最后。

测试应在修复前稳定暴露乱序，修复后可重复运行至少 20 次。若单次调度仍不能稳定触发，测试 helper 可以加入仅测试可用的受控让出/慢消费者，但不能在生产路径加入 sleep。

### 7.2 持久化集成回归

真实 `FileSystemScanEngine` + `PersistingScanRunner` + `SQLiteSnapshotRepository`，在并发背压条件下完成并重开只读库，断言：

- status 为 `completed`；
- last revision 与实际 batch 数一致；
- node/name/aggregate 计数匹配；
- 根节点与根 aggregate 可查询；
- 无 `revisionNotContiguous`。

### 7.3 取消/终止回归

在 event buffer 已满且至少一个 emitter 等待时取消，断言：

- 2 秒内得到唯一 `cancelled` terminal；
- cancel 后没有普通事件；
- worker、FD 和 spool 回收；
- consumer 提前结束时不死锁。

## 8. 分级验收

Pi 自测：

1. 受影响测试 20 次压力重复；
2. `swift test` 全量通过；
3. Release `spacejudge-persist-smoke` 对真实 `workspace` 完成；
4. 报告 wall time、节点数、revision、数据库大小和峰值 RSS；
5. 不提交、不发布、不修改全局 MCP 配置。

Codex 独立验收：

1. 审查 diff 与事件门的 FIFO/取消证明；
2. 独立复跑 targeted、全量和真实 `workspace`；
3. 重新构建并临时安装用户级 CLI/MCP；
4. 先扫主目录，再扫 `/`；两者都必须 `completed`、根可查询、进程与临时目录无残留；
5. 对比修复前后的速度、精度与资源数据，更新真实整机观察和验收基线。

## 9. 完成定义

只有以下条件全部满足，本文状态才可改为 `Accepted`：

- 缺陷有自动化回归而非只靠真实机器偶然通过；
- 真实 `workspace`、主目录和 `/` 均不再出现 revision gap；
- 失败快照不被误报为 completed；
- 全量 Swift、Node/MCP 回归不退化；
- 原有有界背压、取消、隐私和只读边界保持不变；
- Codex 完成独立验收并记录证据。
