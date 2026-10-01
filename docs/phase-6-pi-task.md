# Pi 实施任务：Phase 6 本地 CLI + stdio MCP

## 基线与先读文档

- 仓库：`/Users/example/Documents/ChatGPT/SpaceJudge`
- 分支：`master`
- 起始提交：`43f55d8bc80e`
- 必读：`docs/24-phase-6-design.md`、`docs/adr/0011-local-cli-stdio-mcp.md`、`docs/02-system-architecture.md`、`docs/03-scan-engine.md`、`docs/04-data-and-storage.md`、`docs/05-testing-and-acceptance.md`。
- 工作树中 Codex 新增/修改的 Phase 6 设计文档属于保护成果，禁止覆盖、回退或擅自改语义。

## 目标

完整实现 Phase 6A 和 6B：新增稳定的 Swift agent CLI，并用官方 TypeScript MCP SDK v2 构建只走 stdio 的七工具适配器；完成自测与报告，交给 Codex 独立验收。

## 必须实现

1. `SpaceJudgeAgentCLIKit` 与 `spacejudge-agent-cli`，严格实现设计文档中的 `volume/scan/status/children/issues` NDJSON 契约、字符串 UInt64、持久化后发布和信号取消。
2. `AgentMCP/`，锁定 `@modelcontextprotocol/server`、`@modelcontextprotocol/client` 2.1.0 与 Zod 4.6.5，Node engine >=20，提交 `package-lock.json`。
3. 启动时 `--allow-root` 验证、canonicalize、去重和 opaque root ID；模型不能传任意路径。
4. 七个且仅七个工具、严格 input/output schema、正确 annotations、服务 instructions 与不可信文件名防护。
5. 单并发扫描、精确 PID 取消、有界 stdout/stderr/任务/缓存、私有 workspace、无孤儿进程。
6. 新增 `docs/runbooks/local-agent-mcp.md` 和 `docs/phase-6-pi-report.md`；在 `docs/05-testing-and-acceptance.md`、`docs/06-implementation-and-pi.md` 中标明“Pi 已完成，等待 Codex 验收”，不得自行宣称 Accepted。

## 禁止事项

- 不修改/删除/移动/打开用户文件，不读取文件内容；
- 不加入清理建议、AI 判断、shell 工具、任意路径工具、HTTP、网络监听、远程 MCP、OAuth；
- 不使用 `killall`/`pkill`；不把绝对路径、用户名或文件名写入日志和文本摘要；
- 不降级为 MCP v1，不手写 MCP 帧，不用 `npx` 作为正式运行入口；
- 不修改用户全局 MCP 配置，不发布 npm 包，不签名/公证/发布 App；
- 不提交、不打 tag、不 push；由 Codex 验收后处理基线。

## 可自主决定

在不改变公开 schema、权限边界、持久化语义和依赖大版本的前提下，可自行组织内部类型、文件拆分和测试 helper。若 SDK 2.1.0 类型签名与设计措辞不同，做最小的语义等价适配，并在报告中记录；不得用旧 SDK 或放宽 schema 绕过。

## 自测要求

- 全量 Swift 回归与新增 CLI 测试；
- `npm ci && npm run build && npm test`；
- 官方 TypeScript client 通过 stdio 做 initialize、instructions、tools/list 和七工具端到端；
- 信号取消最终落库为 cancelled；
- 无效 root/scan/node、并发冲突、重复取消、提示词式文件名；
- 连续 10 次任务的进程、句柄和临时目录清理；
- 所有协议、错误和日志的绝对路径/用户名泄漏扫描。

## 交付报告

`docs/phase-6-pi-report.md` 必须列出：改动文件、公开协议、执行的精确测试命令与结果、资源/性能数据、已知限制、未完成项。若任何验收项未过，明确标红并停止宣称完成。
