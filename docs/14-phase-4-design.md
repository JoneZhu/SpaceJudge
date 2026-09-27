# Phase 4 实施设计：高性能原生 Treemap 与浏览交互

状态：Accepted（实现与独立验收见 `15-phase-4-baseline.md`）

设计日期：2026-09-26

## 1. 阶段目标

Phase 4 把 Phase 3 的“最大项目诊断列表”替换为真正可用的 SpaceSniffer 风格空间图，同时保持已经冻结的扫描、容量、权限、SQLite 与退出语义。

本阶段完成：

- 单个 AppKit `NSView` + Core Graphics 绘制面，不为每个 tile 创建 SwiftUI View、`NSView` 或 `CALayer`。
- 真实 SQLite 快照驱动的扁平与嵌套 treemap；面积唯一使用 `SnapshotChildItem.effectiveAttributedBytes`。
- 扫描过程中逐步刷新；用户已经进入的目录、展开状态和选择不会因为新 revision 自动跳回根。
- 单击选择并原位展开目录，双击进入目录；后退、上一级、面包屑导航。
- 概览 / 详细两档，hover 提示、右键菜单、信息面板和在 Finder 中显示。
- 有界数据缓存、异步布局、空间命中索引、局部 hover 重绘和可重复的 layout/hit/render benchmark。
- 900×640 与 1,280×800 的浅色/深色原生界面，以及基本键盘和 VoiceOver 路径。

本阶段不做：

- 删除、移动、废纸篓、清理建议、AI、网络、内容读取或哈希。
- FSEvents、扫描结束后的实时文件变更维护。
- 安全作用域 bookmark、自动恢复上次目录、App Sandbox、签名、公证或发布。
- APFS clone/快照可释放空间的精确推导。
- 多窗口共享扫描、多个根同时扫描或跨设备同步。

## 2. 产品形态

### 2.1 主窗口

窗口仍以 900×640 为最小尺寸，默认 960×680。结构从上到下固定为：

1. **紧凑工具栏**：选择位置、后退、上一级、面包屑、重扫/取消、当前状态、概览/详细。
2. **空间图区域**：占据绝大部分窗口；扫描中已有结果立即可浏览。
3. **轻量覆盖层**：hover 提示；选择项摘要只在有选择时出现，不永久占用大块侧栏。
4. **底部小字**：颜色图例以及整块卷的容量、已用、剩余。进入子目录后仍显示同一卷数据。

不再显示 Phase 3 的大标题、独立状态区或默认最大项目列表。Debug 构建允许通过 `⌥⌘D` 打开诊断列表；Release 不显示这个入口，但保留相同查询和回归测试。

### 2.2 状态呈现

- 未选择位置：地图中央只有“选择文件夹或磁盘”主按钮和一句只读说明。
- preparing/scanning：地图使用已提交快照；工具栏显示旋转进度与计数，文案明确“正在扫描”。
- completed：保留最后地图，状态变为完成。
- cancelled：保留已提交地图并标记“已取消”，允许重扫。
- permissionLimited：保留可见地图；显示问题数量和“打开隐私与安全性设置”入口。
- failed：保留最后成功应用的 render snapshot；显示 path-free 错误，不清空地图制造闪烁。

扫描状态、容量和地图 revision 是不同事实，不能为了视觉方便互相伪造。

## 3. 模块与依赖

Phase 4 使用下列真实模块边界：

```text
SpaceJudgeApp (SwiftUI scene / toolbar / popover / AppDelegate)
  ├── SpaceJudgeTreemapUI (AppKit + Core Graphics + SwiftUI bridge)
  │     ├── TreemapCanvasView
  │     ├── TreemapViewRepresentable
  │     ├── TreemapRenderer
  │     └── layout coordinator / context menu adapter
  ├── SpaceJudgeAppSupport
  │     ├── AppModel navigation state
  │     ├── SnapshotLoader / runtime path resolver
  │     └── immutable TreemapSceneData
  └── existing scan/store/use-case composition

SpaceJudgeTreemap (pure Sendable geometry)
  ├── SquarifiedTreemap / VisibilityReducer
  ├── hierarchy composer
  └── TreemapHitIndex
```

依赖方向：

- `SpaceJudgeTreemap` 只依赖 `SpaceJudgeDomain`，不得 import AppKit、SwiftUI、SQLite 或扫描器。
- `SpaceJudgeAppSupport` 新增对 `SpaceJudgeTreemap` 的依赖，仍不得 import AppKit/SwiftUI。
- 新增 `SpaceJudgeTreemapUI` package product/target，依赖 `SpaceJudgeDomain`、`SpaceJudgeTreemap` 与 `SpaceJudgeAppSupport`；这是唯一包含自定义 `NSView` 和 Core Graphics renderer 的模块。
- App target 链接 `SpaceJudgeAppSupport` 与 `SpaceJudgeTreemapUI`，不在 `ContentView` 内实现布局算法。
- 新增 `SpaceJudgeTreemapUITests` 与 `spacejudge-treemap-bench`。不引入第三方 package。

