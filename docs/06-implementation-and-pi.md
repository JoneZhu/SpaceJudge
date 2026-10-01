# 实施路线与 Pi 协作

状态：Accepted

## 1. 固定分工

- Codex：需求澄清、架构、接口、阶段任务单、独立 code review、复测、验收、必要修正、文档归档。
- Pi：阶段内产品代码、测试、普通错误修复、必要的使用说明和交付报告。
- 用户：决定产品方向和超出既定范围的重大取舍。
- commit、push、签名、公证和发布由 Codex 在验收通过后按用户授权统一处理。

Codex 与 Pi 不同时修改同一产品文件。原始 Pi 会话和日志保存在忽略目录；可复用结论回写 `docs/`，不把思考日志当文档。

## 2. 阶段计划

### Phase 0：核心契约与纯算法

状态：已完成并经 Codex 独立验收，详见 [Phase 0 验收基线](07-phase-0-baseline.md)。

交付：

- `Package.swift`，macOS 14 / Swift 6。
- `SpaceJudgeDomain`：类型、事件、协议、聚合不变量。
- `SpaceJudgeTreemap`：确定性 squarified layout 和裁剪模型。
- 对应单元测试。
- `spacejudge-core-smoke` CLI，用内存示例树输出布局 JSON。

不包含：Darwin syscall、SQLite、SwiftUI、真实文件扫描。

验收门：`swift test` 通过；并发警告为 0；布局不变量测试通过；接口与文档一致。

### Phase 1：扫描器正确性

状态：已完成并经 Codex 独立验收，详见 [Phase 1 验收基线](09-phase-1-baseline.md)。

交付：

- ReferenceEnumerator。
- Darwin 属性 buffer parser。
- DarwinBulkEnumerator。
- 有界调度、取消、错误归类、硬链接去重。
- 临时目录集成测试和差分测试。

验收门：两种 enumerator 规范化结果一致；错误与取消路径通过；无 FD 泄漏。

### Phase 2：持久化与基准

状态：已完成并经 Codex 独立验收，详见 [Phase 2 验收基线](11-phase-2-baseline.md)。

交付：

- SQLite repository、schema、迁移。
- 批量写、UI snapshot 查询。
- fixture generator 与 benchmark CLI。
- 第一份可复现性能基线。

验收门：100 万节点数据测试；关键查询与内存目标有真实报告。

### Phase 3：macOS 应用壳

状态：已完成并经 Codex 独立验收，详见 [Phase 3 验收基线](13-phase-3-baseline.md)。

交付：

- Xcode app、目录选择、权限状态、Privacy Manifest。
- 扫描生命周期和容量小字。
- SwiftUI 工具栏 / 弹窗。
- 最大项目诊断列表。

验收门：真实文件夹端到端扫描、取消、错误汇总。

### Phase 4：高性能 treemap UI

状态：已完成并经 Codex 独立验收，详见 [Phase 4 实施设计](14-phase-4-design.md) 与 [Phase 4 验收基线](15-phase-4-baseline.md)。

交付：

- AppKit/Core Graphics treemap。
- 增量布局、命中测试、导航、hover、右键。
- 深浅色、窗口尺寸、基本可访问性。
- 与 HTML 原型的行为核对。

验收门：代表性真实扫描与 UI 性能目标通过。

### Phase 5A：扫描对账与端到端规模基准

状态：已完成并经 Codex 独立验收，详见 [Phase 5A 实施设计](16-phase-5a-design.md) 与 [Phase 5A 验收基线](17-phase-5a-baseline.md)。

交付：

- 卷容量与当前扫描范围的中性对账。
- 真实目录 → scanner → SQLite → 重开校验的 10 万 / 50 万 / 100 万节点基准。
- 取消延迟、峰值 RSS、FD 与临时产物清理证据。

### Phase 5B：启动盘可见卷组与边界安全

状态：已完成并经 Codex 独立验收，详见 [Phase 5B 实施设计](18-phase-5b-design.md) 与 [Phase 5B 验收基线](19-phase-5b-baseline.md)。

交付：

- APFS 启动卷组 plan。
- firmlink projection 与真实 mount boundary。
- 路径脱敏的非递归 volume-plan probe。

### Phase 5C：快照缓存自保护与异常恢复

状态：已完成并经 Codex 独立验收，详见 [Phase 5C 实施设计](20-phase-5c-design.md) 与 [Phase 5C 验收基线](21-phase-5c-baseline.md)。

