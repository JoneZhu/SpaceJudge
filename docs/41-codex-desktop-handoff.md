# SpaceJudge 0.5.1：右键交接 Codex 桌面草稿

历史交付记录：0.5.2 已扩展为准确路径、清理方案上下文与随 App 附带 CLI，见[文档42](42-cleanup-context-and-cli.md)。以下 path-free 草稿与旧提示词限制仅对应 0.5.1，不代表当前入口。

日期：2026-10-01。执行者：Codex，未使用 Pi。当前安装：`/Applications/SpaceJudge.app`，0.5.1 build 6。
已完成代码、全量 Swift 测试、universal Release、签名与 DMG 校验和本机替换。
已实测合成目录右键、固定范围摘要、隐私说明及系统打开请求；**Codex 接收完整草稿及模型效果尚未验收**。

## 如何使用

1. 选择文件夹或磁盘，等待扫描结束（取消后的部分结果也允许，但必须注明未完成）。
2. 右键空间图中的真实文件或文件夹 →「用 Codex 分析…」。
3. 检查项目、GB/B、快照版本、部分数据说明和下方确切草稿。
4. 点击「打开 Codex 草稿」，在 Codex 新对话检查内容并自行确认发送。
5. 后续对话在 Codex 进行。需要清理时另行授权；处理完回 SpaceJudge 按 `⌘R` 刷新整个扫描范围。

移除旧顶栏 AI 按钮、独立登录指令、Node 配置与内嵌模型输出。
桌面 Codex 已登录时使用其自身状态；SpaceJudge 不读取/复制凭据，不改变账号或配置。
未安装或跳转失败时，「复制分析草稿」用于手动粘贴；成功状态仅写“已请求打开”，不冒充已发送。
“其他”是合成块，不提供 AI 操作；正在扫描/刷新、场景过期或项目失效时拒绝分析。

## 数据与交接边界

沿用 `AgentAnalysisSnapshot.capture` 的固定版本 SQLite 查询，没有第二套扫描器，也不读取文件内容。
范围按菜单点击项目的真实 node ID 固定，而不是异步完成时的最新选中项。捕获前后检查扫描与页面版本。
菜单保存渲染 key，执行时重查 key 与可用性，避免旧菜单误分析新场景。

原始捕获上限：2,000 节点、64 目录页、每页 50 项、最多四层目录页。
`CodexDesktopDraft` 再生成小摘要：至多 12 个直接子项与 12 个已捕获后代中的大项，名称至多 80 字符，
URL 百分号编码后的 UTF-8 大小不超过 16,384 B；超限逐项缩减，保留范围与省略标记。
该上限是工程限制，不宣称所有桌面版本都能接收这个长度。

精确大小使用 UInt64 比较，bytes 为十进制字符串，GB 为 SI 双小数格式，不经浮点排序。
`rootPageCaptured` 区分未查询页与已知空页；未捕获时子项总数缺失，不伪造 0。
`captureTruncated` 表示原报告截断，`summaryOmittedItems` 表示摘要省略，`nameTruncated` 表示名称省略。
`aggregateComplete` 未知与 false 保留区别。问题计数明确属于整份扫描，不冒充该子树计数。
摘要是捕获范围采样，不是全盘 Top-N；直接子项与后代排序可能重复，父子大小不能相加。
扫描归属分配字节不等于 APFS 独占空间，也不保证删除后释放这些容量。

