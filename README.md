# SpaceJudge · macOS 磁盘空间浏览器

一个只读、原生的 macOS 磁盘空间浏览器：用嵌套空间图找到大目录，在扫描过程中逐步显示结果；可把选中范围的上下文交给已有 Codex 桌面应用制定清理建议，不自动删除文件。

开源许可证：[MIT](LICENSE)。系统要求 macOS 14+；源码构建需要 Xcode 与 Swift 6 工具链。图形界面和原生 CLI 不需要 Node.js，只有可选 MCP 适配器需要 Node.js 20+。

## 从源码开始

```sh
git clone https://github.com/JoneZhu/SpaceJudge.git
cd SpaceJudge
swift test
xcodebuild -project App/SpaceJudge.xcodeproj -scheme SpaceJudge \
  -configuration Debug -derivedDataPath build/DerivedData \
  build CODE_SIGNING_ALLOWED=NO
open build/DerivedData/Build/Products/Debug/SpaceJudge.app
```

CLI：`swift build -c release --product spacejudge-agent-cli`，然后运行 `.build/release/spacejudge-agent-cli --help`。
可选 MCP 的构建、授权根和客户端配置见[本地 Agent runbook](docs/runbooks/local-agent-mcp.md)。

源码公开不等于已发布正式 DMG：当前测试安装包未完成 Developer ID 签名、公证与其他 Mac 的安装验收。
本机安装包、日志、扫描快照和个人清理记录不纳入源码仓库；历史验收中的本机路径已匿名化，`output/` 证据链接仅在原验收机器上可用。

原生实现的产品规格、扫描内核、数据口径、测试门槛和 Pi 协作流程见 [工程文档](docs/README.md)。HTML 文件是交互原型，不代表原生扫描性能。

## 当前原生实现

Phase 0–5D-A 已完成并经 Codex 独立验收：Swift 6 扫描内核、SQLite 单扫描缓存、真实目录选择、session-only 访问、磁盘总量/已用/剩余、诚实的扫描范围对账、APFS 启动盘 System/Data 可见卷组边界、AppKit/Core Graphics 的 SpaceSniffer 风格空间图，以及不依赖发布凭据的直接分发工程基线已经接入 macOS App。快照工作区不会扫描自身，不会跨扫描或启动无界累积，并会在缓存卷空间不足时安全停止。

- Xcode 工程：`App/SpaceJudge.xcodeproj`
- Swift 测试：`arch -arm64 swift test`
- 当前回归：596 项 Swift 测试 / 81 suites、109 项发布脚本测试通过；49 项 Node/MCP 测试为上一轮 0.5.0 历史结果，本轮未改动该实现。0.5.2 已安装，附带原生 CLI；已用合成目录实测 CLI 定向扫描与所有查询。Codex 草稿接收及真实模型效果尚待人工确认。此前 universal MVP 已实操选择、浏览、信息、Finder、取消和恢复；百万包装夹具 1000001 节点完整持久化，CLI 重扫峰值 RSS 155648000 B，低于 250000000 B 工程门。
- 最新交付和证据：[原生MVP独立验收](docs/37-native-mvp-acceptance.md)
- 最短操作入口：[本机MVP使用说明](docs/38-native-mvp-quickstart.md)
- 最新分析入口：[右键 → Codex 清理上下文与 CLI](docs/42-cleanup-context-and-cli.md)（0.5.2 build 7，无独立登录或内置 Node；全局 CLI/MCP 配置不变）
- 历史发布工程基线：[Phase 5D-A](docs/23-phase-5d-a-baseline.md)

当前支持启动盘统一可见命名空间与受保护的本地工作缓存，但不联合扫描任意外部/网络卷，也没有 APFS snapshot/clone 独占空间估算或 Developer ID 签名公证的公开发行包。0.5.2 从右键把选中范围的名称、可选准确路径、大小、扫描元数据与 CLI 用法交给已有 Codex 桌面应用作为草稿，要求核查并给清理方案。不自动发送、不读取文件内容、不执行删除。外部 Codex 使用自身权限设置，不是 SpaceJudge 的只读沙箱。

## 运行原生 App（Phase 7 MVP）

已构建的本机交付可以直接启动：

```sh
open /Applications/SpaceJudge.app
```

0.5.2 构建 7 保留启动页、扫描中逐步出图与后台刷新，右键「用 Codex 分析…」用于制定清理方案。
旧版已备份，安装与回滚记录见 [清理上下文与 CLI](docs/42-cleanup-context-and-cli.md)；新增 App 内 helper，原 CLI 和全局 MCP 配置没有改变。
使用和限制见文档38、42。源码构建（可选，无需 Node/runtime；随 App CLI 需用 local-candidate.sh --with-cli 打包）：

```sh
xcodebuild -project App/SpaceJudge.xcodeproj -scheme SpaceJudge \
  -configuration Debug -derivedDataPath build/DerivedData \
  build CODE_SIGNING_ALLOWED=NO
open build/DerivedData/Build/Products/Debug/SpaceJudge.app
```