## 4. 快照查询契约

### 4.1 扩展 `SnapshotChildPage`

现有 page 只能表达前 N 项和总数量，不能证明被截断项目的面积。扩展为：

```swift
public struct SnapshotChildPage: Sendable, Equatable, Hashable, Codable {
    public let items: [SnapshotChildItem]
    public let totalCount: UInt64
    public let snapshotRevision: Revision
    public let parentAggregate: DirectoryAggregateRecord?
}
```

兼容要求：现有 initializer 保留默认参数或同步更新全部调用点；Phase 0–3 测试不得删除。

Store 在一个只读 SQLite transaction/snapshot 中读取：

1. `scans.last_revision`；
2. 当前 parent 的 `directory_aggregates`；
3. 直接子项总数；
4. 按有效占用降序、NodeID 升序的有界 child page。

transaction 必须在成功与任何错误路径确定结束；不能让只读 connection 遗留在 transaction 中。结果数组仍受 `limit` 约束，不能为了算“其他”把全部子项装入 Swift 数组。

### 4.2 “其他”的权重

对于 page 前 N 项：

```text
shown = checked/saturating sum(items.effectiveAttributedBytes)
omittedCount = totalCount - items.count

if parentAggregate exists and parentAggregate.attributedBytes >= shown:
    omittedWeight = parentAggregate.attributedBytes - shown
else:
    omittedWeight = unknown
```

- `omittedCount == 0` 时不创建“其他”。
- `omittedCount > 0` 且 `omittedWeight` 已知时，把它作为该 sibling group 的预折叠权重，与像素阈值折叠出的微小节点合并为一个“其他（N 项）”tile。
- `omittedWeight` 未知时不能猜测 0 或平均值；界面显示“还有 N 项正在统计”，但不画虚假面积。parent aggregate 到达后下一版 snapshot 自然收敛。
- `parentAggregate.isComplete == false` 表示当前面积是 best-known，不是最终值；扫描状态必须继续可见。
- 若求和溢出或 parent 小于 shown，记录可测试的内部不一致并退化为不画 omitted 面积；不得下溢或崩溃。

### 4.3 页面上限

- 当前 focus 的直接子项：最多 500。
- 每个原位展开目录：最多 200。
- 同时原位展开目录：最多 8 个，使用最近交互顺序；第 9 个展开会折叠最早未被当前选择占用的目录。
- 最大原位嵌套深度：概览 2 层、详细 3 层（focus 的直接子项算第 1 层）。
- 理论加载节点上限约为 `500 + 8 × 200`，再加每组一个“其他”；不能随磁盘总节点数增长。

## 5. AppModel 导航状态

新增可观察状态，命名可按 Swift 风格微调，但语义固定：

```swift
currentNodeID: NodeID?              // 当前进入的目录，初始为 rootNodeID
breadcrumbs: [SnapshotPathItem]     // root -> current，含 scan-local 名称
navigationHistory: [NodeID]         // 当前 scan 内的进入历史
historyIndex: Int
selectedNodeID: NodeID?
selectedItem: SnapshotChildItem?
detailMode: .overview | .detail
expandedNodeIDs: ordered bounded set
treemapScene: TreemapSceneData?
sceneRevision: Revision?
sceneError: path-free optional error
```

所有状态还受现有 `refreshGeneration` 保护。

### 5.1 新根与重扫

- 采用新 root 时清空 history、selection、expanded cache 和 scene；收到 rootNodeID 后令 current=root，并建立 `[root]` history。
- 同一 root 重扫会得到新的 ScanID/NodeID 空间，因此同样重置导航；不能拿旧 NodeID 查询新 scan。
- picker 取消继续精确恢复此前稳定 phase 与地图，不改变导航。

### 5.2 单击与展开

- AppKit view 必须区分单击与双击：单击动作延迟约 220–250 ms；若第二击到达则取消单击任务。
- 单击任何真实 tile：设置 selection。
- 单击 directory/mountPoint：若未展开，异步加载其 child page 并原位展开一层；已展开时不反复发起查询。
- 单击 file/symlink/special：只选择，不尝试读取内容或进入。
- “其他”tile 只选择并显示折叠数量/权重，不尝试解析虚构 NodeID。
- 原位展开失败保留父地图并显示轻量错误，不改变 current focus。

### 5.3 双击与进入

- 双击 directory/mountPoint：进入该目录，清空原位展开集合，保留 scan 与容量；把新 NodeID 追加到 history，并截断任何 forward 分支。
- 双击非目录：选择并打开信息面板，不打开文件。
- 进入完成后加载 breadcrumbs 和当前页；加载期间保留旧地图并显示进度，成功后原子替换。

### 5.4 返回路径

