# SpaceJudge 工程文档

这里保存产品与工程决策。原型 HTML 只表达交互，不作为原生实现或性能证明。

公开仓库保留工程设计与历史验收摘要，本机路径匿名化为 `/Users/example`；`output/` 构建、日志、扫描快照及个人清理记录不公开。历史证据链接只在原验收机器上可用，不代表源码仓库包含这些产物。

## 当前基线

- 开源与分发：MIT 源码＋自愿参与的未公证测试版；[v0.5.2](https://github.com/JoneZhu/SpaceJudge/releases/tag/v0.5.2) 已公开提供 DMG，发布记录见[版本说明](releases/v0.5.2.md)，构建、校验和安装边界见[实验性测试包](runbooks/experimental-build.md)。正式公证发行仍未完成。

- 产品：macOS 只读磁盘空间浏览器，不包含清理执行；0.5.1 增加用户明确确认的外部 Codex 桌面草稿交接，没有内置模型会话。
- 核心体验：快速得到可用结果、按面积浏览、单击展开、双击进入、面包屑返回。
- 技术路线：Swift 6、SwiftUI 应用壳、AppKit/Core Graphics 空间图、Darwin 批量文件枚举、SQLite 快照。
- 交付方式：当前由 Codex 直接设计、实现、测试和修正，不再交给 Pi。历史 Pi 分工记录保留。
- 当前进度：Phase 0–5D-A、Phase 6、本地 CLI/MCP、双单位和 Agent 热点已验收。原生本机 MVP 的 0.4.0 更新增加启动页、扫描中已知占用和保留位置的后台全范围刷新。启动入口见文档38，本轮与历史证据分开记录在文档37。局部目录合并刷新未实现；2026-10-01 经授权发布 v0.5.2 未公证测试包，发布脚本测试增至135项，跨机器安装验收仍未完成。
- 当前安装：0.5.2 build 7，右键交接清理目标、可选准确路径和占用上下文，并附带原生 CLI 用法，无专用登录与内置 Node。596 项 Swift 测试、109 项发布脚本测试通过；Codex 内部接收及真实模型效果待人工确认，见文档42。

## 文档地图

1. [MVP 产品规格](01-mvp-spec.md)
2. [系统架构](02-system-architecture.md)
3. [扫描引擎设计](03-scan-engine.md)
4. [数据、计量与持久化](04-data-and-storage.md)
5. [测试、基准与验收](05-testing-and-acceptance.md)
6. [实施路线与 Pi 协作](06-implementation-and-pi.md)
7. [Phase 0 验收基线](07-phase-0-baseline.md)
8. [Phase 1 实施设计](08-phase-1-design.md)
9. [Phase 1 验收基线](09-phase-1-baseline.md)
10. [Phase 2 实施设计](10-phase-2-design.md)
11. [Phase 2 验收基线](11-phase-2-baseline.md)
12. [Phase 3 实施设计](12-phase-3-design.md)
13. [Phase 3 验收基线](13-phase-3-baseline.md)
14. [Phase 4 实施设计](14-phase-4-design.md)
15. [Phase 4 验收基线](15-phase-4-baseline.md)
16. [Phase 5A 实施设计](16-phase-5a-design.md)
17. [Phase 5A 验收基线](17-phase-5a-baseline.md)
18. [Phase 5B 实施设计](18-phase-5b-design.md)
19. [Phase 5B 验收基线](19-phase-5b-baseline.md)
20. [Phase 5C 实施设计](20-phase-5c-design.md)
21. [Phase 5C 验收基线](21-phase-5c-baseline.md)
22. [Phase 5D 实施设计](22-phase-5d-design.md)
23. [Phase 5D-A 验收基线](23-phase-5d-a-baseline.md)
24. [Phase 6 本地 CLI 与 MCP 设计](24-phase-6-design.md)
25. [Phase 6 验收基线](25-phase-6-baseline.md)
26. [Phase 6 真实整机扫描观察](26-phase-6-real-machine-scan.md)
27. [Phase 6 真实大目录可靠性修复设计](27-phase-6-scale-reliability-fix.md)
28. [Phase 6 大目录事件顺序修复验收基线](28-phase-6-scale-fix-baseline.md)
29. [Phase 6 CLI/MCP 双单位大小输出设计](29-phase-6-dual-size-output.md)
30. [Phase 6 CLI/MCP 双单位大小输出验收基线](30-phase-6-dual-size-baseline.md)
31. [Phase 6 Agent 全局热点查询设计](31-phase-6-agent-hotspots.md)
32. [Phase 6 Agent 全局热点查询验收基线](32-phase-6-hotspots-baseline.md)
33–35. 本机个人清理记录仅本地保留，不纳入公开仓库。
36. [原生MVP界面与关键路径设计](36-native-mvp-finishing-design.md)
37. [原生MVP独立验收与本机交付](37-native-mvp-acceptance.md)
38. [原生MVP使用说明](38-native-mvp-quickstart.md)
39. [Codex ACP 桥接（0.5.0 历史设计）](39-agent-bridge.md)
40. [Agent 桥接（0.5.0 历史验收）](40-agent-bridge-acceptance.md)
41. [Codex 桌面草稿交接与 0.5.1 安装验收](41-codex-desktop-handoff.md)
42. [Codex 清理上下文与 CLI 使用](42-cleanup-context-and-cli.md)
43. [术语表](glossary.md)

架构决策记录保存在 `adr/`。任何会影响兼容性、数据语义、权限或模块边界的变化，都先新增或更新 ADR，再进入实现。

## 文档状态约定

- `Proposed`：待真实实现验证，可以调整。
- `Accepted`：当前实现必须遵守；修改需要 ADR。
- `Superseded`：已被新决策替代，但保留历史原因。

当前文档是第一版工程基线。性能数字是验收目标，不是对所有磁盘和文件系统的营销承诺。
