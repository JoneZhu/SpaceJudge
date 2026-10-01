# Phase 6 Agent 热点查询 Pi 实施任务

状态：待 Pi 实施

日期：2026-09-28

以 [Agent 全局热点查询设计](31-phase-6-agent-hotspots.md) 和
[ADR-0012](adr/0012-agent-hotspots.md) 为冻结契约，实现 Swift CLI `hotspots` 与 MCP
`get_hotspots`。

必须保持：

- 现有双单位、授权、隐私、严格 schema、生命周期与七个既有工具行为；
- 复用 `childPage` 做有界最佳优先遍历，不新增数据库表、schema version 或全局索引；
- running/cancelling 返回冲突，终态 revision 一致性 fail-closed；
- ancestor-inclusive 明示不可求和；名称只在 structured content；
- Pi 完成实现、自测、普通修复和实施报告；不 commit/push/发布/安装，不修改全局 MCP 配置。

交付报告：`docs/phase-6-hotspots-pi-report.md`。
