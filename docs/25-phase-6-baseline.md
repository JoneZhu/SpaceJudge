# Phase 6 验收基线：本地 CLI 与 stdio MCP Agent 接口

状态：Accepted

日期：2026-09-27

## 1. 结论

Phase 6 已完成 Codex 设计、真实本机 Pi 实施、四轮集中审查与返修，以及 Codex 独立验收。

SpaceJudge 现在既能作为原生 Swift CLI 使用，也能通过官方 MCP stdio 协议向 Codex、ChatGPT 桌面环境或其他本地 MCP client 暴露七个有界工具。Agent 不能提交任意路径，只能操作启动时映射出的不透明 `rootId`；扫描、查询和取消都不读取文件内容、不修改用户文件、不监听网络端口。

验收结果：**6A 与 6B 均通过，Phase 6 Accepted。** 当前改动尚未 commit、tag 或 push；没有修改用户的全局 MCP 配置，也没有安装、发布或远程部署服务。

## 2. 最终实现

### 2.1 Swift 原生 CLI（6A）

- 新增 `SpaceJudgeAgentCLIKit` 与 `spacejudge-agent-cli`，直接复用已有扫描引擎和 SQLite 快照。
- 提供 `volume`、`scan`、`status`、`children`、`issues` 五个命令；stdout 为有界 NDJSON/JSON，标识与计数使用无精度损失的十进制字符串。
- 只有 SQLite 已持久化的终态才会作为 `completed`、`cancelled` 或 `failed` 发布；无法确认的写入失败只返回 `INTERNAL`，不伪造终态。
- workspace 必须是调用方预先创建、当前用户拥有、非符号链接且权限不超过 `0700` 的真实目录；CLI 不会替调用方创建或 chmod 目录。
- SIGINT/SIGTERM 走协作式取消并持久化终态；路径、用户名和 issue 样例不会泄漏到协议错误。

### 2.2 TypeScript stdio MCP（6B）

- 使用官方 TypeScript MCP SDK v2 与 stdio transport，最低 Node 20。
- 固定七个工具：`list_allowed_roots`、`get_volume_usage`、`start_scan`、`get_scan_status`、`list_children`、`get_scan_issues`、`cancel_scan`。
- 授权根仅在进程启动参数中出现；模型侧只接收 `root-1` 等不透明 ID。最多 64 个唯一根；同一实例最多一个在途扫描。
- JSON schema 限制 UUID、UInt64、枚举、字符串长度、数组大小和 `additionalProperties=false`；native stdout 还经过严格事件状态机与字节级行长上限。
- 正常 stdio EOF、取消、SIGTERM 和启动失败共享幂等清理路径；子进程被精确回收，任务目录不会残留。
- MCP 层没有 HTTP、TCP、UDP、远程认证或运行时网络访问。

## 3. Codex 审查与返修

四轮审查解决了以下关键问题：

1. CLI 不再静默修改已有 workspace 权限；数据库被限制为 workspace 的直接子文件。
2. `started` 之后的失败只有在终态确实持久化时才对外发布；不可确认状态失败关闭。
3. native 事件流增加完整状态机，拒绝 terminal-before-start、重复 started/terminal、畸形进度、scanId 不匹配和 started 后 error。
4. 行长按字节而不是 UTF-16 单元限制；授权根上限、输出 schema、数组上限与运行时行为保持一致。
5. 启动失败先等待子进程回收再清理；服务 shutdown 不会删除仍被存活子进程使用的目录。
6. 真实官方 client 的 stdio EOF 曾暴露任务根泄漏；最终由 transport close 与信号共用的幂等 shutdown 修复，并加入完成、取消和 SIGTERM 三条真实生命周期回归。
7. 基准脚本改为使用实际返回的根节点 ID，并把 `completed` 终态和零任务根泄漏列为硬门。

最终审查没有剩余阻断级或高优先级问题。

## 4. Codex 独立自动验收

