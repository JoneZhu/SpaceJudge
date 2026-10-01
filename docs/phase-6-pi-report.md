# Phase 6 Pi 交付报告

状态：**Pi 已完成实现与自测；Codex 后续已独立验收通过。** 本文保留 Pi 的原始实施与自测记录，最终结论见 [Phase 6 验收基线](25-phase-6-baseline.md)。Pi 未提交、未打 tag、未 push、未签名或发布。

核对日期：2026-09-27

## 1. 交付范围

- 6A：新增 `SpaceJudgeAgentCLIKit` 与 `spacejudge-agent-cli`，实现 `volume/scan/status/children/issues` NDJSON 契约、字符串 UInt64、持久化后发布、真信号取消。
- 6B：新增 `AgentMCP/`，使用官方 `@modelcontextprotocol/server`、`@modelcontextprotocol/client` 2.1.0 与 Zod 4.6.5，只走 stdio 的七工具适配器。
- 新增 runbook 与本报告；在 `docs/05-testing-and-acceptance.md`、`docs/06-implementation-and-pi.md` 标注“Pi 已完成，等待 Codex 验收”。

## 2. 改动文件

### 2.1 Swift

- `Package.swift`：新增 library `SpaceJudgeAgentCLIKit`、executable `spacejudge-agent-cli`、testTarget `SpaceJudgeAgentCLITests`。
- `Sources/SpaceJudgeAgentCLI/main.swift`：进程入口、SIGINT/SIGTERM → 协作式取消、单写者 stdout。
- `Sources/SpaceJudgeAgentCLIKit/AgentCLI.swift`：非流式命令分发。
- `Sources/SpaceJudgeAgentCLIKit/AgentCLIError.swift`：稳定错误码、退出码、无路径错误分类。
- `Sources/SpaceJudgeAgentCLIKit/AgentCLIParser.swift`：严格参数解析与 usage。
- `Sources/SpaceJudgeAgentCLIKit/AgentCLIPath.swift`：绝对路径/目录/符号链接校验、canonical、包含关系。
- `Sources/SpaceJudgeAgentCLIKit/AgentJSON.swift`：确定性 JSON、十进制字符串、UTC ISO-8601、`null` unknown。
- `Sources/SpaceJudgeAgentCLIKit/AgentVolumeCommand.swift`：`volume`。
- `Sources/SpaceJudgeAgentCLIKit/AgentScanCommand.swift`：`scan` 流、workspace/数据库 `0700/0600` 预创建、progress 250 ms 节流、终态先持久化。
- `Sources/SpaceJudgeAgentCLIKit/AgentQueryCommands.swift`：`status`、`children`、`issues` 只读查询。
- `Sources/SpaceJudgeAgentCLIKit/CountingSnapshotRepository.swift`：仅在事务提交后累计 `persistedNodes`。
- `Tests/SpaceJudgeAgentCLITests/AgentCLITests.swift`、`Tests/SpaceJudgeAgentCLITests/AgentCLISignalTests.swift`。

### 2.2 TypeScript

- `AgentMCP/package.json`、`AgentMCP/package-lock.json`、`AgentMCP/tsconfig.json`。
- `AgentMCP/src/server.ts`：七个工具、严格 schema/annotations、服务 instructions、入口与 CLI 路径解析。
- `AgentMCP/src/roots.ts`：`--allow-root` 校验、canonicalize、去重、opaque rootId、脱敏 displayName。
- `AgentMCP/src/jobs.ts`：单并发任务、私有 task 目录、精确 PID 取消、终态清理、shutdown 回收。
- `AgentMCP/src/native-client.ts`：argv 直接 `spawn`、有界行长、stderr 有界 ring buffer、NDJSON 解析。
- `AgentMCP/src/redaction.ts`：显式 secret 与通用 home/temp 路径脱敏。
- `AgentMCP/test/`：`roots.test.js`、`server.e2e.test.js`、`lifecycle.test.js`、`helpers.js`。

### 2.3 文档与忽略