- 后退：跳到 history 前一项；没有历史时禁用。
- 上一级：使用 breadcrumb 的倒数第二项；root 时禁用。上一级是一次新的 history 导航，因此之后“后退”可返回刚才目录。
- 点击面包屑：进入对应 ancestor，并写入 history。
- 新 scan revision 只刷新当前 scene，不修改 current、history、breadcrumbs、selection 或 expanded 顺序。
- 若某节点在扫描后被外部删除，SQLite snapshot 仍可浏览；Finder 操作单独报告项目已不存在。

## 6. Scene 数据与刷新

### 6.1 不可变 Scene

`TreemapSceneData` 是 `Sendable`、不含 AppKit 类型的不可变值，至少包括：

- scanID、generation、best-known revision、focus NodeID/name/aggregate completeness；
- 当前页与最多 8 个 expanded page；
- 每个真实节点的 name、kind、flags、logical/allocated/effective bytes、modifiedAt；
- parent/child 关系、展开顺序、detail mode；
- omitted count/weight 元数据；
- 当前 scan 是否 terminal。

绝对路径、security-scoped URL、SQLite handle 和 callback 不进入 scene。

### 6.2 刷新频率

- 扫描 progress/status 保持 Phase 3 的最多 10 Hz。
- 当前 focus page 的 treemap refresh 最多 4 Hz；在已有 refresh 运行时只记录一次 pending，不排队多个相同任务。
- expanded page 在用户点击时立即加载；扫描中最多 2 Hz 批量刷新当前可见 expanded 集合；terminal 到达后立即刷新一次全部可见 page。
- hover、鼠标移动不触发 SQLite 查询或 layout。
- revision 未增加且 bounds/detail/expanded 没变化时不重新布局。

多 parent page 可能来自相邻 revision；这是扫描中的 best-known 视图。每个 page 自身必须是同一 SQLite snapshot。terminal 强制刷新后，全部 page 必须达到最终 revision；测试覆盖这一收敛行为。

### 6.3 过期结果

所有 query/layout 结果携带：

```text
(scanGeneration, scanID, focusNodeID, sceneRevision, expansionVersion,
 detailMode, pixelWidth, pixelHeight, backingScaleFactor)
```

应用前逐项核对。任何旧 root、旧 focus、旧尺寸或旧 detail mode 的结果直接丢弃，不能让迟到任务覆盖新地图。

## 7. 纯布局层

### 7.1 Hierarchy composer

在 `SpaceJudgeTreemap` 新增纯函数 hierarchy composer：

1. 每个 sibling group 使用现有 `SquarifiedTreemap`。
2. 先用 `VisibilityReducer` 按理论像素面积折叠，再布局 `visible + other`。
3. current focus 的 children 填满画布；目录原位展开时，在父 tile 的内容区继续递归布局。
4. tile 的外框与 header 占用只影响可绘内容区，不改变 sibling group 的权重排序。
5. 0 weight 节点不画可见面积，但仍可在诊断数据中出现。
6. 相同输入、尺寸、mode 与 expansion 必须产生逐值相同结果。

`VisibilityReducer` 扩展一个默认值为 0 的 `precollapsedWeight`，用于合并 query limit 之外的已知权重；所有现有调用保持源兼容。溢出仍使用现有 saturating 语义并有测试。

### 7.2 绘制预算

- 根 page 最大 500，expanded page 最大 200。
- hierarchy composer 还要执行全 scene `maximumDrawableTiles = 2_000` 硬预算；超预算时从最小理论面积开始继续并入各 parent 的“其他”，不能直接丢权重。
- 概览：`minimumTileArea = 64 pt²`，max depth 2，只在较大 tile 显示名称。
- 详细：`minimumTileArea = 24 pt²`，max depth 3；tile 足够高时再显示大小。
- 阈值以 points 计算，render snapshot 同时携带 backing scale；像素对齐在 renderer 完成。
- padding/gap：顶层约 4 pt、嵌套约 2 pt；小 tile 自动降低圆角和 padding，不能产生负尺寸。

具体数值可由 Pi 在不突破 2,000 tile 和验收帧时间的前提下微调，并在报告中记录最终常量。

### 7.3 Render snapshot

布局线程输出 `TreemapRenderSnapshot`：

```swift
struct TreemapRenderTile: Sendable, Equatable {
    enum Identity { case node(NodeID); case other(parent: NodeID) }
    let identity: Identity
    let parentID: NodeID
    let rect: TreemapRect
    let contentRect: TreemapRect?
    let depth: Int
    let paletteIndex: Int
    let displayName: String
    let effectiveBytes: UInt64
    let collapsedCount: UInt64
    let kind: NodeKind?
    let isExpanded: Bool
}
```

Render identity 必须区分不同 parent 下的“其他”，不能把 `NodeID.max` 当作整个 scene 唯一身份。

## 8. 异步布局管线

