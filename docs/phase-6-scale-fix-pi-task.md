# Pi 实施任务：Phase 6 大目录事件乱序修复

## 基线与先读文档

- 仓库：`/Users/example/Documents/ChatGPT/SpaceJudge`
- 分支：`master`
- 起始提交：`43f55d8bc80e`
- 必读：`docs/27-phase-6-scale-reliability-fix.md`、`docs/26-phase-6-real-machine-scan.md`、`docs/08-phase-1-design.md`、`docs/05-testing-and-acceptance.md`。
- 工作树已有未提交的 Phase 6 CLI/MCP 与文档改动，全部属于保护成果；禁止 reset、checkout、覆盖或重排无关改动。

## 目标

修复 `FileSystemScanEngine` 在多 worker + 满 event buffer 下因 actor 重入导致 batch revision 乱序的问题，并用确定性并发背压测试、真实持久化集成和本机 `workspace` 扫描证明修复有效。

## 已确认事实

- 扫描引擎单独扫描 `workspace` 成功：639,344 files、55,441 directories、0 issue。
- 扫描 + SQLite 失败：`revisionNotContiguous(expected: 284, found: 286)`。
- 失败库 `integrity_check = ok`；store 的连续 revision 校验正确，不得放宽。
- 现有背压测试只有一个 worker，因此漏掉并发 actor 重入。

## 实现要求

1. 所有 `ScanEvent` 投递经过单写者 FIFO 事件门；满缓冲重试期间不得让后续 emit 越过。
2. release 必须把所有权直接交给队首等待者，不能制造可插队的空闲窗口。
3. 保留 `.bufferingOldest` 的有界真实背压；禁止 `.unbounded`、禁止第二个无界事件数组。
4. batch revision 必须严格连续；禁止修改/放宽 SQLite 连续性校验。
5. cancel、consumer termination 和唯一 terminal 语义不得退化；等待 emitter 必须可退出。
6. 不修改公开 CLI/MCP schema、SQLite schema、扫描计量/边界、权限、安装或全局配置。
7. 不加入 AI、删除或清理执行能力，不读取文件内容。

## 测试要求

- 新增确定性多 worker 背压回归：4 workers、buffer 1、多子目录、慢消费者、连续 revision、节点完整、唯一 terminal。
- 修复前测试应能暴露问题；报告说明触发机制。修复后 targeted 测试重复至少 20 次。
- 新增或增强真实 engine + runner + SQLite 集成，重开库核对根节点、根 aggregate、计数与 last revision。
- 覆盖满 buffer 时 cancel 和 consumer termination，不死锁、不漏 terminal、不残留 FD/spool。
- `swift test` 全量通过。
- Release `spacejudge-persist-smoke` 扫描 `/Users/example/workspace` 必须完成；记录节点、revision、数据库大小、wall time、峰值 RSS。
- Phase 6 Node/MCP 测试至少执行 `cd AgentMCP && npm test`，证明公开适配层没有回归。

## 执行边界

- 只管理本任务创建且有精确路径/PID 的产物与进程；禁止 `killall`、`pkill`。
- 可以删除本任务自己创建的临时 fixture/数据库，不能删除用户文件。
- 不提交、不打 tag、不 push、不发布、不改用户全局 MCP 配置。
- 普通实现问题自行修复后统一报告；若设计不成立或必须改公开契约，先停止并报告。

## 交付

写入 `docs/phase-6-scale-fix-pi-report.md`，包含：

- 根因和修复结构；
- 修改文件；
- 精确测试命令、退出码与结果；
- 20 次重复结果；
- 真实 `workspace` 扫描数据；
- 资源/性能、限制、未验证项；
- 临时产物是否清理、是否存在后台服务；
- Git 改动范围和未提交说明。

完成实现、自测和普通修复后统一交付，Codex 将独立审查和验收。