- 新增 `docs/runbooks/local-agent-mcp.md`、`docs/phase-6-pi-report.md`。
- 修改 `docs/05-testing-and-acceptance.md`、`docs/06-implementation-and-pi.md`。
- 修改 `.gitignore`：忽略 `node_modules/`、`*.tsbuildinfo`（`dist/`、`.build/` 原已忽略）。
- 保护性文档 `docs/24-phase-6-design.md`、`docs/adr/0011-local-cli-stdio-mcp.md`、`docs/phase-6-pi-task.md` 未修改。

## 3. 公开协议

### 3.1 Swift CLI

所有命令每行一个 JSON；UInt64/节点 ID/revision 是十进制字符串；未知值为 `null`；时间为 UTC ISO-8601；JSON 键排序。

`volume`：

```json
{"type":"volume","ok":true,"capacityBytes":"<u64|null>","availableBytes":"<u64|null>","usedBytes":"<u64|null>"}
```

`scan` 流（示例字段）：

```json
{"type":"started","scanId":"<uuid>","rootNodeId":"<u64>"}
{"type":"progress","visitedEntries":"<u64>","persistedNodes":"<u64>","attributedBytes":"<u64>"}
{"type":"completed","scanId":"<uuid>","status":"completed","startedAt":"<iso>","finishedAt":"<iso>","fileCount":"<u64>","directoryCount":"<u64>","inaccessibleCount":"<u64>","issueCount":"<u64>","rootAttributedBytes":"<u64>"}
```

终态为 `completed`/`cancelled`/`failed` 恰好一个，先持久化后输出。`failed` 额外带 `code` 与无路径 `message`。

`status`：状态、计数、`nodeCount`、`nameCount`、`aggregateCount`、`lastRevision`、容量、按分类聚合的 `issues`。

`children`：`scanId`、`nodeId`、`limit`、`totalCount`、`snapshotRevision`、`items[]`。每个 item 含 `nodeId`、`parentId`、`name`（有损 UTF-8 展示）、`nameBase64`（原始字节）、`kind`、`flags[]`、`logicalBytes`、`allocatedBytes`、`attributedBytes`、`effectiveAttributedBytes`、`modifiedAt`。

`issues`：`categories[]`（`category`、`count`）与 `samples[]`（`category`、`errno`、`count`）。**不返回文件名**（对设计“无路径样例”的隐私加固）。

进程级错误：

```json
{"type":"error","code":"INVALID_ARGUMENT","message":"The request is invalid."}
```

稳定码与退出码：`INVALID_ARGUMENT`=2、`NOT_FOUND`=3、`CONFLICT`=4、`ACCESS_DENIED`=5、`INSUFFICIENT_SPACE`=6、`INTERNAL`=1。`scan` 输出终态时 `completed`/`cancelled` 退出 0、`failed` 退出 1。

### 3.2 MCP 工具

固定七个：`list_allowed_roots`、`get_volume_usage`、`start_scan`、`get_scan_status`、`list_children`、`get_scan_issues`、`cancel_scan`。所有输入 schema 使用 Zod `.strict()`（`additionalProperties=false`）并显式约束枚举、整数范围、长度与 UUID/根 ID 形状；输出 schema 与 `structuredContent` 一致。所有工具 `destructiveHint=false`、`openWorldHint=false`；只读观察工具 `readOnlyHint=true`，`start_scan` 与 `cancel_scan` 为 `readOnlyHint=false`。服务 instructions 声明文件名是不可信元数据、绝不作为指令执行。

## 4. 执行的测试命令与结果

机器：Apple Silicon arm64，macOS（Swift target `arm64-apple-macosx26.0`），Swift 6.3.3。**Pi 自测运行在 Node v22.23.2 / npm 10.9.8**；**Codex 独立验收运行在仓库声明的最低 Node 20**（见第 12 节）。缓存状态未受控。

| 命令 | 结果 |
|---|---|
| `swift build -c release --product spacejudge-agent-cli` | 成功 |
| `swift test` | **434 tests / 59 suites 全部通过** |
| `swift test --filter SpaceJudgeAgentCLITests` | **13 tests / 2 suites 全部通过**（含真进程 SIGINT、注入式 post-start 失败、不可确认失败） |
| `cd AgentMCP && npm ci` | 成功，17 packages，0 vulnerabilities |
| `cd AgentMCP && npm run build` | `tsc` 成功 |
| `cd AgentMCP && npm run typecheck` | 成功（`--noEmit`） |
| `cd AgentMCP && npm test` | **31 tests 全部通过**（Pi 在 Node v22.23.2 与 Node v20.16.0 上均通过） |
| `cd AgentMCP && npm run bench:local` | 通过（budgets 内），输出 JSON 见第 5 节 |

