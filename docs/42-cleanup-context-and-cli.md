# Codex 清理上下文与 CLI 使用

2026年10月1日，SpaceJudge 0.5.2 build 7。目标是帮助用户回答“这里怎么安全清理”，而不是只解释占用。
已实现并安装右键清理方案草稿、准确路径选择、相对位置与随 App 附带的原生 CLI。
这里记录可复用的方法、工具契约和本轮证据；不表示已经清理用户磁盘或验证真实模型效果。

## 用户流程和清理目标

扫描结束 → 右键真实文件/目录「用 Codex 分析…」→ 在「用 Codex 制定清理方案」面板检查上下文 → 打开 Codex 草稿 → 用户确认发送。
Codex 的任务是先核查、给可执行清理建议，执行清理须另行明确授权。
结果要求包含清理对象、具体步骤或命令、证据与前提、风险、备份/恢复、预计收益或未知，以及执行后的验证。
允许必要的只读命令及选中目录的定向重扫，不再使用旧提示词“一律不执行命令、不重扫”的限制。

完整目标路径由当前选中扫描根与真实祖先链在运行时还原，不从末级名称猜测。
面板明确显示路径，并提供“提供准确路径”开关；关闭后草稿不携带它，Agent 必须先询问位置。
路径来源不是当前存在性或身份核验，更不是自动授权工作区，Agent 操作前仍需核查。
文件目标不会自动重扫父目录；使用 CLI 的目录扫描前需要用户确认父目录范围。

## 可复用方法

1. 固定目标：路径、用户目标、扫描时间、已知占用、数据完整性与用户限制。
2. 判断用途：应用数据、虚拟磁盘、缓存、项目产物或个人文件。路径与名称只能作为线索，不能当作安全删除证明。
3. 补充事实：优先已有摘要；必要时用 CLI 扫所选目录，用应用自己的只读命令检查对象与依赖。先确认本机/远端以及运行时范围。
4. 提出分级方案：低风险优先，区分可建议、需核查与应保留；未知收益写未知，不把目录占用当作必然释放量。
5. 请求执行授权：删除、prune、停止服务、迁移、reset、清空废纸篓、提权与安装软件都不能因“要清理建议”而自动执行。
6. 验证结果：按同一容量口径比较磁盘可用空间和目录归属大小，记录失败或回滚条件；回 SpaceJudge 按 `⌘R` 刷新原扫描范围。