首次启动会创建一个只属于本应用的本地 SQLite 快照缓存（`~/Library/Caches/SpaceJudge`），缓存目录本身不会扫描自身。

关键操作：

- `⌘O` / 左上角文件夹按钮：选择要分析的文件夹或磁盘。
- 单击方块：选中（绿色轮廓），并原位展开目录。
- 双击目录：进入该目录；也可用面包屑、后退、上一级导航。
- 顶部右侧：重新扫描；仅扫描进行中显示“取消”。`⌘R` 重新扫描当前选择，扫描进行中不会触发。
- 概览 / 详细：切换 tile 密度与嵌套深度。
- 悬停：查看全名、类型与占用；右键：进入 / 展开 / 折叠 / 信息 / 在 Finder 中显示 / 用 Codex 分析。
- 底部小条：容量“已用 / 总 / 剩余”与“当前位置”大小（当前focus的归属字节；未知用—，
  活动扫描标注“正在统计”，取消后为“未完成”）；悬停可看扫描范围对账与容量来源。
- 顶部列表按钮：打开当前范围的有界项目列表（最多 500 项），包含 0 占用/空文件，可选中查看信息或在 Finder 中显示。

切换目录时新位置读取期间，旧地图只作显示且不可选中/展开/进入/Finder，并明确标注上一位置；
面包屑、后退、上一级仍可用。

默认会为当前页最大的若干目录自动展开两层浅层预览；用户手动折叠的目录（包括先显式展开再折叠）在下一次刷新时不会自行重新打开。展开目录的标题只出现在预留的 header 中，子块从 header 下方开始，不会发生标题与子块重叠。

仅 Debug 构建可用于验收的启动环境变量（Release 完全忽略）：

- `SPACEJUDGE_TEST_APPEARANCE=dark|light`：仅改变本应用的外观。
- `SPACEJUDGE_TEST_WINDOW_SIZE=736x560`（或 `1120x760` / `1440x900`）：设置窗口内容尺寸。
- `SPACEJUDGE_TEST_ROOT_PATH`、`SPACEJUDGE_TEST_DATABASE_PATH`：无面板选择固定夹具与临时库。

已知限制与测量范围：

- 没有删除或自动清理能力。普通扫描只读元数据、默认不上传；Codex 桌面草稿由用户检查并确认发送，无需 SpaceJudge 独立登录；模型效果待验收，不自动连接 MCP。
- 扫描遵循选中根所在卷的边界，不联合跨真实mount；不估算APFS克隆或快照可释放量。
- 容量优先采用系统“重要用途可用”；当该值为 0 或缺失但普通可用或 Darwin `statfs` 仍有正值时，退化到普通可用并标注来源，不会因此误判满盘。真实全部来源为 0 时仍按 0 处理。
- 百万内存门已独立通过：完整E2E为145506304 B，最终取消修复后CLI重扫为155648000 B。生成时间不计入扫描，缓存状态未控制；GUI的系统框架footprint与该RSS口径不同，不混用数字，也不把单机结果当作所有磁盘性能承诺。
- 本机Apple Silicon实操通过；Intel实机、Developer ID、公证和公开分发验证不在本次本机MVP验收内。

Phase 5D 已选择 Developer ID + 公证 DMG 的直接分发方向，并拆分为 5D-A“发布工程就绪”和 5D-B“真实分发验证”。5D-A 已实现并经 Codex 独立验收：Release 启用 Hardened Runtime、保持无 Sandbox 且无 exception entitlement；新增完整 AppIcon 与中英文本地化的只读文件夹权限说明；`scripts/release/` 提供 universal2 ad-hoc 本地候选、fail-closed 的正式签名/公证/staple/Gatekeeper 流水线与 108 项脚本自测；[直接分发 runbook](docs/runbooks/direct-release.md) 记录人工凭据准备、5D-A 本地候选、5D-B 正式发布、验证与回滚。首个干净 Git 基线已经建立；本机尚无 Developer ID Application，因此正式 preflight 现在只剩签名身份 blocker，不会把本地候选宣称为可发布版本，也不会运行真实公证或上传。

## 当前版本：V3 空间图

`index.html` 现在打开 V3；可编辑源文件为 `spacejudge-map.html`。V2 保留在 `index-v2.html` 和 `spacejudge-simple.html`。

只保留目录导航、空间图、概览 / 详细和图例。默认展示全盘。总容量、已用、剩余缩成图例旁的一行小字，进入子目录后仍显示整块磁盘的数据。移除独立标题栏、大块磁盘卡片、底部详情栏、扫描演示与额外说明区域；保留单击展开、双击进入、悬停、右键信息和路径导航。

所有数据为示例，不读取或删除本机文件，不包含 AI 功能。

直接在浏览器打开 `index.html` 可体验 V3。`spacejudge-map.html` 是可编辑原型源片段；预览文件保留在仓库中，不要求安装原作者的 Codex 可视化插件。

## V2 简洁版记录

`index-v2.html` 打开 V2；可编辑源文件为 `spacejudge-simple.html`。第一版保留在 `index-v1.html` 和 `spacejudge-prototype.html`，便于对比。