- `NSViewRepresentable.updateNSView` 只提交不可变 scene、appearance、detail mode 和当前 bounds；不得同步查询数据库或执行 O(n log n) layout。
- representable coordinator 维护一个 layout task；新 key 到达时取消旧任务并在 detached/userInitiated context 计算。
- layout 完成后回到 MainActor，再次比对完整 key；只有最新结果进入 `TreemapCanvasView`。
- NSView resize 不查询 SQLite，只重用最近 scene。live resize 期间最多约 20 Hz 提交布局；中间帧可按当前 bounds 临时缩放上一 snapshot，结束 resize 后必须做一次精确布局。
- appearance 变化只更新颜色并重绘，不重新查询或重新布局。
- teardown 必须取消 layout/hover/single-click tasks，移除 tracking area 和菜单引用。

Apple 明确要求由 `NSViewRepresentable` 管理 AppKit view 的创建、更新和拆除，且 SwiftUI 控制其 frame/bounds；实现不得从 representable 内自行设置托管 view 的 frame。

## 9. Core Graphics Renderer

`TreemapCanvasView`：

- `@MainActor final class`，`isFlipped == true`。
- 只保存最新 immutable render snapshot、hit index、hover/selection identity 和外部 action closures。
- `draw(_ dirtyRect:)` 只绘制与 dirty rect 相交的 tile；不能在 draw 中布局、格式化整棵树、访问 SQLite 或文件系统。
- snapshot/尺寸变化可全量 `needsDisplay = true`；hover 变化只 invalidates 旧 tile、新 tile 和 tooltip bounds。
- 默认 opaque，先填满 dirty rect 背景；遵守 AppKit 对 opaque view 的要求。
- 使用 Core Graphics 批量填充与描边；名称用 Core Text/AppKit text drawing，但只对达到文字阈值的 tile 创建绘制属性。
- 不为 tile 建 subview、layer、tracking area、gesture recognizer 或 accessibility element。
- live scanning 不做面积动画；revision 直接替换，避免持续 animation 占用主线程。hover/selection 只允许轻量边框变化。

### 9.1 颜色

- 顶层 sibling 按确定性顺序分配 6 组低饱和颜色：绿、蓝、米、紫、杏、灰绿；颜色只区分目录，不表达安全或清理建议。
- expanded descendants 继承顶层 parent 的 palette index，通过 depth 调整明度。
- 选择边框使用产品绿色；hover 使用轻量白色/黑色透明覆盖。
- 使用动态 `NSColor` 并在 `effectiveAppearance` 下解析；浅色与深色均需满足文本可读性。
- 不使用微信商标、图标或品牌素材。

## 10. 命中测试与鼠标交互

### 10.1 单一 Tracking Area

Canvas 只创建一个覆盖 visible rect 的 `NSTrackingArea`，选项至少包含 mouse moved、entered/exited、active in key window 与 in visible rect。`updateTrackingAreas()` 中移除旧实例再创建新实例。

禁止每 tile 一个 tracking area。Apple 文档说明 tracking area 会随 view 管理并在几何变化时通过 `updateTrackingAreas()` 更新，本项目只需要一个区域，把精细命中交给自己的索引。

### 10.2 `TreemapHitIndex`

在纯 `SpaceJudgeTreemap` 中实现统一网格索引：

- 默认 cell 约 48–64 pt；bounds 变化时重建。
- 每个 tile 按覆盖 cell 写入 region index；每个 bucket 保持 draw order。
- point query 只检查所在 bucket，按 depth 与 z-order 从前到后返回最深真实/other tile。
- 边界采用固定 half-open 规则，避免共享边缘同时命中两个 sibling。
- 空/退化/负坐标、嵌套重叠、缩放坐标和确定性均有纯单元测试。

如果基准证明均匀网格在超大 tile 上内存膨胀，Pi 可改为 quadtree，但 public 行为与测试不变，并在报告解释。

### 10.3 Hover

- `mouseMoved` 只做坐标变换、hit query 和必要的局部重绘。
- 稳定停留约 350 ms 后显示单个自绘 tooltip：完整名称、格式化占用、类型；扫描中 best-known 值要有状态提示。
- 鼠标离开、snapshot 变化或目标消失立即隐藏。
- hover 不写 AppModel，不引发 SwiftUI body 高频重算。

### 10.4 Context menu

右键先更新 selection，再按 tile 构造一个小型 `NSMenu`：

- directory/mountPoint：进入目录、展开（未展开时）、查看信息、在 Finder 中显示。
- 普通文件/链接/特殊项：查看信息、在 Finder 中显示（可解析时）。
- “其他”：只显示折叠项目数量与占用，不提供 Finder 或进入。

没有删除、移动、打开文件或清理动作。

## 11. Finder 与运行期路径解析

SQLite 继续不保存绝对路径。Finder URL 只可由当前进程内的 `DirectorySelection.fileSystemPath` 加 snapshot ancestor names 临时组成：

