# Phase 6 CLI/MCP 双单位大小输出 Pi 报告

状态：Pi 实现与自测完成；等待 Codex 独立验收

日期：2026-09-28

基线：`master`，起始 HEAD `43f55d8bc80e`（`feat: establish SpaceJudge MVP baseline`），工作树保留 Phase 6 CLI/MCP 与规模修复的既有未提交成果。

环境：Apple M1 Max / 64 GiB / macOS 26.6.2（25G83），宿主 shell `uname -m = x86_64`（Rosetta），Swift 6.3.3（target `arm64-apple-macosx26.0`），Node v22.23.2。

设计依据：[Phase 6 CLI/MCP 双单位大小输出设计](29-phase-6-dual-size-output.md)、[Phase 6 本地 CLI 与 MCP 设计](24-phase-6-design.md)、[本地 Agent MCP runbook](runbooks/local-agent-mcp.md)。

## 1. 结论

CLI 与 stdio MCP 的所有容量字段现在同时返回精确 bytes 和十进制 SI GB。原 bytes 字段名称、类型、语义完全不变，GB 是只增字段的输出层派生值：

- Swift 用纯整数算术 `round(bytes / 10_000_000)`（half-up）得到两位小数，`UInt64.max` 安全；
- TypeScript 用 `BigInt` 做同一换算，绝不经过 `Number`；
- 两侧逐字段一致，并由真机 `/` 卷交叉验证；
- MCP 严格 output schema、`structuredContent` 与人类文本同步更新；
- 未改数据库 schema，未落库 GB，未引入 GiB、自动单位切换或清理能力。

## 2. 换算算法

定义 `1 GB = 1_000_000_000 bytes`（SI 十进制，非 GiB）。两位小数等于

```text
hundredths = round(bytes / 10_000_000)      // half-up
GB 字符串  = hundredths / 100  +  "."  +  (hundredths % 100 补足两位)
```

- Swift：`bytes.quotientAndRemainder(dividingBy: 10_000_000)`，余数 `>= 5_000_000` 时商 `+1`。先除后进位，`UInt64.max` 不会溢出。
- TypeScript：`(value + 5_000_000n) / 10_000_000n`（`BigInt` 非负截断等于 floor），再 `% 100n` 补零。
- 输出只用 ASCII 数字与 `.`，与 locale 无关，无科学计数法；`null` 输入 → `null`。

边界表（Swift `AgentJSON.gigabytes` 与 Node `gigabytes` 断言同一张表）：

| bytes | GB |
| ---: | ---: |
| 0 | `0.00` |
| 4,999,999 | `0.00` |
| 5,000,000 | `0.01` |
| 999,999,999 | `1.00` |
| 1,000,000,000 | `1.00` |
| 1,005,000,000 | `1.01` |
| `UInt64.max` (18,446,744,073,709,551,615) | `18446744073.71` |
| `null` | `null` |

## 3. 字段矩阵与覆盖

| 精确字段（原样保留） | 新增人可读字段 |
| --- | --- |
| `capacityBytes` | `capacityGB` |
| `availableBytes` | `availableGB` |
| `usedBytes` | `usedGB` |
| `rootAttributedBytes` | `rootAttributedGB` |
| `logicalBytes` | `logicalGB` |
| `allocatedBytes` | `allocatedGB` |
| `attributedBytes` | `attributedGB` |
| `effectiveAttributedBytes` | `effectiveAttributedGB` |

覆盖位置：

- CLI `volume`：capacity/available/used；
- CLI scan `progress`：attributed；
- CLI scan `completed`/`cancelled`/`failed`：rootAttributed；
- CLI `status`：rootAttributed 与 capacity/available/used；
- CLI `children.items[]`：logical/allocated/attributed/effectiveAttributed；
- MCP `get_volume_usage`、`get_scan_status.progress/terminal`、`list_children.items[]`：同名字段。

计数、ID、revision 不是容量，不新增 GB。MCP 人类文本摘要形如
`953.22 GB (953224705225 bytes)`，未知为 `unknown`。

MCP output schema 为 GB 新增专用 pattern `^\d{1,11}\.\d{2}$`（`UInt64.max` 的整数部分最多 11 位），bytes 继续使用原 UInt64 pattern；三者（schema、`structuredContent`、文本）由官方 client 端到端断言。

## 4. 修改文件

- `Sources/SpaceJudgeAgentCLIKit/AgentJSON.swift`：`bytesPerGigabyte`、`gigabytes(_:)`、`gigabytesOrNull(_:)`。
- `Sources/SpaceJudgeAgentCLIKit/AgentVolumeCommand.swift`：volume 三对字段。
- `Sources/SpaceJudgeAgentCLIKit/AgentQueryCommands.swift`：status 四对、children 每项四对。
- `Sources/SpaceJudgeAgentCLIKit/AgentScanCommand.swift`：progress 与两种 terminal 的 rootAttributed 对。
- `AgentMCP/src/sizes.ts`（新增）：`BigInt` GB formatter。
- `AgentMCP/src/server.ts`：三个工具的 output schema、`structuredContent`、文本摘要与 GB pattern。
- `AgentMCP/test/sizes.test.js`（新增）：边界表、null/非法输入、真机 CLI 交叉验证。
- `AgentMCP/test/server.e2e.test.js`：schema 新增字段与端到端 bytes/GB 一致性断言。
- `Tests/SpaceJudgeAgentCLITests/AgentCLITests.swift`：formatter 边界、双字段一致性 helper、确定性 progress/terminal 用例。
- `docs/29-phase-6-dual-size-output.md`：补充 half-up 说明与实现说明（状态仍为 `Proposed`）。
- `docs/runbooks/local-agent-mcp.md`：工具表与新容量字段说明。
- `docs/phase-6-dual-size-pi-report.md`（本报告，新增）。