交付：

- 单会话、单扫描 snapshot 生命周期与旧快照回收。
- 工作缓存扫描边界、白名单启动清理和 `0700/0600` 权限。
- 512 MiB 开始门、256 MiB 运行门、页复用与有界 checkpoint / incremental vacuum。
- 取消终态持久化、无路径错误提示和真实 App 恢复验证。

### Phase 5D：直接分发与发布硬化

状态：5D-A“发布工程就绪”已实现并经 Codex 独立验收，首个干净 Git 基线已建立；详见 [Phase 5D 实施设计](22-phase-5d-design.md)、[Phase 5D-A 验收基线](23-phase-5d-a-baseline.md) 与 [ADR-0010](adr/0010-developer-id-dmg-release.md)。5D-B 真实签名、公证、staple 与 Gatekeeper 仍等待 Developer ID Application、Keychain notary profile 与明确授权。

已完成（5D-A）：

- Release Hardened Runtime、无 Sandbox、无 exception entitlement，完整 AppIcon 与中英文本地化只读 usage description；
- `scripts/release/` 两级流水线与 fail-closed 自测；
- universal2 ad-hoc 本地 DMG 与 `distributionReady=false` manifest；
- 正式 `distribute.sh` 的 preflight/签名/公证/staple/Gatekeeper 实现；建立干净 HEAD 后重新预检，当前只因无 Developer ID 明确失败。

仍待 5D-B：Developer ID 签名链、notarization Accepted、staple、Gatekeeper quarantine、Intel 实机矩阵。

不自动包含 AI 或清理；这两项需要新的产品规格与安全 ADR。

## 3. 每次交接文件必须包含

- 目标、工作目录、分支和需先读文档。
- 允许修改和禁止修改范围。
- 必须保留的用户成果。
- 已定设计与 Pi 可自主决定的实现细节。
- 可执行验收命令和预期结果。
- 报告、日志、截图或基准输出路径。
- 服务 PID / 端口管理约束。

## 4. 反馈规则

- Pi 完成整个阶段并自测后一次性交付。
- Codex 把问题按“证据、期望、复现、验证”批量反馈。
- 同一错误经一次有依据修复仍无进展，Pi 停止重试并报告。
- 发现架构边界冲突、需要删除用户数据、需要新增权限或依赖时立即停下确认。
- 验收只覆盖当前阶段，不顺带扩功能。

## 5. 文档积累规则

- 产品范围变化：更新 `01-mvp-spec.md`。
- 模块或协议变化：更新 `02-system-architecture.md`。
- 扫描语义与边界：更新 `03-scan-engine.md`。
- schema / 计量变化：更新 `04-data-and-storage.md`。
- 新失败案例和基准：更新 `05-testing-and-acceptance.md` 或 `docs/runbooks/`。
- 重大取舍：新增 ADR，写明背景、选项、决策、后果和替代条件。
- 可重复测试路径：沉淀脚本和 fixture，不只保留自然语言。

## 6. 当前阶段入口

Phase 0–5D-A 已完成并经 Codex 独立验收，首个干净 Git 基线已经建立。Phase 5D 已确定采用 Developer ID + 公证 DMG 直接分发，并拆成 5D-A“发布工程就绪”和 5D-B“真实分发验证”。5D-A 已冻结 Release Hardened Runtime、AppIcon、本地化 usage description、credential-independent 本地 DMG、fail-closed 发布脚本与 runbook；在 Developer ID Application、Keychain notary profile 和用户真实发布指令都具备前，不执行正式签名、公证或发布，也不得顺带加入删除、清理建议、AI 或网络能力。

Phase 6 已完成：6A（Swift agent CLI）与 6B（TypeScript stdio MCP 适配器）由 Pi 实现、自测并按四轮审查修复，Codex 随后在 Swift 6.3.3 与最低 Node 20.16.0 上独立完成协议互操作、隐私、取消、资源清理、性能和全量回归验收。首次真实整机使用随后暴露多 worker 满缓冲下的 event revision 乱序；Pi 按 [可靠性修复设计](27-phase-6-scale-reliability-fix.md) 实施，Codex 已在 676 万节点主目录和 840 万节点 `/` 上独立验收，证据见 [修复验收基线](28-phase-6-scale-fix-baseline.md)。当前超大扫描内存优化仍开放；未修改任何全局 MCP 配置，也未扩大为删除、AI、文件内容读取或网络能力。
