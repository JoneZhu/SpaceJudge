# Pi 实施任务：CLI/MCP bytes + GB 双单位输出

## 基线与保护

- 仓库：`/Users/example/Documents/ChatGPT/SpaceJudge`
- 分支：`master`，HEAD `43f55d8bc80e`
- 必读：`docs/29-phase-6-dual-size-output.md`、`docs/24-phase-6-design.md`、`docs/runbooks/local-agent-mcp.md`。
- 工作树包含 Phase 6、规模修复和大量未提交成果，全部保护；禁止 reset、checkout、clean、覆盖或无关格式化。

## 目标

让 CLI 与 MCP 的所有容量字段同时返回精确 bytes 与十进制 GB，保持现有脚本兼容、MCP 严格 schema、隐私边界和扫描性能。

## 必须实现

1. Swift 输出层新增整数算术 GB formatter：`1 GB = 1_000_000_000 bytes`，固定两位、四舍五入、locale 无关、`UInt64.max` 安全、optional unknown → `null`。
2. 按设计映射为同级字段，覆盖 CLI volume、scan progress/terminal、status、children items。
3. 所有原 bytes 字段原样保留，仍为十进制字符串或 `null`；GB 也必须是字符串或 `null`。
4. TypeScript MCP 使用 `BigInt` 从 bytes 计算同样的 GB，不经过 `Number`；更新 output schema、structuredContent 和人类文本摘要。
5. 更新 Phase 6 设计、runbook 与一份 `docs/phase-6-dual-size-pi-report.md`，不得自行把设计状态改为 Accepted。

## 禁止事项

- 不改数据库 schema，不落库 GB；
- 不删除 bytes 字段，不改字段类型，不输出仅人类文本；
- 不引入 GiB、自动单位切换、AI、清理或删除能力；
- 不提交、不 push、不发布、不改全局 MCP 配置；
- 不覆盖当前已安装版本，安装由 Codex 验收后处理。

## 验收

- Swift formatter 边界：0、4,999,999、5,000,000、999,999,999、1,000,000,000、1,005,000,000、`UInt64.max`、nil；
- CLI volume/status/children/scan event 双字段测试；
- Node formatter 与 Swift 表一致；相关工具严格 output schema 与 official client e2e；
- `arch -arm64 swift test` 全量；`cd AgentMCP && npm test` 全量；`git diff --check`；
- 真机 `volume --root /` 输出 bytes/GB 且数学一致；
- 不新增后台服务和临时数据残留。

## 交付

报告 `docs/phase-6-dual-size-pi-report.md`：列出修改文件、换算算法、字段矩阵、精确命令/退出码、测试数量、真实输出、限制、临时产物和 Git 状态。普通实现错误自行修复后统一报告；若必须破坏现有 schema，停止并报告。
