# Phase 6 大目录事件顺序修复验收基线

状态：Accepted（revision 乱序缺陷）；超大扫描内存优化仍 Open

日期：2026-09-28

## 1. 验收结论

真实大目录扫描的 `revisionNotContiguous` 缺陷已修复并通过 Codex 独立验收。

修复没有降低并发、扩大 stream buffer、放宽 SQLite 校验或改变公开 CLI/MCP 协议。`ScanCoordinator` 现在通过单写者 FIFO 事件门串行化所有 `ScanEvent` 投递；满缓冲重试期间保持所有权，释放时直接移交队首，避免 actor 重入让后续 batch 越过先前 batch。

修复后的已安装 CLI 已在同一台 Mac 上完成 `workspace`、整个用户主目录和 `/` 三个真实单根扫描，均形成唯一 `completed` 终态且根节点可查询。修复前失败的核心承诺已经恢复。

本轮同时确认一项独立的剩余缺陷：676 万至 840 万节点扫描的峰值 RSS 达到约 1.06–1.29 GB，明显高于既有百万节点 250 MB 工程目标。可靠性修复 Accepted，不把内存扩展性误报为已解决。

## 2. 根因与实现

修复前，`emit` 在有界 buffer 满时等待并重试。等待使 `ScanCoordinator` actor 重入，另一个 worker 可以先发布更高 revision。真实失败为：

```text
revisionNotContiguous(expected: 284, found: 286)
```

SQLite `integrity_check` 为 `ok`，证明数据库拒绝乱序写入的保护正确。

实现增加：

- `emitOwnershipHeld`：唯一投递所有权；
- `emitWaiters`：FIFO continuation 等待队列；
- `acquireEmitOwnership()`：按 actor 到达顺序取门；
- `releaseEmitOwnership()`：门保持占用并直接移交队首，队空才置空闲；
- 所有 event 共用同一门；cancel、terminated 和 terminal 继续遵守原终态语义。

等待队列只保存 continuation，不复制 batch；stream 仍为有界 `.bufferingOldest`。

## 3. 自动化回归

Pi 自测：

- 修复前确定性并发测试 5/5 暴露乱序，持久化测试 3/3 触发 `revisionNotContiguous`；
- 修复后 4 个受影响测试连续 20 轮全部通过；
- 全量 Swift：437 tests / 60 suites；
- Node/MCP：31 passed / 0 failed；
- 真实 `workspace` 的 bulk/reference 两种引擎均完成。

Codex 独立复跑：

| 检查 | 结果 |
| --- | --- |
| 4 个 targeted 并发/取消/持久化回归 | 4/4 通过 |
| `arch -arm64 swift test` | 437 tests / 60 suites，通过 |
| `cd AgentMCP && npm test` | 31 passed / 0 failed |
| `git diff --check` | 通过 |
| 安装产物 SHA-256 与 Release build | 一致 |

集成测试使用真实 engine + runner + SQLite，在 4 workers、1 个 event 槽下落库，随后通过 `openReadOnly(path:)` 重开并核对 status、last revision、根 aggregate、根 children 和计数。

## 4. Codex 真实机器验收

以下均使用修复后安装在 `~/.local/bin/spacejudge` 的 Release CLI。缓存状态未控制；目录内容在扫描期间可能变化，因此相邻两次计数可有小幅差异。

| 根 | 终态 | 节点 | 文件 | 目录 | issue | revision | wall | 峰值 RSS | 临时数据 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `workspace` | completed | 694,823 | 639,382 | 55,441 | 0 | 352 | 9.24 s | 174,768,128 B | 209 MB |
| 用户主目录 | completed | 6,766,424 | 5,848,700 | 917,724 | 154 | 3,917 | 154.04 s | 1,058,553,856 B | 1.9 GB |
| `/` | completed | 8,395,975 | 7,121,518 | 1,274,457 | 500 | 5,019 | 199.52 s | 1,286,356,992 B | 2.3 GB |

主目录 issue 全部为 `permissionDenied`。`/` 的 500 个 issue 中，497 个为 `permissionDenied`、3 个为 `io`。两次超大扫描都在修复前失败规模之上持续提交数千个连续 revision，terminal 后通过新进程读取 status 和根 children 成功。

