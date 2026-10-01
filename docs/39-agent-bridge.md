# SpaceJudge → Codex：只读分析桥接

历史文档：以下记录 0.5.0 的 ACP 方案，不代表当前 GUI。0.5.1 已用[右键 → Codex 桌面草稿](41-codex-desktop-handoff.md)替换独立登录和内置 runtime；旧实现仅留作实验源代码与历史验收依据。

状态：本机体验版 0.5.0（build 5），2026-10-01。已安装到 `/Applications/SpaceJudge.app`，原生入口、Node 和桥接运行环境随 App 附带。没有用真实目录进行云端分析，真实账号登录后的模型分析仍待验收；不标记为公开发行版本。

## 这版解决什么

用户在空间图选中一个真实项目，点击工具栏的「Codex 只读分析」。未选中时采用当前目录；合成的「其他」块不能作为分析对象。面板先固定数据，展示目录、大小、扫描版本和是否部分捕获。明确点击「开始分析」才启动 Codex。答案逐步显示，可取消。

本版不恢复 AI 清理按钮、不删除文件、不自动重扫、不读取文件内容，不自动登录或拷贝既有 Codex 凭据。只有单轮分析，没有追问、历史会话管理或其他 Agent 适配。

## 通道与模块边界

```text
原生空间图 / AppModel
  → AgentAnalysisSnapshot.capture（只读 SQLite 查询，固定版本）
  → AgentAnalysisController（启动 Node、显示流式文本、取消）
  → agent-bridge.js（ACP client，stdio JSONL）
  → codex-acp 2.1.0 → Codex App Server
                          ↓ 会话级 MCP
                    report-server.js
                          ↓
                  当前任务的只读元数据报告
```

ACP 是 SpaceJudge 请求 Agent 分析的通道；MCP 是 Agent 向 SpaceJudge 查询数据的通道。现有 Swift CLI 与八工具 MCP 继续保留、没有破坏兼容性。UI 桥接额外使用三个查询工具的报告模式，避免 Agent 无意另扫一份、读到扫描范围外的数据，或启动新的扫描写入。

没有第二套扫描器。报告来自 UI 使用的原生快照仓库，而不是 Node 遍历磁盘。`report-server` 使用既有官方 MCP Server SDK，ACP 使用项目内的小型有界 JSONL 客户端接第三方 Codex 适配器。没有采用 acpx；这样当前 Node 20 环境不用另装 Node 22。

## 快照与准确性

`schemaVersion=1`，`scanId`、`revision`、`scopeNodeId` 固定。只允许终态扫描，拒绝扫描/刷新中、场景过期、范围不存在、读取前后状态变化或页面 revision 不一致。导出完成后用户刷新 UI，不会改变正在分析的报告。

所有 UInt64 数量、ID、bytes 都编码为十进制字符串；`gb` 是 SI GB，1 GB = 1,000,000,000 bytes，两位小数，整数半入四舍五入。两端校验 GB 与 bytes 一致，不经过浮点数。`attributedBytes` 是扫描归属口径，不是独占占用，更不是保证可回收空间；父子目录占用有重叠，不能直接相加。

报告上限：2,000 个节点、64 个目录页、每页最大的 50 个直接子项、最多四层目录页。宽度/深度超限显式设置 `captureTruncated` 和页面 `truncated`。它是采样报告，不宣称完整全局 Top-N。未捕获页面返回 `captured=false, items=null, totalChildren=null`，与已捕获且真实为空的页面区别。目录 `aggregateComplete` 缺失表示未确认完整，false 表示部分汇总；特别在取消扫描或权限不足时，已记录 0 bytes 不能推导目录真正为空。

采样采用有界广度优先查询。它可能无法给出非常深的热点；用户可进入相关目录，再发起分析。截断信息不表示扫描引擎本身没扫完。整个扫描的 issue/inaccessible 计数标成全扫描事实，不冒充选中子树的问题计数。名称最多 256 个字符并带截断标记，非 UTF-8 名称用替代字符显示，不能依赖显示名称定位执行清理。

报告不传原始绝对路径或父级链，仅包含选中节点和已捕获后代、名称、类别、flags、大小和完整性事实。验证器拒绝范围外节点、循环、重复节点、不一致父子关系、错误数量和虚假完整标记。文件名可能包含提示注入内容，始终作为数据；UI 用纯文本，不执行 HTML、Markdown 链接或命令。

## 三个 MCP 工具

| 工具 | 返回 | 不能做什么 |
| --- | --- | --- |
| `spacejudge_scope` | 范围、版本、bytes/GB、捕获数、部分扫描警告 | 不查询磁盘实时状态 |
| `spacejudge_children` | 已捕获直接子项及页覆盖信息 | 不接收模型提供的路径；范围外 ID 拒绝 |
| `spacejudge_largest_captured` | 已捕获后代排序，最多 50 项，注明父子重叠 | 不能冒充全盘 Top-N 或可回收空间 |

工具描述、MCP instructions 和任务 prompt 一起说明 SpaceJudge 的能力。安全不能仅靠提示词或 `readOnlyHint`：报告服务没有写入/执行接口，查询不访问原始文件系统。

## 权限、隐私与退出

Codex 使用专用 `CODEX_HOME`，不继承用户默认 `~/.codex` 的 MCP、skills 或 plugins，不继承 API key、CODEX_CONFIG、CODEX_PATH 等运行覆盖变量。桥接只接入本任务报告 MCP，固定独立配置；配置被修改则拒绝分析，不覆盖用户改动。专用目录要求当前用户所有且权限 0700，配置 0600，拒绝符号链接。允许 Codex 自己生成的 `.system` 内置技能与空插件目录；额外技能包和非空插件目录拒绝。内置资源来自锁定 Codex 依赖，并不表示导入用户的技能配置。