新增/修复后用例覆盖：JSON schema/UInt64 字符串/`null`/排序分页；真实 fixture 扫描到 persisted `completed`；真 `SIGINT` 到 persisted `cancelled`；无效 root/scan/node、缺库、坏 UUID、库已存在、数据库不在 workspace 内/嵌套数据库；**既有 0755 workspace 被拒且模式不变**；**注入式 post-start 失败产生唯一持久化 `failed` 终态**；**不可确认的失败只输出 `error/INTERNAL`，不发布 `failed` 终态**；workspace `0700` 与数据库 `0600`；官方 client 经 stdio 的 initialize/instructions/`tools/list`/七工具端到端；**输出 schema 的 UUID/UInt64 pattern、`additionalProperties=false`、数组上限**；schema 拒绝与未知 ID；并发冲突与幂等取消；提示词式文件名；连续 10 次扫描后无孤儿进程；**JobManager 任务目录有界且 shutdown 后 task root 消失**；**stdout 超长行 fail-closed**；**native 事件状态机（terminal-before-start、重复 started、乱序/畸形 progress、scanId 不匹配、重复 terminal、started 后 error 均 fail-closed）**；**64/65 个授权根的启动边界**；协议/错误/stderr 的路径与用户名泄漏扫描。

## 5. 资源与性能数据

本机一次测量（arm64，Release Swift CLI，热缓存，Node 适配器，200 目录 × 100 文件 = 20,000 entries fixture；由 `cd AgentMCP && npm run bench:local` 复现）：

- 扫描 wall time：161.6 ms；
- 适配器 RSS：扫描后 75.8 MiB，100 次 `list_children` 后 95.7 MiB（预算 < 150 MiB）；
- `list_children`（limit 100）延迟：P50 26.29 ms，P95 33.11 ms，max 35.20 ms（预算 P95 < 100 ms）。

`bench:local` 会在自己的临时 fixture 上运行官方 stdio client（使用 `start_scan` 返回的 `rootNodeId`），打印含 fixture 形状、扫描时间、RSS、P50/P95/max、任务根泄漏数与预算判定的单 JSON，并自行清理；`passed` 同时要求 `terminalStatus === 'completed'`、RSS < 150 MiB、P95 < 100 ms、`leakedTaskRoots` 为空。不属于 `npm test`。数值随机器和缓存状态波动，Codex 需在本机复测。

## 6. 隐私与边界验证

- 所有协议输出、错误 JSON、MCP 文本摘要、server stderr 均断言不含授权根绝对路径与用户名（`list_children.structuredContent` 中的文件名除外，且仅为不可信展示元数据）。
- 提示词式文件名只出现在 `list_children.structuredContent`；不进入文本摘要、issues 或错误。
- `src/` 无 `node:http`/`node:https`/`node:net`/`node:tls`/`fetch` 等网络 API，不监听端口。
- `scan` 的数据库与临时文件位于任务私有、`0700` 的 workspace，数据库三件套 `0600`；MCP `taskRoot` 由 `mkdtempSync` 创建并 `chmod 0700`。
- 取消只对本实例 `spawn` 返回的精确 PID 发送 `SIGINT`，超时才对该 PID 升级 `SIGKILL`；未使用 `killall`/`pkill`/进程名匹配。
- 服务退出时全部授权根目录零删除、零枚举；只删除本实例 taskRoot。

## 7. 已知限制与未完成项

