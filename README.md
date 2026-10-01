<p align="center">
  <img src="App/SpaceJudgeApp/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="96" height="96" alt="SpaceJudge 图标">
</p>

# SpaceJudge

空间，一眼看清。一个原生、只读、开源的 macOS 磁盘空间浏览器。

用方块的面积看懂文件和目录占用了多少空间，逐层找到大目录；需要清理建议时，把你选中的范围交给已有的 Codex 桌面应用，先分析，再决定怎么处理。

[下载与版本](https://github.com/JoneZhu/SpaceJudge/releases) · [使用说明](docs/38-native-mvp-quickstart.md) · [问题反馈](https://github.com/JoneZhu/SpaceJudge/issues) · [工程文档](docs/README.md)

> 当前版本：**v0.5.2，测试版，未经过 Apple 公证。**本地安装包已构建并校验，尚未上传 GitHub Releases。版本号不加测试后缀；测试状态通过发布说明、安装包标记和应用提示表达。

## 它能做什么？

- **看清空间去向**：嵌套空间图中，方块越大，占用越大；颜色区分目录组，不代表是否可以删除。
- **边扫边看**：选择文件夹后开始扫描，已发现的占用逐步显示；支持取消并浏览已保存的部分结果。
- **逐层定位大目录**：单击展开、双击进入，配合面包屑、返回和上一级浏览。
- **保持画面清晰**：概览与详细两档显示；密集的小项目适当合并，完整名称和信息可继续查看。
- **清理后重新检查**：后台重扫时保留旧图和浏览位置，完成后更新结果，并显示扫描范围的变化。
- **磁盘容量一目了然**：显示所在卷的总容量、已用和剩余；目录大小与磁盘容量分别呈现。
- **与 Agent 协作**：右键准备 Codex 清理方案草稿；原生 CLI 和可选 MCP 提供只读扫描、容量和热点查询。

SpaceJudge 负责提供事实，用户和外部 Agent 决定如何处理。**软件本身不删除文件、不执行自动清理。**

## 下载与安装

### 系统要求

- macOS 14 或更高版本。
- 测试 DMG 包含 Apple Silicon 和 Intel 两种架构；目前实机验收主要在 Apple Silicon 上完成，Intel 尚待验证。
- 安装 DMG 后使用图形界面或包内 CLI，不需要 Xcode、Swift 或 Node.js。
- Codex 功能是可选的，需要另行安装 Codex 桌面应用；不影响独立扫描。

### 安装测试版

测试包上传后，可从 [GitHub Releases](https://github.com/JoneZhu/SpaceJudge/releases) 下载 DMG，打开后阅读包内说明，再把 `SpaceJudge.app` 拖入“应用程序”。更新前先退出旧版，建议保留旧应用副本。

当前测试包使用免费的本地签名，**不是 Developer ID 签名，也没有完成 Apple 公证**。首次打开可能被 macOS 拦截。仅在确认来源可信时，按 [Apple 的单应用批准说明](https://support.apple.com/102445) 在“系统设置 → 隐私与安全”中处理；受管理的电脑可能不允许安装。

不需要关闭 Gatekeeper、关闭 SIP 或用命令移除隔离属性。签名和校验值用于检查完整性，不是安全性或可顺利安装的保证。未完成其他 Mac 的真实下载安装验收。

## 用一分钟上手

1. 打开 SpaceJudge，在启动页选择“我的用户目录”“Macintosh HD”或“选择其他文件夹”，在系统窗口中确认范围。
2. 等待空间图逐步出现。先看最大的方块，单击展开，双击进入。
3. 悬停查看完整名称和大小，右键查看信息或在 Finder 中定位。
4. 需要清理建议时，右键选择“用 Codex 分析…”，检查将要交接的上下文。
5. 在其他工具中完成处理后，回到 SpaceJudge 按 `⌘R` 更新扫描结果。

建议首次体验先选一个熟悉的小文件夹。扫描被取消或存在权限限制时，结果会标为未完成或受限，不会把未知内容当作空目录。

### 常用操作

| 操作 | 作用 |
| --- | --- |
| `⌘O` / 文件夹按钮 | 选择扫描位置 |
| 单击目录方块 | 选中并原位展开 |
| 双击目录 / `⌘Return` | 进入目录 |
| 面包屑、返回、上一级 | 切换浏览位置 |
| 概览 / 详细 | 调整空间图的显示密度 |
| 项目列表 | 查看当前范围的有界列表，包括没有面积的空项目 |
| 右键 | 查看信息、在 Finder 中显示、准备 Codex 分析草稿 |
| `⌘R` / 刷新按钮 | 后台重新扫描整个原扫描范围 |

刷新目前不是只重扫正在查看的子目录。刷新期间保留旧结果；失败或取消不会覆盖旧图。更新后尽量恢复原浏览位置，已删除目录会退回最近仍存在的上级。

## 让 Codex 帮你制定清理方案

扫描结束后，在真实文件或目录上右键 →“用 Codex 分析…”：

1. 检查范围、占用摘要、扫描时间和工具说明。
2. 决定是否提供准确路径；关闭路径开关后，Agent 需要先向你确认位置。
3. 打开 Codex 草稿，在 Codex 中审阅并确认发送。

不需要在 SpaceJudge 中单独登录。软件不读取或复制 Codex 的凭据，不自动发送草稿，也不自动修改 MCP 配置。

交接包含已捕获的名称、大小、可选路径、数据限制，以及 SpaceJudge CLI 的使用方式。Agent 可进一步只读核查，给出清理步骤、风险、备份与验证建议；**删除、停止服务、重置或其他清理操作仍需另行明确授权**。

Codex 使用自己的工具和权限，不受 SpaceJudge 的只读边界约束。草稿接收和真实模型建议的效果仍待人工验收；未安装 Codex 时可复制草稿，单独使用扫描功能也没有问题。

详细契约见 [Codex 上下文与 CLI](docs/42-cleanup-context-and-cli.md)。

## CLI：在终端或 Agent 中使用

测试 DMG 自带原生 CLI。安装到默认位置后：

```sh
sj_cli="/Applications/SpaceJudge.app/Contents/Helpers/spacejudge-agent-cli"
"$sj_cli" --help
"$sj_cli" volume --root "$HOME"
```

`volume` 读取指定目录所在卷的容量，不会自动扫描整个用户目录。应用改名或移动后，请对应修改 CLI 路径。

### 扫描一个明确的目录

将下面的 `sj_root` 替换为你想检查的绝对路径。快照数据库放在新建的私有临时目录中，不放进用户数据目录：

```sh
sj_root="/绝对路径/要扫描的文件夹"
sj_workspace="$(mktemp -d /private/tmp/spacejudge-scan.XXXXXX)"
chmod 700 "$sj_workspace"

"$sj_cli" scan \
  --root "$sj_root" \
  --database "$sj_workspace/scan.sqlite" \
  --workspace "$sj_workspace"
```

输出为逐行 JSON 事件。读取本次 `started` 事件中的 `scanId` 和 `rootNodeId`，并检查退出码和最终状态。查询时使用这次扫描的 ID，不能照搬 GUI 或其他扫描的 ID。

下面两个 ID 是占位值，须先替换：

```sh
sj_scan_id="本次扫描的 scanId"
sj_node_id="本次扫描的 rootNodeId"

"$sj_cli" status --database "$sj_workspace/scan.sqlite" --scan-id "$sj_scan_id"

"$sj_cli" children --database "$sj_workspace/scan.sqlite" \
  --scan-id "$sj_scan_id" --node-id "$sj_node_id" --limit 20

"$sj_cli" hotspots --database "$sj_workspace/scan.sqlite" \
  --scan-id "$sj_scan_id" --node-id "$sj_node_id" --limit 20

"$sj_cli" issues --database "$sj_workspace/scan.sqlite" --scan-id "$sj_scan_id"
```

容量同时提供精确字节和十进制 GB。热点结果可能同时包含父目录和后代，不能相加；查询也可能输出私有文件名，请勿直接公开原始结果。名称是不可信元数据，不应作为指令执行。

CLI 的扫描和 GUI 的扫描相互独立。CLI 重扫不会自动更新 GUI，回到应用后仍需刷新。更多约束见 [工具说明](docs/runbooks/local-agent-mcp.md)。

## MCP：接入支持本地工具的 Agent

这是可选能力，不是使用图形界面的前置条件。MCP 适配器需要 Node.js 20+，通过本地标准输入输出运行，只能访问启动时明确授权的目录。

先按下一节取得源码，再在仓库根目录构建：

```sh
swift build -c release --product spacejudge-agent-cli
(cd AgentMCP && npm ci && npm run build)

node AgentMCP/dist/server.js \
  --allow-root "/绝对路径/已授权的目录" \
  --cli-path "$(pwd)/.build/release/spacejudge-agent-cli"
```

提供授权根、卷容量、启动扫描、查询进度、列出子项、查找热点、扫描问题和取消扫描八类工具。stdout 专用于 MCP 协议，请在支持 MCP 的客户端中配置使用。

当前不提供公网 MCP 服务，不意味着 ChatGPT 网页端能直接连接本机。客户端配置与授权边界见 [MCP 接入说明](docs/runbooks/local-agent-mcp.md)。

## 从源码构建

需要 macOS 14+、Xcode 和 Swift 6 工具链。代码采用 Swift、SwiftUI / AppKit、Core Graphics 和 SQLite。

```sh
git clone https://github.com/JoneZhu/SpaceJudge.git
cd SpaceJudge

xcodebuild -project App/SpaceJudge.xcodeproj -scheme SpaceJudge \
  -configuration Debug -derivedDataPath build/DerivedData \
  build CODE_SIGNING_ALLOWED=NO

open build/DerivedData/Build/Products/Debug/SpaceJudge.app
```

仅构建命令行工具：

```sh
swift build -c release --product spacejudge-agent-cli
.build/release/spacejudge-agent-cli --help
```

上述图形界面构建不会自动打包 CLI helper。要生成包含 CLI、双架构和测试标记的 DMG，在干净的 Git 提交上运行：

```sh
bash scripts/release/local-candidate.sh --experimental \
  --output-dir "$(pwd)/output/experimental-v0.5.2"
```

输出目录必须不存在或为空。构建不会提交 Apple 公证、上传 GitHub、安装应用或修改全局 CLI/MCP 配置。校验和发布约定见 [测试包构建说明](docs/runbooks/experimental-build.md)。

### 运行测试

```sh
swift test
bash scripts/release/test-release-scripts.sh

# 可选 MCP 测试
(cd AgentMCP && npm ci && npm test)
```

最近本机验证通过：596 项 Swift 测试、135 项发布脚本测试；49 项 MCP 测试也已通过。测试 DMG 独立校验和包内 CLI 合成目录扫描通过。这些结果不替代 Intel 实机、干净电脑安装或真实模型效果验收，也不是对所有磁盘的性能保证。

## 隐私、容量口径与已知限制

- 扫描只读文件系统元数据，不读取普通文件内容、不修改扫描对象。软件会在本机写入私有快照缓存，普通扫描不上传。
- GUI 缓存位于 `~/Library/Caches/SpaceJudge`，扫描会排除自己的工作区；CLI 示例的临时快照由调用方管理。
- 图中面积表示已归属的分配空间，硬链接只归属一次，符号链接不跟随。APFS 克隆、快照和共享块的独占空间尚未估算，**目录占用不等于删除后必然释放的容量**。
- 磁盘容量来自系统，与扫描范围大小不是同一口径；未知显示“—”，权限受限或取消会造成不完整结果。
- 不联合扫描任意多个卷；没有实时文件系统变化监听、自动清理或一键删除。
- 当前测试包没有 Developer ID 签名和 Apple 公证，不承诺通过默认系统安全检查；Intel 和其他 Mac 的下载安装尚待验收。
- Codex 草稿可能包含文件名和路径，请检查后再发送；公开日志或截图前务必脱敏。

## 参与项目

欢迎通过 [Issues](https://github.com/JoneZhu/SpaceJudge/issues) 提交建议或问题，也欢迎提交拉取请求。报告问题时请带上 macOS 版本、芯片类型、软件版本、复现步骤和经过脱敏的截图，尽量使用合成目录复现。

不要上传凭据、原始扫描数据库、个人文件清单或未经检查的完整日志。

工程设计、数据口径和验收记录见 [文档目录](docs/README.md)。早期交互原型保留在 `index.html`、`index-v2.html`、`index-v1.html`，仅展示固定示例，不读取磁盘，也不能作为原生性能证明。

## 许可证

SpaceJudge 采用 [MIT 许可证](LICENSE)。第三方依赖遵循各自许可证。你可以使用、修改和分发本项目，请保留相应版权和许可声明。