1. `ancestors(of:)` 必须从当前 root 到目标且 scanID 一致；循环/缺父节点按已有错误处理。
2. 每个 name 必须严格 UTF-8 可解码，且是单个 POSIX path component；拒绝空、`.`、`..`、含 `/` 或 NUL 的值。
3. root node 不重复追加；子组件逐个 `appendPathComponent`。
4. 标准化后的目标必须仍位于选择 root 内；不解析 symlink 目标，也不跨越扫描边界。
5. 文件存在性检查在后台完成；最终 `NSWorkspace.activateFileViewerSelecting` 在 MainActor 调用。
6. 项目已移动/删除时显示“项目已不存在或位置已变化”，不显示完整私人路径，不写日志。

路径只活在当前 session，不进入 scene、数据库、日志或下一次启动状态。

## 12. 信息面板

选择或右键“查看信息”展示一个紧凑、可关闭的 SwiftUI overlay/popover：

- 名称、相对路径、类型。
- `effectiveAttributedBytes`；文件同时显示 logical/allocated，目录在有 aggregate 时显示聚合 logical/allocated。
- 修改时间（已知时）。
- package、hard-link duplicate、inaccessible、mount boundary、sparse、changed 等现有 flags 的人类可读说明。
- 目录 aggregate 是否 complete；扫描未完成时标记“正在统计”。
- 操作只有进入目录（适用时）和 Finder 显示；没有写操作。

取 directory aggregate 和 path 的任务也受 generation/selection token 保护；快速切换 selection 时旧详情不得覆盖新项。

## 13. 键盘与可访问性

不为数千个 tile 创建数千个 accessibility element。最低可访问路径：

- toolbar、面包屑、状态、容量和概览/详细使用原生 SwiftUI 控件。
- canvas 是一个 accessibility group，label 为“目录空间图”，value 包含当前目录、可见项目数和扫描状态。
- selected summary 是独立可访问区域，读出名称、大小、类型与状态，并提供“展开”“进入”“在 Finder 中显示”按钮。
- canvas 可成为 first responder。方向键按 tile 中心的方向/距离选择最近可见真实 tile；Return 对目录执行展开，Command-Return 进入目录，Escape 清除 selection。
- 键盘命中与鼠标使用同一 render snapshot，不能另建不一致的节点列表。
- 增大字体时工具栏允许截断面包屑中间项，但选择位置、返回、取消等关键操作不可消失。

## 14. 错误、并发与生命周期

- 所有 snapshot query error 转成 path-free `sceneError`；最后成功地图继续显示。
- AppModel 仍只有一个 active scan；替换 root、重扫和退出执行 Phase 3 的 cancel-and-wait。
- layout/query/hover/click-delay task 都必须在 shutdown 或 representable teardown 中取消。
- actor / MainActor 边界只传 `Sendable` 值；不能以 `@unchecked Sendable` 包装 AppKit 对象绕过检查。
- closure 从 NSView 回调 AppModel 时使用弱引用或 coordinator 生命周期，避免 canvas-model retain cycle。
- Thread Sanitizer 至少覆盖 scene refresh coalescing、旧 generation 丢弃、快速导航、连续 resize/layout cancellation 与 shutdown。

## 15. 性能预算与测量

新增 Release `spacejudge-treemap-bench`，使用固定 seed，输出机器/系统、参数和 JSON 结果。至少测量：

| 场景 | 工程门 |
| --- | ---: |
| 10,000 sibling 输入纯布局 p95 | < 50 ms |
| 2,000 drawable tile hit-index build p95 | < 10 ms |
| 100,000 次确定性 point query 平均 | < 20 µs/query |
| 1,280×800、裁剪后 ≤2,000 tile bitmap render p95 | < 16.7 ms |
| 同一 scene resize/layout 连续 100 次 | 无过期结果应用、无任务无界增长 |
| App UI snapshot 发布 | ≤ 10 Hz |
| treemap scene query/layout 发布 | ≤ 4 Hz |

基准必须：

- Release、arm64、本机运行；报告 iterations、warmup、p50/p95/max。
- 单独测 layout、index、render，不用一个总耗时掩盖瓶颈。
- 用 `/usr/bin/time -l` 记录 benchmark 峰值 RSS。
- bitmap render 使用与 App 相同 `TreemapRenderer`，不能另写更简单的假 renderer。
- 实际 App 用 500+ 项宽目录与多层 fixture 检查交互；CLI 数字不能替代 UI 观察。

若未达到门槛，Pi 报告真实数字和瓶颈，不能降低规模或减少 iterations 来宣称通过。

## 16. 自动化测试

### Domain / Store

- `SnapshotChildPage` revision/parent aggregate round-trip 与默认兼容。
- childPage 的 0 children、超过 limit、partial/complete parent aggregate。
- 一个只读 snapshot 内 revision、aggregate、count 与 items 一致。
- read transaction 在 prepare/step/decode/commit 失败后可继续查询。
- 有效权重顺序与 Phase 3 回归测试继续通过。