- **等待 Codex 验收**：本报告的“通过”仅代表 Pi 自测，不代表独立验收通过；Phase 6 未标记 Accepted。
- 权限拒绝（EACCES）与真正 `INSUFFICIENT_SPACE` 的端到端路径未用受限目录/低空间卷做自动化实测；仅做了分类与错误码的单测级验证。Codex 可用受限 fixture 补测。
- `get_scan_issues` / CLI `issues` 有意不返回任何文件名，只返回分类计数与 errno 样例；这是对设计“无路径样例”的隐私加固，如需样例名需另行规格。
- `children` 的 `name` 是有损 UTF-8 展示；原始字节通过 `nameBase64` 无损给出。
- macOS `/tmp` 是符号链接；`volume`/`scan` 拒绝符号链接根，MCP 启动校验时已 canonicalize，用户直接调用 CLI 时应传真实路径。
- CLI 根路径不变量：`volume`/`scan` 的 root 必须存在、为目录、最终组件非符号链接；MCP `--allow-root` 在启动时完成同样的校验与去重。
- CLI `scan --workspace` 不变量：workspace 必须**已存在**、为当前用户所有、真实目录且无 group/other 权限位；数据库必须是它的直接子文件。CLI 不创建、不 `chmod`、不修改调用方目录；因此调用方需自行提供合格的 workspace（MCP 适配器会创建它的 `0700` 任务目录）。
- `start_scan` 后极短扫描可能没有任何 `progress` 行（`progress` 上限 250 ms 一条）；状态查询此时返回 `progress: null`。
- 运行时不下载依赖、不访问网络，但 Node 适配器的 `npm ci` 安装阶段需要网络获取已锁定版本。
- 未修改全局 MCP 配置、未发布 npm 包、未签名/公证/发布 App、未提交/打 tag/push。

## 8. 交回 Codex 的下一步

1. 独立复跑第 4 节命令并记录退出码。
2. 复查 CLI NDJSON schema 与 MCP `structuredContent`/schema 是否与 `docs/24-phase-6-design.md` 完全一致。
3. 用受限目录、低空间卷补测 `ACCESS_DENIED`/`INSUFFICIENT_SPACE`。
4. 抽查真机进程表确认无孤儿进程与无端口监听。
5. 通过后将 Phase 6 标记为 Accepted 并按用户授权处理基线。

## 9. 设计适配说明（最小语义等价）

SDK 2.1.0 与设计措辞存在少量非语义差异，均已按最小适配处理并在此记录：

- `@modelcontextprotocol/client` 仅由测试使用，因此放在 `devDependencies`；`@modelcontextprotocol/server` 与 `zod` 仍固定在 `dependencies`。三个版本都精确锁定在 `package-lock.json`。
- 官方 server 的 `registerTool` 使用 `z.object(...).strict()` 派生 `additionalProperties=false` 的 JSON Schema；未手写 schema。
- 工具错误统一返回 `isError: true` 的无路径文本；调用方只依赖文本中的稳定语义，不依赖平台异常类型。
- CLI `scan` 终态 `failed` 退出码取 1，`completed`/`cancelled` 取 0；这是对“进程级错误用非零退出码”的最直接解释，终态本身仍在 NDJSON 中明确给出。
- `issues` 仅返回分类计数与 errno 样例，不返回任何文件名/路径，以满足隐私矩阵对“提示词式文件名只出现在 `list_children.structuredContent`”的验收。
- 极短扫描可能没有 `progress` 行；`get_scan_status.progress` 此时为 `null`，与“进度可选、终态必有”的语义一致。

## 10. 修复轮：Codex review 1

本轮针对 review-1 的 8 项要求逐条修复，未改公开 schema、权限边界、持久化终态语义或依赖大版本。Phase 6 仍为“等待 Codex 验收”，未标记 Accepted。