名称通过 JSON 编码并明确标为不可信数据；不把名称当指令，不用名称定位执行清理。
交接不包含文件内容、原始完整路径或扫描目录的父级路径。
URL 仅有 `prompt` 参数，`+` 等保留字符百分号编码；不指定 workspace/path、不自动发送、不注入插件或 MCP。
官方协议依据：[Desktop deep links](https://learn.chatgpt.com/docs/reference/commands#deep-links)。

## 权限、CLI/MCP 和旧方案

这是外部桌面交接，不是 SpaceJudge 内置的只读沙箱。Codex 使用已有工具与权限；
“只分析、不执行、不删除”的草稿要求不构成系统级限制。发送和清理须由用户分别确认。
SpaceJudge 不写 Codex 配置、不查登录、不创建专用 home，不后台启动模型。

CLI 与现有 MCP 完整保留，已安装路径和全局配置未变；本轮没有运行或重配它们。
草稿会说明 SpaceJudge 的能力，但不会自动连接工具。若当前 Codex 会话未配置 SpaceJudge MCP，
只能依据摘要分析或按[本地 MCP runbook](runbooks/local-agent-mcp.md)另行接入，不凭摘要 node ID 自动访问实时数据。

原 ACP controller/bridge/report MCP 留作历史实验源码，不由当前 GUI 实例化，不随本次 App 打包。
[文档39](39-agent-bridge.md)、[文档40](40-agent-bridge-acceptance.md)与 ADR 0014 对应旧 0.5.0。
旧 `agent-local-preview.mjs` 已加版本前置检查，防止给新版错误打入旧 runtime；新版使用 `local-candidate.sh`。
当前决策见 [ADR 0015](adr/0015-codex-desktop-draft.md)。

## 测试与实际验收

| 范围 | 本轮证据 | 尚不能证明 |
| --- | --- | --- |
| Swift 回归 | 590 tests / 80 suites 通过，含新增 5 项草稿及 3 项菜单测试 | 模型效果与外部桌面兼容 |
| 草稿测试 | 中文/C++/URL 保留字符/换行、UInt64 极值及 >2^53 排序、长摘要编码大小、截断标记、空页/未知页、缺失范围拒绝 | 所有客户端均接收 16 KB URL |
| 菜单测试 | 文件/目录回调与 exact tile、禁用状态、执行时复查、旧场景菜单拒绝、“其他”不提供分析 | 全部系统外观/输入法 |
| 原生 UI | 合成根 2 文件/3 目录扫描完成；右键 Synthetic Docker C++ 中文；面板显示 4096 B、正确 sample.txt、隐私和草稿；点击后显示“已请求打开” | Codex 内部草稿实际接收与未自动发送的本机 UI 观察 |
| 构建与签名 | Release arm64/x86_64；deep/strict 签名、Hardened Runtime、Mach-O 架构与 DMG 挂载内容校验通过 | Developer ID、公证、Intel 实机、公开分发 |

验收只交接 `/private/tmp/spacejudge-codex-handoff-ui-20261001` 的合成文件名与大小；没有交接真实用户磁盘摘要、文件内容或模型请求，也没有点击发送。
目录选择后的 AX 读取曾超时，但截图随后确认扫描完成；右键和面板 AX 恢复正常。
采样显示主线程在正常 AppKit 事件等待，不能据此认定扫描卡死。
最终系统接受跳转请求后，CUA 明确禁止查看 `com.openai.codex` 自身窗口，因此接收完整草稿需要人工确认。
这是未完成的外部应用验收项，不用单元测试或打开请求成功替代。
Node/MCP 的 49 项通过结果来自旧轮，本轮未修改或重跑该实现。

## 安装、证据与恢复

产物目录：[output/codex-desktop-0.5.1-20261001](../output/codex-desktop-0.5.1-20261001/)。
Swift 记录：[swift-regression.log](../output/codex-desktop-0.5.1-20261001/logs/swift-regression.log)。
构建记录：[xcodebuild-Release.log](../output/codex-desktop-0.5.1-20261001/logs/xcodebuild-Release.log)。
超时采样：[ui-timeout-sample.txt](../output/codex-desktop-0.5.1-20261001/logs/ui-timeout-sample.txt)。
本机 UI 步骤与版本核对：[ui-acceptance.txt](../output/codex-desktop-0.5.1-20261001/logs/ui-acceptance.txt)。

备用 DMG：`SpaceJudge-0.5.1-6-universal-LOCAL-ADHOC-NOT-FOR-DISTRIBUTION.dmg`。
SHA-256：`7626eb5a048524f7e34e621272fdf4d89540fb6aea2b83471436840d8860e154`。
安装后二进制 SHA-256：`8c8ba356ffa5301d7a63f97594e9566801a39940a2b40069a4cf212a98bf60fc`。
从只读 DMG 暂存安装，签名与版本校验后替换 `/Applications/SpaceJudge.app`；最终版本 0.5.1/6、双架构、deep/strict 校验均通过。
旧 0.5.0 可恢复备份：[SpaceJudge-0.5.0-build5.app](../output/codex-desktop-0.5.1-20261001/backup/SpaceJudge-0.5.0-build5.app)。
未删除用户文件、快照、CLI、Codex 配置或旧独立登录目录。
需要恢复时先退出 App，再从备份拷回并重新验证签名；云盘若补写扩展元数据，以旧版已校验只读 DMG 为准，不关闭系统安全保护。

待人工验收：Codex 草稿中文和 `C++` 完整、内容未被自动发送、实际摘要分析效果、已配置 MCP 的补充查询与用户授权流程。
验收完成后已正常退出合成扫描实例，重新打开已安装应用，AX 确认停在欢迎页，供用户选择扫描位置。
待正式发布：Developer ID、公证、Gatekeeper、Intel 实机和跨桌面版本兼容；本包仍为本机 ad-hoc，不可作为公开发行版本。