| 检查 | 结果 |
| --- | --- |
| `swift build -c release --product spacejudge-agent-cli` | 通过 |
| `swift test` | 434 tests / 59 suites，通过 |
| Node 20.16.0 `npm run build` | 通过 |
| Node 20.16.0 `npm run typecheck` | 通过 |
| Node 20.16.0 `npm test` | 31 passed / 0 failed |
| 官方 client：initialize、instructions、tools/list、七工具端到端 | 通过 |
| 真实 stdio EOF：完成/取消；SIGTERM | 服务退出且零新增任务根 |
| 协议、错误、stderr 路径与用户名泄漏检查 | 通过 |
| 运行中进程网络审计 | TCP listener 0；UDP socket 0 |
| `git diff --check` | 通过 |

Swift 回归覆盖 CLI schema、真实完成、真 SIGINT 取消、失败持久化、权限、数据库位置、非法标识与脱敏。Node 回归覆盖官方 client 互操作、严格 schema、并发、幂等取消、协议状态机、超长行、提示词式文件名、进程和目录生命周期。

## 5. 独立性能基准

Codex 使用 Node 20.16.0 运行 `npm run bench:local`，fixture 为 200 个目录、每目录 100 个文件，共 20,000 entries：

| 指标 | 实测 | 验收门 |
| --- | ---: | ---: |
| 扫描终态 | `completed` | 必须 `completed` |
| 扫描时间 | 164 ms | 记录项 |
| 查询后 RSS | 95.7 MiB | < 150 MiB |
| 100 次查询 P50 | 26.49 ms | 记录项 |
| 100 次查询 P95 | 30.55 ms | < 100 ms |
| 查询最大值 | 37.71 ms | 记录项 |
| 新增任务根 | 0 | 0 |

该数据是当前 Apple Silicon 本机、未控制缓存状态下的工程验收结果，不是跨机器营销承诺。

## 6. 安全边界与已知限制

- 这是本地 stdio MCP，不是远程 MCP；ChatGPT 网页端无法直接访问本机进程。
- 服务只观察元数据和空间占用，不读取文件内容，不执行文件名中的文字，不删除、移动、打开或清理文件。
- `start_scan` 和 `cancel_scan` 会改变本地任务与缓存状态，所以不是 read-only 工具；它们仍然不修改用户文件，标注为非 destructive。
- 当前没有 AI 判断、清理建议、自动删除、网络服务、OAuth、多用户隔离或远程部署。
- 本阶段没有自动写入任何客户端配置。实际启用时，用户仍需选择明确授权目录，并把 runbook 中的本地命令登记到自己的 MCP client。
- 2026-09-28 的首次真实整机使用发现：2 万 entries 的验收基准不能代表百万级单根扫描；`/` 与用户主目录曾因并发事件乱序以 `INTERNAL` 失败。该缺陷已通过 FIFO 单写者事件门修复，并在 676 万节点主目录与 840 万节点 `/` 上完成独立验收，详见 [修复设计](27-phase-6-scale-reliability-fix.md) 与 [修复验收基线](28-phase-6-scale-fix-baseline.md)。
- 超大扫描的峰值 RSS 仍会增长到约 1.06–1.29 GB；内存扩展性与更细的无路径内部诊断码仍是开放问题。

## 7. 文档与仓库状态

- [Phase 6 设计](24-phase-6-design.md)：Accepted。
- [ADR-0011](adr/0011-local-cli-stdio-mcp.md)：Accepted。
- [本地 Agent MCP runbook](runbooks/local-agent-mcp.md)：当前构建与接入说明。
- [Phase 6 Pi 交付报告](phase-6-pi-report.md)：实施、自测和四轮返修记录。
- [Phase 6 真实整机扫描观察](26-phase-6-real-machine-scan.md)：首次实际整机分析的失败、根因与修复后对照。
- [Phase 6 大目录事件顺序修复验收基线](28-phase-6-scale-fix-baseline.md)：自动化、真实整机、安装与资源证据。
- Pi 会话：`/var/folders/4t/qf2d297d4_s4hycck7dyfdmw0000gn/T/spacejudge-phase6-pi.cBIi7R`，session `01a0e246-dd7f-7237-ace4-133d553fd781`。
- Codex 验收产生的 160 个旧版泄漏任务根和 1 个验收临时目录已移入废纸篓，可恢复；最终修复后的复测与端口审计均为零任务根残留。
- 工作树尚未 commit、tag 或 push；未修改全局 MCP 配置，未发布服务。
