# Phase 6 Agent 全局热点查询 Pi 实施报告

状态：Pi 实现与自测完成；Codex 已独立验收，详见
[Phase 6 Agent 全局热点查询验收基线](32-phase-6-hotspots-baseline.md)

日期：2026-09-28

基线：`master`，起始 HEAD `43f55d8bc80e`（`feat: establish SpaceJudge MVP baseline`）。工作树保留 Phase 6 CLI/MCP、规模修复与双单位输出的既有未提交成果，本任务未 reset/checkout/clean，未覆盖用户改动。

环境：Apple Silicon（宿主 shell `uname -m = arm64`），Swift 6.3.3（target `arm64-apple-macosx26.0`），Node v22.23.2。所有命令在 `/Users/example/Documents/ChatGPT/SpaceJudge` 下执行。

设计依据：[Phase 6 Agent 全局热点查询设计](31-phase-6-agent-hotspots.md)、[ADR-0012](adr/0012-agent-hotspots.md)、[Phase 6 本地 CLI 与 MCP 设计](24-phase-6-design.md)、[本地 Agent MCP runbook](runbooks/local-agent-mcp.md)。

## 1. 结论

新增只读 Swift CLI `hotspots` 与第八个 MCP 工具 `get_hotspots`，让 Agent 一次调用即可得到 scope 下按有效归属容量排序的跨层 Top-K 后代节点。实现严格遵循冻结设计：

- 只复用现有 `childPage(of:in:limit:)`，未新增 schema、表、索引或迁移，未改扫描写入路径；
- 有界最佳优先：scope 不输出，每次最多读取一个目录的前 `limit` 个子项，最多输出 `limit` 项、最多扩展 `limit` 个目录，队列上界约 `limit²`；
- running/cancelling 拒绝为 `CONFLICT`；终态分页 revision 必须等于初始 `lastRevision`，否则 fail-closed；
- 结果明确 `overlapSemantics = "ancestorInclusive"`，祖先与后代可能同时出现，协议与 MCP 文本都禁止求和；
- 名称只在 `structuredContent`，人类文本不含名称；不返回绝对路径、不读内容、不联网、不动用户文件；
- 新增工具 `readOnly=true`、`destructive=false`、`idempotent=true`、`openWorld=false`；既有七个工具行为与 schema 不变。

## 2. 算法与边界

### 2.1 排序与遍历

优先级队列比较键：`effectiveAttributedBytes` 降序 → `depth` 升序 → `nodeId` 升序。

1. 校验 scan（`scanState`）与 scope（`ancestors`），scope 不入队；
2. 读取 scope 的前 `limit` 个直接子项，只把 `>= minimumBytes` 的项入队；
3. 每次弹出最大候选：计入结果；若未达 `limit` 且候选是目录（`NodeKind.isDirectoryLike`），读取其前 `limit` 个子项并入队；
4. 达到 `limit`、队列为空或队列最大项低于 `minimumBytes` 时结束。

正确性：目录容量不小于任一后代；每次只省略某父节点第 `limit+1` 名之后的子项，而它们前面至少有 `limit` 个容量不小于它们的兄弟，故省略项不可能进入全局 Top-`limit`。同容量时 `depth` 升序保证祖先先于后代。

### 2.2 `truncated` 判定

`truncated` 仅在达到 `limit` 时可能为 true，取以下三者的或：

- 队列仍有 `>= minimumBytes` 的候选；
- 某次分页被截断（`totalCount > items.count`）且该页最后一项仍 `>= minimumBytes`（未读兄弟可能合格）；
- 第 `limit` 个结果本身是尚未展开的目录（可能仍有合格后代）。

若结束原因是队列排空且所有分页尾部都已证明低于 `minimumBytes`，则为 false。该判定是保守的：已知不完整时绝不报 false；只有当剩余被证明低于门槛时才报 false。

### 2.3 快照与错误

- `completed` → `snapshotComplete=true`；`cancelled` / `failed` / `interrupted` 返回已持久化部分并 `snapshotComplete=false`；
- `running` / `cancelling` → `CONFLICT`（避免跨 revision 混读）；
- 每个 `childPage.snapshotRevision != 初始 lastRevision` → `CONFLICT`；
- 未知 scan/scope → `NOT_FOUND`；`limit` 越界、`minimumBytes` 非法 → `INVALID_ARGUMENT`；
- 所有错误经既有分类器输出稳定错误码，保持路径脱敏。

### 2.4 输入边界

