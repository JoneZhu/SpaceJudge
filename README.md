# SpaceJudge · macOS 磁盘空间浏览器

原生实现的产品规格、扫描内核、数据口径、测试门槛和 Pi 协作流程见 [工程文档](docs/README.md)。HTML 文件是交互原型，不代表原生扫描性能。

## 当前原生实现

Phase 0–5D-A 已完成并经 Codex 独立验收：Swift 6 扫描内核、SQLite 单扫描缓存、真实目录选择、session-only 访问、磁盘总量/已用/剩余、诚实的扫描范围对账、APFS 启动盘 System/Data 可见卷组边界、AppKit/Core Graphics 的 SpaceSniffer 风格空间图，以及不依赖发布凭据的直接分发工程基线已经接入 macOS App。快照工作区不会扫描自身，不会跨扫描或启动无界累积，并会在缓存卷空间不足时安全停止。

- Xcode 工程：`App/SpaceJudge.xcodeproj`
- Swift 测试：`arch -arm64 swift test`
- 当前验收结果：421 tests / 57 suites、Xcode Debug/Release 构建通过、99 项缓存/取消/持久化关键测试通过 Thread Sanitizer；100 万 mixed 节点完整扫描 + SQLite 峰值 240.2 MB，持久化计数精确一致；真实启动盘能沿 firmlink 扫描并截断真实 mount，也会把 SpaceJudge 自身缓存显示为无子项叶子；真实点击取消后 UI 与 SQLite 同时为 cancelled。
- 最新证据与已知边界：[Phase 5C 验收基线](docs/21-phase-5c-baseline.md)
- 最新实施设计：[Phase 5D 直接分发与发布硬化](docs/22-phase-5d-design.md)
- 最新验收基线：[Phase 5D-A 直接分发工程就绪](docs/23-phase-5d-a-baseline.md)

当前支持启动盘统一可见命名空间与受保护的本地工作缓存，但不联合扫描任意外部/网络卷，也没有 APFS snapshot/clone 独占空间估算、签名、公证或发布产物；仍不包含删除、清理建议、AI 或网络能力。

Phase 5D 已选择 Developer ID + 公证 DMG 的直接分发方向，并拆分为 5D-A“发布工程就绪”和 5D-B“真实分发验证”。5D-A 已实现并经 Codex 独立验收：Release 启用 Hardened Runtime、保持无 Sandbox 且无 exception entitlement；新增完整 AppIcon 与中英文本地化的只读文件夹权限说明；`scripts/release/` 提供 universal2 ad-hoc 本地候选、fail-closed 的正式签名/公证/staple/Gatekeeper 流水线与 108 项脚本自测；[直接分发 runbook](docs/runbooks/direct-release.md) 记录人工凭据准备、5D-A 本地候选、5D-B 正式发布、验证与回滚。首个干净 Git 基线已经建立；本机尚无 Developer ID Application，因此正式 preflight 现在只剩签名身份 blocker，不会把本地候选宣称为可发布版本，也不会运行真实公证或上传。

## 当前版本：V3 空间图

`index.html` 现在打开 V3；可编辑源文件为 `spacejudge-map.html`。V2 保留在 `index-v2.html` 和 `spacejudge-simple.html`。

只保留目录导航、空间图、概览 / 详细和图例。默认展示全盘。总容量、已用、剩余缩成图例旁的一行小字，进入子目录后仍显示整块磁盘的数据。移除独立标题栏、大块磁盘卡片、底部详情栏、扫描演示与额外说明区域；保留单击展开、双击进入、悬停、右键信息和路径导航。

所有数据为示例，不读取或删除本机文件，不包含 AI 功能。

更新 V3 预览：

```sh
python3 /Users/hongdazhu/.codex/plugins/cache/openai-bundled/visualize/1.0.39/skills/visualize/scripts/render.py \
  /Users/hongdazhu/Documents/ChatGPT/SpaceJudge/spacejudge-map.html \
  /Users/hongdazhu/Documents/ChatGPT/SpaceJudge/index.html --force --title 'SpaceJudge · 空间图'
```

## V2 简洁版记录

`index-v2.html` 打开 V2；可编辑源文件为 `spacejudge-simple.html`。第一版保留在 `index-v1.html` 和 `spacejudge-prototype.html`，便于对比。

V2 以大面积空间图为主体，移除 AI 面板、建议、清理清单、四色标记、复杂筛选、侧栏与多步骤引导。保留：

- 顶部整块磁盘的容量、已用与剩余空间，浏览子目录时保持不变。
- 单击原位展开、双击进入、面包屑、后退与上一级。
- 概览 / 详细两档细节，选中项在底部显示。
- 文件信息、悬停全名、右键菜单，以及示例位置选择与模拟扫描。

默认用户目录为 312.6 GB；全盘已用 412.6 GB，另有应用程序 42 GB、系统及其他 58 GB。顶部可用空间为 99.4 GB。点击面包屑中的 `Macintosh HD` 可浏览完整磁盘示例。

右上角问号中有简短操作说明。所有数据均为模拟，原型不读取或删除本机文件，也不提供 AI 判断。

更新 V2 预览：

```sh
python3 /Users/hongdazhu/.codex/plugins/cache/openai-bundled/visualize/1.0.39/skills/visualize/scripts/render.py \
  /Users/hongdazhu/Documents/ChatGPT/SpaceJudge/spacejudge-simple.html \
  /Users/hongdazhu/Documents/ChatGPT/SpaceJudge/index.html --force --title 'SpaceJudge · 简洁版'
```

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
- `output/playwright/`：浏览器验证截图与验收记录。

在本机更新片段后，再生成预览：

```sh
python3 /Users/hongdazhu/.codex/plugins/cache/openai-bundled/visualize/1.0.39/skills/visualize/scripts/render.py \
  /Users/hongdazhu/Documents/ChatGPT/SpaceJudge/spacejudge-prototype.html \
  /Users/hongdazhu/Documents/ChatGPT/SpaceJudge/index-v1.html --force
```

也可以在此目录运行 `python3 -m http.server 8765 --bind 127.0.0.1`，打开 `http://127.0.0.1:8765/index.html`。

## 原型边界

已实现：按大小布局、细节层级、原位展开、目录进入、历史导航、表达式筛选、检查标记、上下文菜单、预设 AI 解释、候选清单、模拟移除与撤销、模拟扫描过程、操作引导和响应式布局。

原生 Phase 4 已实现：真实目录选择、session-only 权限、文件扫描、SQLite 快照、磁盘容量显示，以及有界、异步、单原生绘制面的空间图与浏览交互。

后续阶段仍待实现：APFS clone/快照/云文件口径、FSEvents、完整权限引导、签名、公证与发布恢复验证；废纸篓、删除和 AI 只有在新的产品规格与安全设计通过后才会加入。

SpaceSniffer 多窗口共享扫描、真实拖拽入口、自定义报告导出尚未纳入这个交互原型。NTFS 专属特性不直接移植到 Mac。

当前已验证的原生技术方向是 Swift、SwiftUI / AppKit、Core Graphics 与 SQLite；原生 treemap 已有独立 layout/hit/render 基准，FSEvents 与百万文件真实系统盘联合基准尚未完成。HTML 中的流畅交互仍不构成原生性能证明。