1. **workspace 权限不再被修改**：`prepareWorkspace` 改为 fail-closed 校验已存在目录——必须是当前有效用户所有、真实目录、无 group/other 权限位，否则按码拒绝且**不 chmod**；数据库必须是该 workspace 的**直接子文件**，CLI 不再创建嵌套调用方目录。MCP 仍对自己 `mkdtemp` 创建的 `0700` 任务目录负责。回归测试：既有 `0755` workspace 被拒且模式保持 `0755`、未创建数据库。
2. **post-start 失败的终态**：`AgentScanCommand` 拆出 `runSession`，仓库保持打开到失败确认之后，并在每条返回路径关闭一次；`started` 之后的失败只输出一个持久化 `failed` 终态，不再追加进程级 `error`。确定性测试用注入的 `FailingAfterStartedEngine` 断言 `started` + 恰好一个 `failed` 且持久化为 `.failed`。
3. **授权根数量**：`parseAllowedRoots` 在去重后超过 64 个时以无路径错误拒绝；`roots.test.js` 覆盖 64 通过 / 65 失败。
4. **NDJSON 行长 fail-closed**：`LineScanner` 改为按字节计长；一旦超限即永久失败、只上报一次 overflow 并忽略后续数据；`ScanProcess` 立即把该扫描标为 `INTERNAL` 并强制终止精确 PID。测试覆盖直接超长行、按字节（非 UTF-16）计长，以及“超长行后仍不能收到 started”。
5. **启动失败清理不竞态子进程**：`startScan` 失败/超时时先 `forceKill` 并等待 `done`（子进程 close）再删除任务目录；无法在有界窗口内回收时保留私有目录并返回 `INTERNAL`。`shutdown` 同样只在所有子进程被回收后才删除 task root。
6. **资源清理证据**：新增 `job-manager.test.js` 直接驱动 `JobManager`：连续 10 次扫描期间任务目录数量有界，`shutdown()` 后实例 task root 不存在，并保留孤儿进程断言。
7. **可复现基准**：新增 `AgentMCP/scripts/bench-local.mjs` 与 `npm run bench:local`；它自建自清临时 fixture，经官方 stdio client 测量并输出含 fixture 形状、扫描时间、RSS、P50/P95/max 与预算判定的单 JSON。
8. **文档一致性**：runbook 增加 workspace/直接子文件不变量；本报告更新测试计数与基准命令，并保留“等待 Codex 验收”。

## 11. 修复轮：Codex review 2

本轮针对 review-2 的 4 项最终协议加固逐条修复，未改工具名、`structuredContent` 形状、权限边界或依赖大版本。Phase 6 仍为“等待 Codex 验收”，未标记 Accepted。

1. **不发布未持久化的 failed 终态**：`AgentScanCommand.runSession` 只有在 `scanState(scanID)` 存在且状态恰为 `.failed` 时才发布 `failed` 终态；否则关闭仓库并只发布一个无路径的 `error`（`INTERNAL`），不再从内存伪造 failed summary（`failedSummary` 已删除）。测试用 `UnconfirmedFailureRepository`（`begin` 成功、`fail` 抛错、`scanState` 持续 `running`）断言输出只有 `started` + `error/INTERNAL`、无 `failed`；原有“started + 唯一持久化 failed”测试继续通过。
2. **native 事件状态机**：`ScanProcess` 现在强制 `started` 必须是第一个且唯一的合法 UUID + UInt64 事件；`progress` 只能在 started 之后、terminal 之前且三个字段均为合法 UInt64；terminal 必须在 started 之后、恰好一个、scanId 与 started 一致、可选计数/时间戳/错误码合法；重复/乱序/畸形/未知事件、started 之后的 `error`、超长行都永久 `INTERNAL`、终止精确 PID 并忽略后续事件。`done` 改为在子进程 close 时结算，因此重复 terminal 不能被当作成功。新增 `protocol.test.js` 覆盖 terminal-before-start、重复 started、started 前 progress、畸形 progress、scanId 不匹配、重复 terminal、started 后 error，并保留一个合法序列成功用例。
3. **输出 schema 收紧**：复用 `scanIdSchema`、`rootIdSchema`、带真实 UInt64 上界 `refine` 的 `uint64`、`scanStatusSchema`、`nodeKindSchema`、`flagSchema`、新增 `issueCategorySchema`；约束 displayName ≤128、name ≤1024、nameBase64 ≤2048、时间戳 ≤40、`errno` Int32、数组上限（roots 64、items 100、flags 11、categories 16、samples 20）。tools/list 测试现在检查代表性输出 schema 的 UUID/UInt64 pattern、`additionalProperties=false`、`anyOf` 可空分支与数组上限。
4. **基准裁决**：`bench-local.mjs` 使用 `start_scan` 返回的 `rootNodeId`，`passed` 现在同时要求 `terminalStatus === 'completed'`；budgets 中显式列出该要求。