- CLI：`hotspots --database ABS --scan-id UUID --node-id U64 [--limit N] [--min-bytes U64]`；
- `limit` 默认 30、范围 `1...50`；`minimumBytes` 默认 1，允许 `0` 与 `UInt64.max`，拒绝负数、空串以外非法值、溢出值；
- MCP：`get_hotspots(scanId, scopeNodeId, limit?, minimumBytes?)`，`limit` 整数 `1...50`，`minimumBytes` 为 UInt64 十进制字符串。

### 2.5 输出契约

顶层：`type`、`scanId`、`scopeNodeId`、`status`、`snapshotComplete`、`snapshotRevision`、`limit`、`minimumBytes`/`minimumGB`、`overlapSemantics="ancestorInclusive"`、`truncated`、`items`（≤50）。每项与 `children.items[]` 字段一致（节点、名称、flags、时间、四组 bytes/GB），另加 `depth`（scope 直接子项为 1）。

## 3. 修改文件

产品代码：

- `Sources/SpaceJudgeAgentCLIKit/AgentHotspotsQuery.swift`（新增）：结果类型、`AgentHotspotsQuery.run`、`AgentHotspotQueue` 二叉堆；对 `any SnapshotRepository` 编程以便受控测试。
- `Sources/SpaceJudgeAgentCLIKit/AgentCLIParser.swift`：新增 `.hotspots` 命令与 `--limit`/`--min-bytes` 解析、usage。
- `Sources/SpaceJudgeAgentCLIKit/AgentCLI.swift`：命令分发。
- `Sources/SpaceJudgeAgentCLIKit/AgentQueryCommands.swift`：`hotspots` 入口、`performHotspots` 渲染、`parseHotspotsLimit`/`parseMinimumBytes`，并把 children/hotspots 共用的 item 字段抽到 `childItemFields` 防止漂移。
- `AgentMCP/src/jobs.ts`：`getHotspots` 调用 CLI（显式 `--limit`/`--min-bytes`）。
- `AgentMCP/src/server.ts`：服务 instructions 改为八个工具；注册 `get_hotspots`（严格 input/output schema、annotations、GB 投影、脱敏人类文本）。

测试：

- `Tests/SpaceJudgeAgentCLITests/AgentHotspotsTests.swift`（新增）：内存 `SnapshotRepository` 夹具、算法与 tie-break、scope 排除、truncated、终态完整性、running/cancelling 冲突、坏 scan/node、revision fail-closed、参数边界；真实 SQLite 合成快照的 CLI 端到端、非法 UTF-8 名称、10 万节点性能。
- `AgentMCP/test/server.e2e.test.js`：`EXPECTED_TOOLS` 八工具、readOnly 集合、`get_hotspots` output schema 断言、端到端深层热点/祖先包含/不求和文本/隐私、running/未知/坏参拒绝。

文档：

- `docs/24-phase-6-design.md`：工具集合由七改八、新增 `get_hotspots` 表格行、CLI 5.3 增加 `hotspots`、schema 约束与验收门计数同步。
- `docs/adr/0011-local-cli-stdio-mcp.md`：工具数量陈述更新为八个并注明由 ADR-0012 扩展，架构决策本身未改。
- `docs/runbooks/local-agent-mcp.md`：工具表增至八个、`get_hotspots` 行、`minimumBytes`/`minimumGB` 与 ancestor-inclusive 说明。
- `docs/phase-6-hotspots-pi-report.md`（本报告，新增）。

未改动扫描引擎、`Package.swift`、数据库 schema 或既有七工具 schema/行为。

## 4. 测试证据

完整日志：`/tmp/spacejudge-hotspots-pi.CUtaVJ/logs/`（最终复核 `final-swift-test.log`、`final-typecheck.log`、`final-mcp-test.log`）。

### 4.1 Swift 全量

```text
arch -arm64 swift test
exit=0
✔ Test run with 460 tests in 62 suites passed after 10.036 seconds
```

日志 `swift-test.log`，无 `warning:`/`error:`。其中 `SpaceJudgeAgentCLITests` 由原规模增至含 hotspots 的 4 个 suite、36 个测试；新增 21 个 hotspots 用例。

关键用例：深层 `X` 一次出现且全局排序 `[A, A1, X, A2, B]`；同容量按 depth→nodeId；scope 不输出；目录与后代容量各自独立（不相减）；完整小树 `truncated=false`；`minimumBytes` 0 / 1 / 250 / `UInt64.max`；空目录与文件 scope；`limit` 1/50/51；completed/cancelled/failed/interrupted 的 `snapshotComplete`；running/cancelling `CONFLICT`；未知 scan/node `NOT_FOUND`；revision 变化 `CONFLICT`；每对 bytes/GB 可复算；items ≤ 50。