V2 以大面积空间图为主体，移除 AI 面板、建议、清理清单、四色标记、复杂筛选、侧栏与多步骤引导。保留：

- 顶部整块磁盘的容量、已用与剩余空间，浏览子目录时保持不变。
- 单击原位展开、双击进入、面包屑、后退与上一级。
- 概览 / 详细两档细节，选中项在底部显示。
- 文件信息、悬停全名、右键菜单，以及示例位置选择与模拟扫描。

默认用户目录为 312.6 GB；全盘已用 412.6 GB，另有应用程序 42 GB、系统及其他 58 GB。顶部可用空间为 99.4 GB。点击面包屑中的 `Macintosh HD` 可浏览完整磁盘示例。

右上角问号中有简短操作说明。所有数据均为模拟，原型不读取或删除本机文件，也不提供 AI 判断。

直接在浏览器打开 `index-v2.html` 可体验 V2。

## 以下为 V1 设计记录

打开 `index-v1.html` 即可体验第一版。无需应用后端，不访问用户磁盘。空间数据和 AI 判断均为固定示例，不能用来评估原生扫描性能。

页面右上角有「原型说明」与「跟着体验」。说明直接包含产品定位、来源、操作方法、筛选语法、实现范围和未实现部分。

## 建议体验顺序

1. 单击「资源库」，观察在原位展开更多子目录。
2. 双击 `Developer` 进入；使用面包屑、上一级、后退、前进导航。
3. 选中 `DerivedData`，查看右侧用途、依据和处理影响。
4. 加入清理清单，模拟移入废纸篓，再撤销。
5. 回到「我的文件」，尝试 `*.dmg;>5gb`、`>6months`、`|*.dmg` 等筛选。
6. 给条目添加颜色标记，再用 `:green` 或 `:all` 筛选。
7. 演示重新扫描，尝试在扫描中导航、暂停、继续和停止。

## 设计依据

研究日期：2026-09-26。研究方式为官方文档与产品资料查阅，没有运行 Windows 版 SpaceSniffer。

- [SpaceSniffer 官方操作介绍](https://www.uderzo.it/main_products/space_sniffer/)：嵌套 treemap、单击展开、双击进入、文件筛选、排除条件和四色标记。
- [SpaceSniffer 官方功能说明](https://www.uderzo.it/main_products/space_sniffer/features.html)：浏览器式导航、扫描中浏览、细化扫描、多视图共享扫描、变化反馈与系统右键菜单。
- [腾讯微信 Mac 产品页](https://apps.apple.com/cn/app/%E5%BE%AE%E4%BF%A1/id836500024?mt=12)：视觉参考对象。此原型采用浅色侧栏、灰白分层、绿色强调和紧凑操作，未使用微信品牌素材。

我们保留 SpaceSniffer 的核心空间探索交互；新增“文件洞察”和“主动加入清单”的判断流程。空间地图底色表示目录类别，四色小圆点表示用户检查标记，避免把不同语义混在一起。

第一版原型选择显示固定的浅色方案。用户目录示例总计 312.6 GB；磁盘示例已用 412.6 GB，另有 100 GB 不属于该用户目录。模拟移入废纸篓不会增加磁盘可用空间。修改时间使用相对于演示基准日的月份数据，并不代表最后使用时间。

## 文件与再生成

- `spacejudge-prototype.html`：自包含可编辑片段，CSS、示例文件树、treemap 布局与交互均在其中。
- `index-v1.html`：第一版可单独打开的浏览器预览文件，由片段生成。
- `output/playwright/`：本地浏览器验证截图与验收记录，不纳入公开源码提交。

直接在浏览器打开 `index-v1.html` 可体验 V1。

也可以在此目录运行 `python3 -m http.server 8765 --bind 127.0.0.1`，打开 `http://127.0.0.1:8765/index.html`。

## 原型边界

已实现：按大小布局、细节层级、原位展开、目录进入、历史导航、表达式筛选、检查标记、上下文菜单、预设 AI 解释、候选清单、模拟移除与撤销、模拟扫描过程、操作引导和响应式布局。

原生 Phase 4 已实现：真实目录选择、session-only 权限、文件扫描、SQLite 快照、磁盘容量显示，以及有界、异步、单原生绘制面的空间图与浏览交互。

后续阶段仍待实现：APFS clone/快照/云文件口径、FSEvents、完整权限引导、签名、公证与发布恢复验证；废纸篓、删除和 AI 只有在新的产品规格与安全设计通过后才会加入。

SpaceSniffer 多窗口共享扫描、真实拖拽入口、自定义报告导出尚未纳入这个交互原型。NTFS 专属特性不直接移植到 Mac。

当前已验证的原生技术方向是 Swift、SwiftUI / AppKit、Core Graphics 与 SQLite；原生 treemap 已有独立 layout/hit/render 基准，FSEvents 与百万文件真实系统盘联合基准尚未完成。HTML 中的流畅交互仍不构成原生性能证明。