## 12. 修复轮：Codex acceptance（Node 20 清理兼容性）

Codex 在本机干净复跑：Swift release 构建 + 434 Swift 测试通过；`npm ci`、build、typecheck 通过；**`npm test` 在仓库声明的最低 Node 20 上有 1/28 失败**，仅限 `parseAllowedRoots rejects a symlinked root` 的测试清理：`fs.rmSync(link, { force: true })` 对指向目录的符号链接在 Node 20 抛 `ERR_FS_EISDIR`。这是**测试清理的可移植性问题，不影响产品代码或公开协议**。

修复：

- 新增 `test/helpers.js` 的 `removeSymlink(link)`：用 `fs.unlinkSync` 只删除链接本身、从不跟随目标进入目录，并对 `ENOENT` 幂等。`roots.test.js` 与 `server.e2e.test.js` 统一使用它；后者原本还会泄漏一个指向已删除 fixture 的悬挂链接，已一并修正。
- 未改动 `AgentMCP/src/`、Swift 产品代码、工具表面或依赖版本。

运行时区分：

- **Pi 自测环境**：Node v22.23.2 / npm 10.9.8；`npm run build`、`npm run typecheck`、`npm test`（28/28）、`npm run bench:local` 均通过。
- **Codex 验收环境**：仓库声明的最低 Node 20；此修复只使用 Node 20 就存在的 `fs.unlinkSync`，不引入任何新 API 或依赖。

清理后自测再次在 Node v22.23.2 上验证：`npm test` 28/28 通过，且运行后临时目录中不再残留 `sj-mcp-test-*-link` 悬挂链接（此前累积的 18 个测试遗留链接已清除）。

## 13. 修复轮：Codex runtime acceptance（stdio EOF 任务根泄漏）

Codex 在 Node 20.16.0 上复跑：28/28 测试与基准通过，但真实文件系统审计发现官方 stdio client `close()` 后遗留大量 `spacejudge-mcp-*` 目录。

根因：`main()` 只在 SIGINT/SIGTERM 时调用 `manager.shutdown()`。官方 `StdioServerTransport` 在 stdin EOF 时自行关闭，进程自然退出，因此正常 `client.close()` 不经过 manager 清理。

修复：

- `AgentMCP/src/server.ts` 新增 `CleanupStdioTransport extends StdioServerTransport`：`close()` 先 await 一个共享、幂等的 `manager.shutdown()` promise，再 `super.close()`；以 `serveStdio(..., { transport })` 注入。清理挂在**连接 wire** 上而不是 `McpServer` 实例上，因此 `serveStdio` 的探测/丢弃实例不会触发 manager 关闭。
- SIGINT/SIGTERM 与 stdio EOF 复用同一个 cleanup promise，重复关闭/重复信号幂等。
- 新增 `AgentMCP/test/stdio-cleanup.test.js`：用真实官方 client 启动真实 server，完成/取消扫描后 `client.close()`，等待进程退出，断言测试 TMPDIR 下不新增 `spacejudge-mcp-*`；另含 SIGTERM 变体。
- `bench:local` 同样在 close 并等待进程退出后比对任务根，`leakedTaskRoots` 与 `passed` 绑定（budget 0）。
- 测试与基准通过显式 `TMPDIR`（SDK 的 `getDefaultEnvironment()` 默认不传 `TMPDIR`，子进程会回落到 `/tmp`）保证断言检查的是 server 实际使用的临时目录。

运行时区分：**Pi 自测在 Node v22.23.2 和仓库最低 Node v20.16.0 两个运行时上均验证**：`npm run build`、`npm run typecheck`、`npm test`（31/31）、`npm run bench:local`（`passed:true`、`leakedTaskRoots:[]`）全部通过。Codex 的 Node 20.16.0 验收发现并报告了本问题。修复仅使用 Node 20 已有 API（`StdioServerTransport` 子类、`process.kill`、`fs`）。

**未清理项**：发现修复前遗留的 `spacejudge-mcp-*` 目录（位于 server 子进程实际使用的 `/private/tmp`）大量存在；按评审要求，Pi 未删除这些目录，交由 Codex 在验证后清理。修复后的运行不再产生新泄漏。
