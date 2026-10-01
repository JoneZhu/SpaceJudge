# ADR-0011：采用原生 Swift CLI + TypeScript stdio MCP 适配器

状态：`Accepted`
日期：2026-09-27

## 背景

SpaceJudge 需要被 ChatGPT、Codex 等 Agent 调用，同时必须复用现有 Swift 扫描性能与 SQLite 快照语义，并维持“不修改用户文件、不接受模型任意路径”的边界。

## 选项

1. 只依赖 UI 自动化：无需协议，但慢、脆弱、难以分页和稳定验收。
2. 只提供 CLI：适合脚本，却不能向 Agent 提供标准工具 schema、注解和生命周期。
3. 在 TypeScript 中重新实现扫描：MCP 简单，但复制最关键的性能和文件系统语义。
4. 在 Swift 中手写 MCP/JSON-RPC：依赖少，但协议版本、能力协商和兼容性风险由项目自行承担。
5. Swift CLI 提供窄协议，TypeScript 使用官方 MCP SDK 做 stdio 适配。

## 决策

采用选项 5。

- Swift 是唯一扫描与快照事实来源；
- MCP 层不接触任意路径，只处理启动时建立的 root ID 与自身 scan ID；
- 使用官方 TypeScript MCP SDK v2 与 stdio transport；
- 不启动 HTTP 服务，不开放网络，不手写 MCP 帧；
- 工具表面固定为八个只读观察/任务控制工具（原七个，由 [ADR-0012](0012-agent-hotspots.md) 增加只读的 `get_hotspots`，决策边界不变）；
- `start_scan` 和 `cancel_scan` 因改变任务/缓存状态标注为非 read-only，但都标注非 destructive。

## 后果

正面：复用高性能原生核心；协议可独立测试；Agent 接入标准；权限边界集中且可审计。
代价：需要同时维护 Swift NDJSON 契约和一个小型 Node.js 包；本地使用需要 Node 20+。
风险控制：提交 lockfile、限制输出/进程/缓存、精确 PID 取消、路径脱敏、官方 client 端到端测试。

## 替代条件

只有在成熟、受维护的 Swift MCP SDK 能覆盖所需协议版本并通过相同互操作测试，或产品决定完全取消 MCP，才重新评估本决策。远程 MCP、OAuth、删除/清理工具均不属于此 ADR。
