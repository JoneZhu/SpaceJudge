# SpaceJudge 工程文档

这里保存产品与工程决策。原型 HTML 只表达交互，不作为原生实现或性能证明。

## 当前基线

- 产品：macOS 只读磁盘空间浏览器，第一版不包含 AI 判断和清理执行。
- 核心体验：快速得到可用结果、按面积浏览、单击展开、双击进入、面包屑返回。
- 技术路线：Swift 6、SwiftUI 应用壳、AppKit/Core Graphics 空间图、Darwin 批量文件枚举、SQLite 快照。
- 交付方式：Codex 设计与独立验收，Pi 实现、自测和普通修复。
- 当前进度：Phase 0–5D-A 已验收，首个干净 Git 基线已建立；Phase 5D-B 真实 Developer ID 签名、公证和分发验证等待发布凭据与明确授权。

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
24. [术语表](glossary.md)

架构决策记录保存在 `adr/`。任何会影响兼容性、数据语义、权限或模块边界的变化，都先新增或更新 ADR，再进入实现。

## 文档状态约定

- `Proposed`：待真实实现验证，可以调整。
- `Accepted`：当前实现必须遵守；修改需要 ADR。
- `Superseded`：已被新决策替代，但保留历史原因。

当前文档是第一版工程基线。性能数字是验收目标，不是对所有磁盘和文件系统的营销承诺。