未改 `docs/24-phase-6-design.md`（`Accepted`，新增只增字段在其兼容扩展范围内，避免触碰 Accepted 文档）。

## 5. 测试证据

所有命令在 `/Users/example/Documents/ChatGPT/SpaceJudge` 下执行；日志见
`/tmp/spacejudge-dual-size-pi.PnkQLB/logs/`。

### 5.1 Formatter 边界

- Swift：`arch -arm64 swift test --filter SpaceJudgeAgentCLITests`，15 tests / 2 suites 通过，退出码 0。含 `The GB formatter matches the frozen boundary table`（0、4,999,999、5,000,000、999,999,999、1,000,000,000、1,005,000,000、`UInt64.max`、nil）。
- Node：`gigabytes matches the frozen boundary table`、`gigabytes handles the null and malformed contract`、`gigabytes never uses floating point`。

### 5.2 Swift 全量

```text
arch -arm64 swift test
✔ Test run with 439 tests in 60 suites passed after 9.790 seconds
```

新增确定性用例 `scan progress and terminal events carry bytes and GB`：受控引擎发一条
progress（`attributedBytes=1500000000 → attributedGB=1.50`）后等到测试门才终态
（`rootAttributedBytes=2500000000 → rootAttributedGB=2.50`），断言双字段。
`scan completes, persists completed and serves queries` 额外断言 volume/status/children/terminal
的每对 bytes/GB 可复算一致，且 GB 是字符串而非 number。

### 5.3 Node / MCP 全量

```text
cd AgentMCP && npm test     # pretest 先 npm run build
# tests 34→35, pass 35, fail 0
```

- `published output schemas carry the contract constraints`：三个工具的 GB 字段存在且为
  nullable/非空字符串 pattern。
- `end-to-end scan, queries, untrusted names and privacy`：真实扫描后逐字段断言
  `*GB === gigabytes(*Bytes)`，卷摘要含 `GB (`。
- `the Swift CLI and the MCP formatter agree on real volume facts`：spawn release CLI
  `volume --root <tmp>`，对同一 bytes 比较 Swift 输出与 Node formatter。
- 既有生命周期、孤儿进程、stdio 清理、行长、脱敏、roots 用例全部保持通过。

### 5.4 真机 `/` 卷

```text
.build/release/spacejudge-agent-cli volume --root /
{"availableBytes":"41437879095","availableGB":"41.44","capacityBytes":"994662584320",
 "capacityGB":"994.66","ok":true,"type":"volume","usedBytes":"953224705225","usedGB":"953.22"}
```

用独立 Node `BigInt` 重算三对字段全部 `OK`；`994662584320 → 994.66` 与设计示例一致。
（实际数值随卷状态浮动，断言的是换算关系。）

### 5.5 静态与工作树

- `AgentMCP && npm run typecheck`：退出码 0。
- `git diff --check`：无空白错误，退出码 0。

## 6. 兼容性与边界

- 只增字段；CLI 输出仍是每行一个 JSON/NDJSON 对象，原有脚本只读 bytes 不受影响。
- MCP 严格 schema 同步新增 GB，`additionalProperties=false` 未被放宽。
- GB 与 bytes 可互相复算；`null` 一一对应，未知不伪装成 `0.00`。
- 未改数据库 schema，未改扫描/计量/权限/取消语义，未新增网络、后台服务或依赖。

## 7. 限制与未验证项

- 本报告只做 Pi 自测；发布级重新构建、用户级安装与 Codex 独立验收不在本次范围。
- 真机只验证了 `/` 卷的 `volume`；整盘 `scan` 的双单位输出由 Swift 用例与 fixture e2e 覆盖，未做整盘真实扫描。
- 未在不同 locale 环境切换验证（实现只用 ASCII 整数运算，理论上与 locale 无关）。
- 未覆盖 `UInt64.max` 的量级真机卷（不可得），由单测覆盖。

## 8. 临时产物与后台服务

- 未新增后台服务、监听端口或网络访问；`pgrep -fl 'spacejudge|SpaceJudge'` 无残留。
- 无遗留 `spacejudge-mcp-*` 任务目录；测试 fixture 与 probe 脚本已删除。
- 日志保留在任务目录 `/tmp/spacejudge-dual-size-pi.PnkQLB/logs/`，未提交进仓库。
- `/private/tmp` 中其它 `sj-*` / `spacejudge-phase*` 为更早阶段遗留，非本任务产物。

## 9. Git 改动范围

未提交、未打 tag、未 push、未发布、未修改用户全局 MCP 配置。本任务涉及的文件均在
Phase 6 未提交成果内（`AgentMCP/`、`Sources/SpaceJudgeAgentCLIKit/`、
`Tests/SpaceJudgeAgentCLITests/`、`docs/29`、`docs/runbooks/`、本报告），
`git status` 中其余 `M`/`??` 为既有 Phase 6 与规模修复成果，语义未改。
`git diff --check` 通过。