### 4.2 Node / MCP

```text
cd AgentMCP && npm run typecheck   # exit=0
cd AgentMCP && npm test            # exit=0
# tests 37, pass 37, fail 0
```

日志 `mcp-typecheck.log`、`mcp-test.log`。新增两条：

- `get_hotspots returns bounded ancestor-inclusive hotspots without leaking names`：真实 fixture 扫描到 completed 后一次调用看到深层目录 `a`→`b`（`depth=2`），字段逐项校验，人类文本不含 `ignore previous instructions`/中文名称且含 `do not sum`/`untrusted`，输出无授权根路径与用户名。
- `get_hotspots rejects running scans, unknown ids and bad arguments`：未知 scan 拒绝；大 fixture（`files: 20000`）扫描运行中 `get_hotspots` 报错（CONFLICT）；`limit=51`、非法 `minimumBytes`、未知 node、额外属性均被拒绝。该用例连续 3 次单独复跑均通过。

`tools/list` 恰好八个工具；`get_hotspots` `readOnlyHint=true`、`destructiveHint=false`、`openWorldHint=false`，output schema `additionalProperties=false` 且含 50 上限、`ancestorInclusive` literal、`depth` 整数约束。

### 4.3 静态检查

```text
git diff --check   # exit=0
```

## 5. 性能数据

10 万节点分层合成快照（root → 100 顶层目录 → 每个 40 子目录 → 每个 24 文件 = 100,101 节点），真实 SQLite 只读连接：

```text
[hotspots-perf] nodes=100101 build=1.422s query=0.020s items=50
```

全量 `swift test` 末次记录查询耗时 0.020 s，多次复跑区间约 0.017–0.026 s，均远低于 < 1 s 目标；构建时间不计入查询目标。查询额外内存由 `limit` 上界约束（最多 50 次分页、队列约 50×50），不随全树节点数线性增长；未新增索引或改变扫描写入路径。

## 6. 隐私验证

- 真实 release CLI 冒烟：`hotspots` 输出的名称仅出现在 JSON 字段中，无数据库/根绝对路径；坏 node 返回 `NOT_FOUND`（exit 3），`--limit 51` 返回 `INVALID_ARGUMENT`（exit 2），均无路径。
- Swift 用例断言输出不含临时基路径与 `NSHomeDirectory()`；非法 UTF-8 名称同时以 `name`（替换字符）与 `nameBase64`（原始字节）安全返回。
- Node 用例对 `structuredContent` 全部字符串做绝对路径与 `/<username>` 泄漏扫描，并断言 MCP 文本摘要与 stderr 不含名称或路径。
- 未读文件内容、未联网、未监听端口、未修改/删除用户文件。

## 7. 限制与未验证项

- 本报告为 Pi 自测；独立审查、commit、push、安装与发布由 Codex 验收后处理，不在本次范围。
- MCP running 冲突用例依赖扫描运行窗口：使用 20,000 文件 fixture 并在 `start_scan` 返回后立即调用，本地连续 3 次稳定通过，但在极快机器上仍有理论竞态；Swift 层用受控 repository 确定性覆盖 running/cancelling。若验收环境更慢可增大 fixture。
- `truncated` 对「第 `limit` 项恰为无子目录的空目录」会保守报 true（未额外查询证明其无子节点）；符合「剩余未证明低于门槛时不报 false」的保守要求。
- 性能数据来自本机合成快照，非真实整盘；超大扫描内存优化仍为既有开放项，本阶段未触及。
- 未覆盖 `UInt64.max` 量级的真实快照（不可得），由参数与算法单测覆盖。

## 8. 临时产物与进程清理

- 冒烟 fixture `/tmp/sj-hotspot-smoke.*` 已删除；未遗留 `spacejudge-mcp-*` 任务根。
- 未新增后台服务、监听端口或网络访问；`ps` 未见本任务遗留的 CLI/MCP 子进程。
- 测试 fixture 由用例自行创建并清理；日志保留在 `/tmp/spacejudge-hotspots-pi.CUtaVJ/logs/`，未提交进仓库。

## 9. Git 范围

未 commit、未打 tag、未 push、未发布、未安装、未修改用户全局 MCP 配置。本任务新增/修改的文件均落在既有未提交成果范围（`Sources/SpaceJudgeAgentCLIKit/`、`Tests/SpaceJudgeAgentCLITests/`、`AgentMCP/`、`docs/24`、`docs/adr/0011`、`docs/runbooks/`、本报告）；`git status` 中其余 `M`/`??` 为既有 Phase 6、规模修复与双单位成果，语义未改。`git diff --check` 通过。