### Treemap

- `precollapsedWeight` 与 threshold collapsed 合并后总权重不丢失。
- 每个 parent 的 other identity 唯一；不会与真实 NodeID 冲突。
- hierarchy tiles 在各自 parent content rect 内、不重叠、确定性一致。
- max depth、max drawable budget、0 weight、overflow、极端宽高比。
- hit index 对随机点与线性 reference 结果一致，至少 10,000 个随机 scene。
- half-open 边界、deepest tile、resize scale 与空 scene。

### AppSupport

- 新 root/重扫重置 navigation；revision refresh 保留 focus/selection/expansion。
- back/up/breadcrumb history 语义。
- 第 9 个 expansion 的确定性 eviction。
- 快速 enter A -> enter B，A 的迟到 query/layout 不能覆盖 B。
- terminal refresh 收敛到最终 revision。
- omitted weight known/unknown/underflow/overflow 分支。
- runtime path resolver 的 Unicode、非法 UTF-8、`.`/`..`、slash、root mismatch 与已删除项目。
- picker cancel、cancel scan、permission、shutdown 的 Phase 3 测试全部保留。

### TreemapUI

- renderer 在 light/dark、empty、other、selected/hover 与文字阈值下不崩溃。
- dirty rect 跳过不相交 tile；hover 只请求局部 invalidation。
- 单击延迟被双击取消；双击目录只触发 enter 一次。
- tracking area 更新后只有一个本 view 拥有的 area。
- context menu 不出现任何删除/写操作。
- representable coordinator 丢弃旧尺寸/旧 generation layout。

## 17. Codex 真实验收路径

Pi 交付后 Codex 独立完成：

1. `arch -arm64 swift test`、Release build、package dependency 检查。
2. 全新 DerivedData 的 Xcode Debug/Release build。
3. 关键并发套件 Thread Sanitizer。
4. 运行 Release treemap benchmark，保存 JSON 与 `/usr/bin/time -l`。
5. 构造至少 12 个顶层目录、3 层嵌套、大小差异明显、含 600+ 直接子项的真实分配 fixture。
6. 实际 App 验证首批图、扫描完成收敛、面积顺序、其他 tile、单击展开、双击进入、back/up/breadcrumb、概览/详细、hover、右键、Finder、重扫与退出。
7. 900×640、1,280×800、浅色、深色和较大字体截图；关键操作无截断。
8. 检查进程退出、running scan、DB lock、spool、临时 fixture 和后台任务。

只有真实 UI、性能门与回归测试同时通过，才能新增 Phase 4 验收基线并把本文状态改为 Accepted。

## 18. Pi 实施边界

Pi 可自主决定私有类型命名、文件拆分、调色具体数值与 renderer 内部批处理，只要遵守本设计的 public 语义、有界上限和验收门。

Pi 必须保留：

- Phase 0–3 的 214 项测试和冻结语义。
- 单 writer + 独立 read-only reader。
- session-only root access 和数据库无绝对路径。
- `effectiveAttributedBytes` 唯一面积权重。
- 只读产品边界和无第三方依赖。

Pi 不得：

- 修改 HTML 原型、删除用户已有文件、提交、push、签名、公证或发布。
- 为方便绘制绕过数据库边界读取真实目录。
- 在主线程做 SQLite、文件枚举或完整 layout。
- 通过降低 fixture/iterations、隐藏“其他”或丢弃小项来满足性能数字。
- 顺带实现 AI、清理、删除、FSEvents 或权限持久化。

## 19. 官方 API 依据