这是 SpaceJudge 的产品方法，不声称是某个官方“磁盘清理 Agent 标准”。
组织方式参考 OpenAI 的目标、上下文、输出、边界框架，见[官方提示词说明](https://learn.chatgpt.com/docs/prompting)。
系统和软件的数据分别用自身管理入口处理，见 [Apple 存储空间说明](https://support.apple.com/en-ie/102624)。

## Docker 示例和官方依据

用户所给 `com.docker.docker` 摘要显示大部分已捕获占用沿 `Data/vms/0/data` 目录链集中。
这支持 Docker Desktop 数据占用的候选判断，但摘要没有捕获到 Docker.raw 文件或运行时对象清单，不能声称已确认文件可删除。

[Docker Mac FAQ](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/)建议核对实际磁盘镜像占用，并用 `docker system df -v` 等检查对象；空间图不等同于 Docker 对象清单。
新草稿额外要求先检查 Docker context 端点，避免针对错误引擎或远程主机给出清理命令。
建议优先应用管理入口与对象级方法，不直接删除容器目录或虚拟磁盘。
[Docker prune 文档](https://docs.docker.com/engine/manage-resources/pruning/)说明不同对象有不同清理规则，卷可能保存数据；“unused”不证明用户不再需要。
因此不默认推荐 `system prune -a --volumes` 或跳过确认的 `-f`，也不自动运行镜像回收、特权容器或重置命令。
具体软件版本、对象依赖、备份与可回收量仍由 Codex 只读核查后说明。

## 提供给 Codex 的上下文

新上下文由 `CodexCleanupContext` 单独承载，不改变旧 ACP `AgentAnalysisSnapshot` 的 path-free schema。
捕获检查 scan ID、revision、终态、目标 ID、完整祖先关系、根路径约束和读取前后稳定性；路径使用未截断的原始名称，不跟随符号链接。
SQLite 仍不保存完整路径。完整路径仅进入用户可审阅的本地草稿，普通扫描不上传。

字段包含目标准确路径或未提供、来源说明、扫描起止时间、扫描时所在卷容量及来源。
摘要的 capturedAt 只是生成时间。bytes/GB、未知、部分、权限问题和截断信息继续保留。
每项增加从目标起算的 relativePath；名称截断、链断裂、无效组件或过长时不伪造路径。
大项排序使用捕获前沿，避免 Data/vms/0/data 同一占用反复列四行；前沿仍可能是不完整目录，不是真实文件系统叶子或全局 Top-N。
直接子项与前沿仍可能重叠，不能相加。没有捕获到的文件不会仅凭经验补成真实测量。

草稿只用 `codex://new?prompt=...`，不加 workspace/path 参数，不自动发送。
URL 编码后继续限制 16,384 B，逐项收敛摘要；失败时不会改为猜测范围。
原始范围、CLI 用法与安全说明不作为可省略的项目摘要处理。
Codex 使用自身权限和工具，提示词不是硬沙箱。桌面草稿的接收和后续模型行为需用户人工确认。

## CLI 优先的工具能力

CLI 比 MCP 少一个配置步骤，适合本机桌面 Codex 的命令行核查。本版随 App 提供：

```sh
/Applications/SpaceJudge.app/Contents/Helpers/spacejudge-agent-cli --help
```

App 按自身安装位置生成确切 helper 路径，因此改名/移动应用后不依赖固定仓库目录或 PATH。
不自动安装全局 CLI、不修改 Codex MCP 配置。没有找到 helper 的源码构建只提供发现/询问流程，不能冒充已连接工具。
原始独立 CLI 和现有 MCP 保留；本轮没有替换其全局位置或配置。

| 命令 | 能力与边界 |
| --- | --- |
| `volume --root DIR` | 所在卷容量，bytes 与 GB；系统来源与未知值明确 |
| `scan --root DIR --database NEW_DB --workspace PRIVATE_DIR` | 对当前目录独立扫描，元数据只读；仅写任务私有快照 |
| `status --database DB --scan-id UUID` | 判断扫描结果与完整性 |
| `children --database DB --scan-id UUID --node-id U64 --limit 20` | 直接子项查询 |
| `hotspots --database DB --scan-id UUID --node-id U64 --limit 20` | 跨层热点；祖先/后代可能重复，不可相加 |
| `issues --database DB --scan-id UUID` | 扫描问题摘要 |

草稿给出准确路径的 shell 参数转义及私有 `mktemp` 工作区示例，不把名称插进可执行脚本语法。
`scan` 用新 DB，工作区须存在、当前用户拥有、0700；建议在 `/private/tmp` 新建独立目录，不能选择用户数据目录作为 workspace。
如果所选目标本身覆盖临时目录，应选择另一安全私有工作区并确认范围，不能把扫描排除区误认成已检查数据。
扫描器本身会排除自己的工作区。每次重扫使用新任务目录，先保留日志和快照供比较，不附批量清空 /tmp 的脚本。

从本次 NDJSON `started` 取 scanId/rootNodeId，确认退出码与最后 completed/cancelled/failed 记录，再查询。
示例中的 sj_scan_id/sj_root_id 是需要从本次结果设置的变量，不是 GUI ID。
GUI、CLI、MCP 各自拥有快照；不可混用 ID，不打开 GUI 私有数据库，也不声称 CLI 重扫自动更新 GUI。
CLI queries 的名称输出属于私有元数据，注意日志披露；现有 help 中“file names never echoed”措辞过强，真实 children/hotspots 会输出名称，不能按那句话推断数据脱敏。
CLI/MCP 详细约束见[本地 Agent runbook](runbooks/local-agent-mcp.md)。

## 本轮验收与安装证据

596 项 Swift 测试 / 81 suites 通过，109 项发布脚本自测通过。
新增覆盖清理目标与授权边界、Docker context/卷风险、CLI 参数和完整路径、不携带路径、文件范围不扩大、相对路径未知、非重叠前沿、扫描时间和卷容量、版本/根/组件拒绝、helper 实际可执行判断。
另以合成目录实测安装后的 CLI help、scan、status、children、hotspots、issues、volume 全部成功。
这些是工具事实与提示词结构测试，不是模型能正确给出清理建议的效果评测。

安装版本 0.5.2 build 7，App 与 helper 都为 arm64/x86_64；helper 先单独 Hardened Runtime 签名，再签外层，不使用 codesign --deep 代替签名计划。
固定 Mach-O 清单只增添这一 helper，未知嵌套代码仍拒绝；允许的 helper 也必须签名有效、双架构、无例外 entitlement。
本机 ad-hoc DMG 和独立 verify-artifact 校验通过，不是 Developer ID/公证或公开发行版。

证据目录：[cleanup-strategy-0.5.2-20261001](../output/cleanup-strategy-0.5.2-20261001/)。
其中 logs 保存 Swift、发布脚本、Xcode、双架构 CLI、签名、独立 DMG 校验和 [installed-cli-smoke.json](../output/cleanup-strategy-0.5.2-20261001/logs/installed-cli-smoke.json)。
DMG SHA-256：`b95274429a70bbcf76c19f81e2255f8d35b72e9d2739fedcd27326fdb6ea3ad0`。
helper SHA-256：`8690a0d674f69a3ec62257881af6f27072c453583653255fb258751306931496`。
旧 0.5.1 可恢复备份在 `output/cleanup-strategy-0.5.2-20261001/backup/SpaceJudge-0.5.1-build6.app`，原始签名副本以旧 DMG 为准。
本轮没有发送真实用户磁盘数据、调用真实模型、执行 prune/删除或改变 CLI/MCP 全局配置。

新版启动欢迎页与合成目录选择框已由 CUA 观察确认；点击选择后 AX 和截图持续超时，重新绑定、显示模式调整及自动化重置未恢复。
采样显示主线程在正常 AppKit 事件等待，未发现扫描工作阻塞；这不能证明所有 UI 状态正常，也不将该问题直接归因于产品或工具。
因此新版确认面板布局、路径开关实操、Codex 完整接收和实际方案质量仍待人工确认。
没有打开新版模型草稿或发送任何模型请求。原生 UI 观察限制见 [ui-acceptance.txt](../output/cleanup-strategy-0.5.2-20261001/logs/ui-acceptance.txt)，不把 CLI 成功替代 GUI 验收。