归属字节：

- `workspace`：146,673,262,592 B；
- 用户主目录：722,084,118,528 B；
- `/`：873,938,997,248 B。

这些是扫描树内的 allocated/hard-link attribution，不等于 APFS 卷的可回收字节；不能直接与卷 used 做删除收益承诺。

## 5. 安装与清理

修复版安装为：

```text
~/.local/share/spacejudge/releases/0.1.0-scale-fix-20260928
```

`~/.local/share/spacejudge/current` 已切换到该版本，`~/.local/bin/spacejudge` 与 `spacejudge-mcp` 入口保持不变。CLI 二进制与本轮 Release build 的 SHA-256 一致。MCP 适配器代码未变；全局 MCP client 配置未修改。

三个 Codex 验收数据库在结果提取后按精确目录删除，回收约 4.4 GB；没有用户文件被删除。验收结束时没有扫描进程、后台服务或 `spacejudge-spool-*` 残留。

## 6. SpaceJudge 对分析工作的实际帮助

### 明显提速的部分

- `volume` 立即给出卷容量、已用和可用，不必拼接多条系统命令。
- 一次扫描后，`children` 可在同一个持久化快照上逐层查询，无需每深入一层重新跑 `du`。
- JSON/NDJSON 的 UInt64 原始值可直接排序、对账和交给 Agent，省去解析人类化文本。
- `effectiveAttributedBytes`、allocated/logical 与 sparse flag 能正确识别 Docker `Docker.raw` 这类逻辑大小远大于物理占用的文件。

### 明显提高精度的部分

- 同一扫描内 hard link 只归属一次，避免朴素递归重复计数。
- 权限拒绝和 I/O issue 有明确计数，分析结果可以标注覆盖边界，而不是假装全盘完全可见。
- 根与子节点共享 snapshot revision，避免分析过程中不同时间点的数据被混在一起。
- 原始字节、allocated bytes 和 volume facts 分开表达，减少 Finder/`ls`/`du` 不同口径造成的误判。

### 仍然拖慢分析的部分

- 修复前整盘失败迫使 Codex 手工分段，显著增加调用与对账成本；本轮已解决该可靠性问题。
- 当前没有“全树 top N”“跨分支候选汇总”或可回收性分类，Agent 仍需多次下钻并自行避免父子重复统计。
- 超大扫描内存与临时数据库偏大；在低剩余空间机器上必须监控存储门并及时清理任务缓存。
- 对外 `INTERNAL` 仍过于笼统；本次靠诊断入口才看到 `revisionNotContiguous`。后续应增加无路径泄漏的内部阶段/原因码。

## 7. 最终判断

SpaceJudge 已经让磁盘分析更快、更精确，尤其是在“找出最大分支、区分逻辑/物理占用、持续下钻、让 Agent 消费结构化结果”这几个环节。它把原本需要大量 `du/find/stat` 和人工拼接的工作，变成一次扫描加稳定查询。

但结论必须分层：

- 对已完成扫描范围的大小判断：有明显帮助，且比临时 shell 输出更可重复、更精确；
- 对一键整机可靠性：本轮修复前不合格，本轮修复后已在 840 万节点真实 `/` 上通过；
- 对“哪些能安全清理、能释放多少”：当前仍不能自动下结论，因为产品刻意没有 AI/清理规则，APFS clone/snapshot 与应用数据语义也需要额外证据；
- 对超大规模资源效率：仍有明确优化空间，下一阶段应优先处理 Name interner、hard-link set 和目录聚合状态的常驻内存。

## 8. 后续缺陷

按优先级保留：

1. 超大扫描峰值 RSS 约 1.29 GB：需要可重复的 700–900 万节点内存剖析与分层优化。
2. 无路径内部诊断码：区分 scan、event delivery、store revision、storage gate 和 SQLite I/O。
3. CLI progress 输出频率对长扫描偏高；Agent/MCP 应继续聚合，直接 CLI 可提供较低频率选项。
4. 增加只读 `top_items`/批量下钻能力，减少 Agent 多轮查询，但需另行定义有界输出与快照一致性。