- [NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable)：SwiftUI 管理 AppKit view 的创建、更新与拆除；托管 view 的 frame/bounds 由 SwiftUI 控制。
- [NSView drawing](https://developer.apple.com/documentation/appkit/nsview-drawing)：自定义 view 在 `draw(_:)` 内按 dirty rect 绘制并使用 invalidation API。
- [NSTrackingArea](https://developer.apple.com/documentation/appkit/nstrackingarea)：view 级鼠标 tracking 与 `updateTrackingAreas()` 生命周期。


## 20. 实现记录（Pi）

本节记录 Pi 实施时的最终常量与关键决策，供 Codex 复验参考；不改变本文状态，也不构成验收基线。

### 20.1 模块与文件

- `SpaceJudgeTreemap`（纯 Sendable）：`VisibilityReducer` 新增 `precollapsedWeight`；新增 `TreemapScene.swift`（`TreemapDetailMode`、`TreemapLayoutKey`、hierarchy 与 render snapshot 值类型）、`HierarchyComposer.swift`、`TreemapHitIndex.swift`。
- `SpaceJudgeAppSupport`：`SnapshotLoader` 增加 `ancestors`/`name`/`aggregate`；新增 `TreemapSceneData.swift`（`TreemapSceneData`/`TreemapScenePage`/`SnapshotPathItem`）与 `RuntimePathResolver.swift`；`AppModel` 增加导航、展开、场景刷新、选择与 Finder 定位。
- 新增 `SpaceJudgeTreemapUI` product/target：`TreemapRenderer.swift`、`TreemapCanvasView.swift`、`TreemapViewRepresentable.swift`。App target 链接 `SpaceJudgeAppSupport` 与 `SpaceJudgeTreemapUI`。
- `SpaceJudgeStore.SQLiteSnapshotRepository.childPage` 在只读连接的一个 `BEGIN DEFERRED` 事务内读取 revision、parent aggregate、count 与 items；`SQLiteDatabase` 新增 `withReadTransaction`。
- 新增 `spacejudge-treemap-bench` 与 `SpaceJudgeTreemapUITests`。

### 20.2 最终常量

- focus page 500，expanded page 200，同时 expanded 最多 8；第 9 个按交互顺序折叠最早且非当前选择的目录。
- 概览：`minimumTileArea = 64`、max depth 2；详细：`minimumTileArea = 24`、max depth 3；全 scene drawable tile 硬上限 2,000。
- 全 scene 超预算时按 1.5× 递增阈值重排，直到 ≤2,000；不丢权重。
- padding：顶层 gap 4 pt、嵌套 2 pt；expanded header 最大 16 pt；小 tile（最短边 < 28 pt）不画圆角。
- hover tooltip 350 ms；单击仲裁 230 ms；tracking area 恰好 1 个 view-level 实例。
- 场景刷新节流：无 expanded 时 250 ms，有 expanded 时 500 ms；terminal/进入/展开立即刷新；layout key 包含 generation/scan/focus/revision/expansion/mode/size/scale。

### 20.3 测试基础设施说明

`AppModelTests` 的既有断言要求诊断列表的 `childPage` limit 恒为 100。为不改变 Phase 0–3 测试，`AppModel` 新增可选 `sceneReader` 依赖（生产环境默认复用同一个只读 repository），`AppModelTests.makeModel` 为场景读取注入隔离的 stub。原有断言语义未变，诊断列表仍走 limit 100。

### 20.4 性能实测（本机）

Release、arm64、Apple M1 Max（MacBookPro18,2）、macOS 26.6.2、10 核、64 GB。固定 seed，layout/index/render warmup 5，hit warmup 2,000；benchmark 退出码 0：

| 场景 | iterations | p50 | p95 | max | 门 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 10,000 sibling 纯布局 | 100 | 0.84 ms | 2.75 ms | 5.11 ms | < 50 ms |
| 2,000 tile hit-index build | 200 | 0.099 ms | 0.105 ms | 0.18 ms | < 10 ms |
| 100,000 measured point query 平均 | 100,000（+2,000 warmup） | 0.125 µs | 0.167 µs | 21.8 µs | < 20 µs |
| 1,280×800 render | 60 | 6.05 ms | 6.46 ms | 6.52 ms | < 16.7 ms |
| 100 次纯 composer resize layout | 100 | 0.53 ms | 0.58 ms | 0.66 ms | 仅纯布局耗时 |

`/usr/bin/time -l` 峰值 RSS ≈ 28.7 MB。renderer 关键优化：按 `(depth, palette)` 批量 fill/stroke、最小边 < 28 pt 的 tile 使用直角矩形（圆角栅格化是主要瓶颈）。benchmark 的 resize 指标只测纯 composer 耗时，不声称测了 coordinator 的任务增长；coordinator latest-wins/cancellation 由 `TreemapCoordinatorTests` 覆盖。

### 20.5 已知限制

- 真实 UI 交互（选择目录、单击展开、双击进入、Finder、浅/深色截图）由 Codex 在 GUI 会话中复验；Pi 环境只做了进程启动/退出与 benchmark 级验证。
- 多 parent page 可来自相邻 revision，属扫描中的 best-known 视图；terminal 刷新后收敛。
- 未实现跨进程缓存或持久化布局。
- 信息面板的相对路径由 breadcrumb 名称加场景内展开页名称拼接；若所选节点不在当前场景的可达页内则显示“—”，不伪造绝对路径，也不持久化。

### 20.6 Round 1 review 修正（Codex feedback）

- Renderer `render` 用 `defer { context.restoreGState() }`，所有早退路径都恢复 dirty-rect clip；新增 clip 边界与跨 dirty-rect 填色回归测试。
- `AppModel` 引入完整 `SceneQueryToken`（generation/scan/focus/mode/expansionVersion/expansionSet/terminal）与 `sceneQueryTask`/`sceneQuerySequence`；结果只在 token 与当前模型完全一致时应用，查询任务在 reset/替换/shutdown 时取消，迟到完成不触碰状态。
- Canvas 统一 `updateSelection` 同时失效旧/新 selection；方向键选择会回调模型 `select`，summary/accessibility 同步。
- `setRenderSnapshot` 清除消失的 hover 与 tooltip；hover 切换失效旧 tooltip 边界；`isBestKnownValues` 在扫描中给 tooltip 加“正在统计”。
- 新增 `TreemapOtherSelection`：`other(parent:)` 可选择并显示折叠数量/已知权重，无 NodeID、无 Finder/进入；选择 summary 与 canvas 高亮同步。
- Store 测试新增直接验证 `withReadTransaction` 抛错后可再次开启事务；空目录 aggregate 总数为 0。
- benchmark 架构改为编译期判定（arm64），hit 场景改为 2,000 warmup + 100,000 measured，resize 指标更名 `resizeLayout100` 并删除同义反复的 appliedKeys；coordinator 2000 tile 变化由单测覆盖。
- `TreemapSceneData.hierarchy()` 的 focus 权重改用 saturating 加法；`hiddenOmittedCount` 文档改为 scene-wide。

### 20.7 Round 2 review 修正（Codex feedback）

- **detail mode 不再让在途查询卡死**：`SceneQueryToken` 移除 `mode`（mode 只影响布局阈值，不影响读取哪些页）；查询结果在 apply 时用 `TreemapSceneData.withDetailMode(live mode)` 重盖。这样在途查询期间切换概览/详细一定收敛，且已加载场景切换 mode 不发多余 SQLite 读，只由 coordinator 按 key 重新布局。新增“首个场景到达前切换 mode 仍收敛”的延迟查询测试，以及“仅 mode 变化从同一 scene 重排一次”的 coordinator 测试。
- **右键不再展开**：`rightMouseDown` 改走 `handleRightClick` → `updateSelection` + `actions.select`，不再调用会触发延迟展开的 `singleClick`。新增测试证明右键 select 一次、`singleClick`/expand/enter 均为 0。
- **未知 omitted 不再混入 known-weight other**：`HierarchyComposer` 只在 `omittedWeight != nil` 时把 `omittedCount` 计入 other tile 的 `collapsedCount`；权重未知时 other 只代表已加载的被折叠项，未知数量走 scene-wide `hiddenOmittedCount`。新增 compose 两个分支的纯测试（未知且无折叠、未知且有折叠、已知对照），`TreemapSceneData.hiddenOmittedCount` 计算属性与 `AppModel.hiddenOmittedMessage`（“还有 N 项正在统计”）在 UI 区展示。
- **tooltip 终态刷新**：tooltip 只存 tile，不存文本；文本在绘制时由当前 `isBestKnownValues` 计算，`other` tile 也带“正在统计（best-known）”。终态切换时已有 tooltip 全量重绘。新增“任务触发前切换”“已可见时切换”“other tile 标记”三个确定性测试（轮询等待，兼容 TSan 时序）。

### 20.8 Round 3 GUI 验收修正（Codex feedback）

- **展开场景到达后不重排（阻断）**：`TreemapViewRepresentable` 的布局 key 改为使用 `scene.scanGeneration` 与 `scene.expansionVersion`（描述已装入 scene 的内容），而不是可能先行的 `content`/模型版本；`content` 字段只作为 SwiftUI change trigger。新增确定性 race 回归 `A scene arriving after a model-version bump is still laid out`：old scene(v1)+model v2 先 update，随后 new scene(v2，同 scan/focus/revision/mode/size) update，断言第二次一定提交且最终 snapshot 含展开子项 `node(20)`。
- **Finder 错误跨新扫描残留**：`ContentView` 删除本地 `@State revealMessage`，footer 直接显示可观察的 `model.revealError`（新根/重扫、清选择、移动焦点时由模型重置）；新增 `.onChange(of: model.scanID)` 关闭指向旧选择的 info panel。新增模型回归 `A new scan clears a stale reveal error`：用非法 path 组件（`..`）触发 reveal 失败，再 `chooseRoot()` 新根，断言 `revealError == nil`。
- **工具栏整行不可见（阻断）**：真实复现与截图确认根因是 AppKit `NSViewRepresentable` 画布与 SwiftUI 工具栏作为同一 `VStack` 的兄弟时，画布被合成在工具栏之上。改为 `treemapArea.safeAreaInset(edge: .top)` / `.safeAreaInset(edge: .bottom)` 承载工具栏与 footer，使其始终绘制在画布之上；画布仍是 opaque、flipped 的单绘制面（设计要求不变）。900×640 与更大窗口的截图证据见 run-dir。XCTest 无法做可靠像素验收，故以 canvas 契约测试（`isFlipped`/`isOpaque`/无 subview）+ App 级截图说明。
- 新增 DEBUG-only `SPACEJUDGE_TEST_ROOT_PATH`（Release 忽略，与既有 `SPACEJUDGE_TEST_DATABASE_PATH` 同类），用于自动化启动时选择 fixture 根，便于复现工具栏与展开场景。
