# Phase 6 Agent 全局热点查询验收基线

状态：Accepted

日期：2026-09-28

## 1. 验收结论

SpaceJudge 已新增原生 CLI `hotspots` 与第八个 MCP 工具 `get_hotspots`。Agent 现在可以在
一次有界调用中取得某个 scope 下跨层级的 Top-K 容量热点，不再需要反复调用
`list_children` 自行拼接整棵目录树。

实现达到 [全局热点查询设计](31-phase-6-agent-hotspots.md) 与
[ADR-0012](adr/0012-agent-hotspots.md) 的边界：

- Swift/SQLite 仍是唯一快照事实来源，MCP 只做严格协议适配；
- 只复用现有 `childPage` 查询，没有数据库表、schema、索引或扫描写入路径变更；
- 最多输出 50 项，候选队列上界约为 `limit²`，不随整棵树节点数线性增长；
- 结果按 effective attributed bytes 降序、depth 升序、node ID 升序稳定排序；
- scope 自身不返回，深层后代可在一次调用中出现；
- running/cancelling 与跨 revision 混读均 fail-closed 为 `CONFLICT`；
- completed 标记完整，cancelled/failed/interrupted 可读取已持久化部分并标记不完整；
- 不接受模型提供的路径，不读取内容、不联网、不修改或删除用户文件。

结果为 `ancestorInclusive`：目录与其后代可能同时出现，容量用于定位而不能直接相加。
该限制同时存在于结构化字段、工具说明与 MCP 文本摘要中。

## 2. Codex 独立验证

在 Pi 完成实现和自测后，Codex 独立执行并通过：

- `arch -arm64 swift test --filter AgentHotspotsTests`：21 tests / 2 suites；
- `arch -arm64 swift test`：460 tests / 62 suites；
- `cd AgentMCP && npm run typecheck && npm test`：37 tests，0 fail；
- `arch -arm64 swift build -c release`；
- `git diff --check`。

热点专项覆盖多层交错容量、同容量 tie-break、scope 排除、空目录、文件 scope、limit
1/50/51、minimumBytes 0/1/阈值/UInt64.max、未知 ID、全部终态、running/cancelling、
revision 变化、无效 UTF-8 名称、bytes/GB 一致性和保守 `truncated` 语义。

官方 MCP client 验证 `tools/list` 恰好包含八个工具；`get_hotspots` 的 annotations 为
`readOnly=true`、`destructive=false`、`idempotent=true`、`openWorld=false`，输入输出 schema
严格且最多 50 项。提示词式文件名只出现在 structured content；文本摘要不包含名称或路径，
并明确提示 do not sum。

## 3. 黑盒目录验收

Codex 使用 release CLI 扫描一个真实三层临时目录：

```text
root/
  alpha/                 7 MiB
    top.bin              4 MiB
    beta/                3 MiB
      deep.bin           3 MiB
  gamma/                 2 MiB
    other.bin            2 MiB
```

单次 `hotspots --limit 8` 返回 completed 快照，顺序为 `alpha`、`top.bin`、`beta`、
`deep.bin`、`gamma`、`other.bin`，其中 `deep.bin.depth = 3`，证明查询不是直接子项包装。
结果 `snapshotComplete=true`、`overlapSemantics=ancestorInclusive`、`truncated=false`。
临时验收目录随后移入废纸篓。

## 4. 性能证据

专项测试使用真实 SQLite 构造 100,101 节点的分层快照，返回 50 项：

- Pi 自测查询约 0.020 秒，复跑区间约 0.017–0.026 秒；
- Codex 专项复测 0.015 秒；
- Codex 全量回归复测 0.021 秒。

这些数据远低于 1 秒工程门槛，但属于本机验收数据，不是跨硬件营销承诺。算法最多扩展
`limit` 个目录、每页最多 `limit` 项，因此查询额外内存保持有界。

## 5. 本机安装与回滚

验收版本安装在：

```text
/Users/example/.local/share/spacejudge/releases/0.1.0-hotspots-20260928
```

`/Users/example/.local/share/spacejudge/current` 已切换到该目录，既有
`/Users/example/.local/bin/spacejudge` 与 `spacejudge-mcp` 入口不变。安装后独立验证：

- `spacejudge --help` 已列出 `hotspots`；
- 通过官方 MCP client 连接已安装的 `spacejudge-mcp`，`tools/list` 返回八个工具；
- 已安装的 `get_hotspots` annotations 与验收契约一致。

上一版本 `0.1.0-dual-size-20260928` 保留，可通过重新指向 `current` 回滚。未修改任何
Codex、ChatGPT 或其他客户端的全局 MCP 配置。

## 6. 当前限制

- `get_hotspots` 返回容量事实，不提供“可安全删除”的判断，也不计算可释放空间；
- ancestor-inclusive 结果不能求和；需要不重叠候选时应设计独立接口；
- MCP 仅能查询本服务实例启动的扫描，CLI 可直接查询已持久化数据库；
- 超大整盘扫描的峰值内存优化仍是独立开放项，本阶段未改变扫描器。

Pi 的实现与自测记录见
[Phase 6 Agent 全局热点查询 Pi 报告](phase-6-hotspots-pi-report.md)。