Codex 初始化预设为 `read-only`，会话创建必须明确确认该模式才发送 prompt。固定配置关闭 Shell、统一执行、网页搜索、Apps、图像读取与浏览器操作；客户端不提供 filesystem/terminal 能力。所有 ACP 权限申请返回 cancelled，未知客户端方法拒绝。只读 sandbox 不约束外部 MCP，所以不复用用户默认工具配置。

上述约束适用于锁定依赖与无额外平台强制工具的本地环境。第三方适配器和模型不是可信任的安全边界；平台策略、未来内置工具与依赖升级需要重新审计。此预览不宣称完整的操作系统级“只能读报告”沙箱。正式发行前须用真实登录验证工具清单及拒绝路径。

目录名称可能敏感。面板明确提示数据会发送给登录的 Codex 服务，按用户显式点击触发，未经同意不发送真实磁盘信息。报告临时文件权限 0600、目录 0700；进程完成/取消后仅清理本任务创建的临时目录。Agent 可能在其服务及专用本地 home 保留会话记录，删除临时报告不能撤回已经发送的数据。

读取报告大小上限 4 MiB；ACP 单行 1 MiB、整任务输入流 16 MiB、答案 256 KB；native 通道总量 1 MB、单行 128 KB。畸形 JSON、未知事件、异常 EOF、超时、异常退出失败关闭。Node 持续排空 stderr，但不把认证/供应商错误原文展示给用户。

取消发 `session/cancel` 并停止桥接拥有的进程组；stdin 关闭也取消。客户端 RPC 有超时，分析最多十分钟。先关闭 stdin，宽限后 TERM/KILL 自己创建的组，等待回收才清理报告。强杀整个应用/系统崩溃后的孤儿与临时目录清理尚未覆盖，不能声称 crash-proof。

## 本机体验版使用

打开已安装的 SpaceJudge，选择文件夹并等待扫描完成。点击工具栏「Codex 只读分析」，面板固定当前目录或选中项目的数据。展开「首次使用：运行环境与独立登录」，应看到「运行环境已随应用附带」以及 `/Applications/SpaceJudge.app/Contents/Resources/AgentRuntime`；不需要手工选择 Node 或仓库目录。

点击「复制专用登录命令」，在终端由用户本人完成独立登录，再回到面板点击「开始分析」。安装和打开面板不会登录或发送磁盘报告。默认独立状态目录为 `~/Library/Application Support/SpaceJudgeAgent/codex-home`，不读取或复制已有 auth 文件，不修改已安装 Codex 的设置。报告临时文件会回收，但本地登录状态和 Codex 会话记录可能保留。

本次只完成未登录 ACP 初始化和合成报告 MCP 查询；没有验证实际模型回答。扫描可以直接使用，Agent 分析属于待用户登录验收的体验能力。安装包为本机 arm64 App，内置 Node 20.16.0 / x86_64 Codex helper，使用这台 Mac 已有的 Rosetta；不是 universal2 公开分发包。

安装、回滚与证据见 [验收记录](40-agent-bridge-acceptance.md)。文稿同步目录可能给散装 `.app` 添加 FinderInfo，备用只读 DMG 用于保留签名；不要为运行副本关闭系统安全保护。

## 源码开发使用

先在 `AgentMCP` 中执行 `npm ci --ignore-scripts` 和 `npm run build`（需要可联网安装 npm 依赖）。界面选择这个已构建目录和 Node 可执行文件；Node 20+，适配器固定 2.1.0，npm lock 固定完整依赖树。适配器自带兼容的 Codex，不能凭用户 PATH 偷换其他版本。

打开分析面板中的「首次使用」说明，复制专用登录命令，在终端由用户完成登录。默认独立状态目录为 `~/Library/Application Support/SpaceJudgeAgent/codex-home`。不读取或复制已有 auth 文件，不修改已安装 Codex 的设置。

登录后「开始分析」。失败时保留已有磁盘扫描，结果标为未完成；不要把部分输出当成完整分析。关闭面板取消当前请求。未打包的源码构建需要外置 Node 和 AgentMCP；已安装本机体验版优先发现 App 内置运行环境。

## 验证范围与后续

新增 Swift 测试验证容量精度、范围隐私、空目录、扫描终态/混合 revision、宽目录截断与 native 输出边界。Node 测试验证严格 schema、图关系、报告 MCP、异常流、权限拒绝、专用配置、ACP→真实报告 MCP 的模拟闭环，以及不确认只读模式时不发送 prompt。模拟 Agent 的输出不是实际模型分析结果。

真实适配器仅完成 ACP initialize 握手（协议 1、适配器 2.1.0），未登录或发 prompt；Xcode Debug 构建通过。完整回归与界面验收结果另见验收记录，不用构建通过替代 UI/真实模型验收。

后续门槛：用户登录后用合成报告确认实际工具清单、首次查询、流式中文答案和取消；补原生进程生命周期集成测试、崩溃恢复/TTL 清理、凭据存储方案；完成 Intel/Apple Silicon 正式依赖分发、许可与隐私审计、Developer ID 签名和公证。当前按用户要求安装本机体验版，不代表这些公开交付门槛已完成。清理执行需要独立设计与授权流程，不随分析能力一起开放。

## 参考

协议与配置依据：[ACP 会话初始化](https://agentclientprotocol.com/protocol/v1/session-setup)、[Codex ACP 适配器](https://github.com/agentclientprotocol/codex-acp)、[OpenAI App Server](https://learn.chatgpt.com/docs/app-server)、[OpenAI 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)。这些文档会变化；本版运行约束以锁定版本源码、测试与实测记录为准。
