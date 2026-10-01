# Phase 7 Native MVP · Pi 实现与自测记录

状态：**Pi 自测完成，待 Codex 验收**

日期：2026-10-01
基线 commit：`43f55d8`（master，工作树含既有 Phase 6 脏文件，未 commit/push）
机器：Apple M1 Max / macOS 26.6.2 (build 25G83)；命令均以 `arch -arm64` 执行。

本记录是 Pi 的实现证据，不代表独立验收。真实 NSOpenPanel / Finder / 导航 / 取消 /
代表尺寸 / 浅深色检查由 Codex 独立执行。验收后按 Codex 反馈完成第二轮修复
（标题几何、三个独立失败回归、loading/error/content、0 占用入口、容量回退、小窗自适应）。

## 1. 范围与设计入口

- `docs/01-mvp-spec.md`：容量退化口径补充 Darwin `statfs` 来源。
- 既有 `docs/05-testing-and-acceptance.md`、本机个人清理记录（仅本地保留）
  的读数、容量与安全语义全部保留。
- 默认只读、单快照、自身 workspace 排除、安全关闭、边界策略、双单位 CLI/MCP 未改动。

## 2. 第一轮实现

### 2.1 容量误报修复（Domain + Store）

- `VolumeCapacityResolver.facts(...)` 新增可选默认参数 `fileSystemAvailable: UInt64? = nil`，
  三参数旧调用保持源兼容。正的重要用途值优先；重要用途缺失/为负/为 0 且普通可用或 `statfs`
  为正时退化到普通可用并标记 `standardAvailable`；所有来源为 0 才保留 0；`available > total`
  降级为未知；`statfs` 乘法溢出安全。
- 新增 `FileSystemCapacityProbe`（`open`+`fstatfs`，FD 始终关闭）。
- `VolumeStorageCapacityProvider` 与 `FoundationVolumeFactsProvider` 使用同一解析规则；未新增
  `CapacitySource` 枚举，SQLite/CLI/MCP 编码不变；512/256 MiB 门未改。

### 2.2 自动浅层嵌套预览（AppSupport）

- `previewExpandedLimit = 6`、`previewPageLimit = 80`，合并用户展开（≤8×200），预算有上界。
- `suppressedPreviewNodeIDs` 让明确折叠的目录跨刷新保持折叠；场景 revision 取所有页面最大值。

### 2.3 原生界面与 presentation

- `ContentView` 重写为紧凑导航 + 画布 + 容量小条；窗口默认 1120×760、最低 736×560。
- `AppPresentation.swift` 提供纯 `AppPresentationState` / `CapacityPresentation`。
- `TreemapCanvasView` 新增 `collapse` 动作与右键“折叠”。

## 3. 第二轮修复（Codex 独立验收反馈）

### 3.1 标题几何（HierarchyComposer + TreemapRenderer）

- 新增共享纯几何 `Sources/SpaceJudgeTreemap/TreemapTileChrome.swift`：header 高度、名称/大小
  标签布局、裁剪区域、圆角，全部可单测。
- composer 的 `contentRect` 用同一 `headerHeight`，子内容从 header 下方开始；18pt 统一 header
  覆盖被删除，改为按目录色组缓存的协调 header band。
- renderer 每个标签用自己的区域 `saveGState/clip/restore`，父标题不再跨到子块；两行文字需要
  足够高度，较矮块只一行或不显示；宽块大小行右对齐内联。
- 新增几何断言：`Tests/SpaceJudgeTreemapTests/TileHeaderGeometryTests.swift`（header 边界、
  窄块/矮块/宽块、composer 子块不侵入 header）与
  `Tests/SpaceJudgeTreemapUITests/TileHeaderRenderTests.swift`（不同色组 header 不同、header
  与填充不同、子块在 header 下方）。

### 3.2 视觉收尾

- 六组柔和目录色：light `(.855,.91,.875) (.865,.907,.944) (.934,.9,.848) (.899,.888,.941)
  (.938,.889,.851) (.892,.925,.858)`；dark 独立调深，非简单反相。
- 名称 13pt medium、深灰绿；大小 11pt、弱一级灰绿；文字内边距 8pt；大块圆角 8pt；细浅边框。
- 绿色选中轮廓与 tooltip 保留；没有为 tile 创建 NSView；draw 门仍满足。

### 3.3 三个独立失败回归（均已修复）

- `collapse` 现在对“用户显式展开后折叠”的目录也写入预览抑制，刷新不再自动重开。
- 空目录判定改用当前 focus 的 `page`/`aggregate`，不再用整次扫描总字节。
- 首次读取失败（`scene == nil && sceneError`）归类 `.sceneError`，无旧图也有可见失败与重试。
- `arch -arm64 swift test --filter MVPIndependentAcceptanceTests` 由 EXIT1 变为 EXIT0（3/3）。

### 3.4 loading / error / content 区分

- `AppPresentationState` 新增 `.loading`；`resolve(...)` 增加默认参数 `isLoading` /
  `sceneMatchesFocus`（旧调用源兼容）；`sceneError` 优先于扫描/取消阶段。
- `AppModel` 新增 `isSceneLoading`、`isSceneStale`；`retrySceneLoad()` 不再提前清除错误文字；
  `selectedRelativePath` 在旧图与新 focus 不一致时返回 nil，避免误用当前路径。
- 状态回归：`Tests/SpaceJudgeAppSupportTests/SceneLoadingStateTests.swift` 覆盖首次失败、重试
  仍失败、恢复、focus 切换中/旧图、扫描中读取失败、旧图保留错误。

### 3.5 0 分配项目入口

- 顶部“列表”按钮打开有界 popover：显示当前 focus 页（≤500 项）的名称/大小/类型，0 占用标
  “0 占用”，点选接入现有 info/Finder；`.zeroAllocation` 解释里也有“查看项目”入口。
- 不是常驻侧栏/列表模式，不读内容，不虚构面积。

### 3.6 容量查询失败回退

- `FoundationVolumeFactsProvider` 现在无论 Foundation 是否抛错都对确切路径 `open`+`fstatfs`；
  缺失路径探测失败 → 未知，不借祖先。
- Store provider 也走同一 resolver，因此正的重要用途值同样经过 `available > total` 校验。
- Domain 与 Store 各新增可注入 raw lookup/probe 的 production-provider 测试：Foundation throw +
  现存路径回退、缺失路径、`important > total`、异常 0 而其他为正、全部 0。真实正值读取仅作冒烟。

### 3.7 小窗口与验收入口

- 状态区改为 `ViewThatFits`：窄窗口只留状态标题，完整计数进入 tooltip/AX 值；关键按钮仍可操作。
- DEBUG-only seam：`SPACEJUDGE_TEST_APPEARANCE=dark|light`、`SPACEJUDGE_TEST_WINDOW_SIZE=WxH`
  （736x560 / 1120x760 / 1440x900 等），Release 完全忽略；真实 Release 标准启动已构建通过。

## 4. 第三轮修复（第二轮独立验收反馈 feedback-2）

### 4.1 旧地图不再接受交互

- `AppModel.select/selectNode/selectOther/expand/collapse` 在 `isSceneStale` 时一致提前返回；
  `finderURLForSelection` 在陈旧时返回 nil 并给出无路径提示。`enter` 本身不全局禁用，
  面包屑/后退/上一级/快速导航仍可用。
- `ContentView` 的 canvas 与 project list 在陈旧时全部不动作；列表按钮禁用，焦点切换后自动
  关闭 popover並显示 loading，而不是把旧页当“当前范围”。
- 回归：`SceneLoadingStateTests.staleMapRejectsActions`（选择/展开/折叠/Other/Finder 全部拒绝，
  `goBack` 仍可离开）、`MVPIndependentAcceptanceTests` 4/4。

### 4.2 启动重试单飞

- 新增可测 `BootstrapGate`（单飞 begin/end）与 `BootstrapGateTests`。
- `AppDelegate` 用 gate + `isBootstrapping` + `isTerminating`：重试先清错显示准备状态；
  重复点击被拒绝；终止后晚到的 bootstrap 结果会被丢弃并关闭连接；失败保留真实提示可再试。

### 4.3 并行 spool / FD 测试隔离（经反馈允许的最小修改）

- `ScanTestSupport.swift` 新增 `spoolFiles(in directory:)`，`spoolFilesInTemporaryDirectory()` 变为
  其临时目录包装；另新增 `settledFileDescriptorCount()`（短窗口取最小）。
- `FollowupRegressionTests.swift` 的 4 个 spool 用例各自建立 `TempFixture` 作为 spool root
  （位于扫描 fixture 之外），向对应 engine 注入 `ScanConfiguration(spoolDirectory:)`，只统计该
  root 并断言完成后为空；4 处 FD 断言改用 `settledFileDescriptorCount()`。保留 correctness /
  cancel / FD / queueHighWater / spoolUsed / terminal 断言，未串行化全局测试。
- 同类全局计数污染：`ScanEngineTests.swift` 与 `PagedEnumerationTests.swift` 的 FD 基线/后续采样
  也改用 `settledFileDescriptorCount()`（tolerance 不变，未弱化泄发断言）。
- 连续多轮全量并行通过（`feedback2/full-test-8..12` 连续 5 次绿）。

### 4.4 自测自身竞态修复

- `SceneLoadingStateTests` 的首次失败/旧图失败用例改为等待 `sceneError != nil && !isSceneLoading`，
  消除读取失败后可能开始的后续刷新与断言之间的竞态。定向重复 8 次稳定。

### 4.5 扫描范围与当前 focus 不再混淆

- `AppModel.focusAttributedBytes` / `focusAggregateIsComplete` / `focusSizeLine` 只取当前 focus
  的 `focusAggregate`；未知用 —、未完成标“正在统计”，绝不回退到 root 总量。
- `scanScopeReconciliationLine` 把根对账明确标为“扫描范围 · …”，与容量来源一起放小条的 tooltip。
- 回归：`SceneLoadingStateTests.focusSizeUsesFocusAggregate`（进入子目录后 focus 大小=子聚合
  500 B，而非 root 10 KB）。

## 5. 自测

命令与退出码（每个数字都指向其唯一原始文件）：

| 命令 | 结果 | 原始文件 |
| --- | --- | --- |
| `arch -arm64 swift test --filter MVPIndependentAcceptanceTests` | EXIT=0，4/4 | `logs/feedback2/independent-acceptance.txt` |
| `arch -arm64 swift test`（多轮） | 连续 5 次 EXIT=0，**517 tests / 68 suites passed** | `logs/feedback2/full-test-8..12.txt` |
| 定向回归（BootstrapGate/SceneLoading/TileHeader/Volume/Space） | EXIT=0，58 tests / 6 suites | `logs/feedback2/targeted.txt` |
| `xcodebuild … -configuration Debug … CODE_SIGNING_ALLOWED=NO` | EXIT=0，BUILD SUCCEEDED | `logs/feedback2/xcodebuild-debug.txt` |
| `xcodebuild … -configuration Release … CODE_SIGNING_ALLOWED=NO` | EXIT=0，BUILD SUCCEEDED | `logs/feedback2/xcodebuild-release.txt` |
| `arch -arm64 swift run -c release spacejudge-treemap-bench` | EXIT=0，layout10k p95 **0.833333 ms**，draw 1280×800 p95 **6.526958 ms**，resize p95 **0.609584 ms** | `logs/feedback2/treemap-bench.txt` |
| Debug App 冒烟（light + 736x560 seam + fixture） | 107 节点、scan completed、stderr 无 negative/invalid/geometry 告警、按精确 PID 终止 | `logs/feedback2/app-min-smoke.out` |

历史忠实记录（未为“变绿”而重跑删除失败）：`feedback1/full-test-1.txt` 因全局 spool 污染 EXIT1
（已修）；`feedback2/full-test-3.txt` 因全局 FD 计数 EXIT1（已修）；`feedback2/full-test-6.txt` 因自测
自身竞态 EXIT1（已修）；其余 `feedback2/full-test-1..5,7..12.txt` 均 EXIT0。

## 6. 百万节点内存门修复（feedback-5）

feedback-4 的实测（256/64/1 缓冲差异都在噪声内、最高 260–270 MB）证明事件缓冲不是主因，
堆采样定位到已消费工作项与已完成目录的工作状态。本阶段据此修复：

- 新增 `DirectoryWorkQueue` ring FIFO：`pop` 即把槽位置 nil，释放已消费 `pathBytes`/FD 引用；
  容量按需增长但不超过 `maximumQueuedDirectories`，溢出仍走 spool；FIFO、queueHighWater、
  取消/FD 生命周期不变。
- `DirectoryAggregateBuilder.retire`：目录最终聚合已折叠进父且父引用已捕获后，回收
  `direct`/`children`/`parentOf`；保留轻量 `completed` 去重集合；root 永不 retire。
  coordinator 同步回收 `completionInfo`/`pendingChildren`/`selfComplete` 对应项。
- 保留 `eventBufferSize` 默认 64，但源注释不再声称它是已证实主因。

保留百万 fixture 重扫（独立 0700 workspace，`/usr/bin/time -l`）：

| 轮次 | maxRSS (B) | peak footprint (B) | real (s) |
| --- | --- | --- | --- |
| 1 | 186,318,848 | 196,543,136 | 15.68 |
| 2 | 174,718,976 | 164,774,584 | 13.90 |
| 3 | 181,927,936 | 170,672,800 | 14.35 |

**均低于 250,000,000 B 工程门**。每轮 `completed`、dir=175230、file=824770（=1,000,000）、
issue=0、root attributed=3378257920；独立只读重开 DB 确认 nodes=1,000,000、aggregates=175230、
root aggregate=3378257920/175229 dirs/complete。堆采样中 `_ContiguousArrayStorage<UInt8>`
从 93.8 MB 降至约 50.9 MB，工作项存储从 16.8 MB 降至约 3.7 MB。

100k E2E 不回归：first 48–69 ms、total 0.745–0.812 s、RSS 50–56 MB（门：first<500 ms、total<2 s）。
`arch -arm64 swift test` 连续两次 EXIT 0（528 tests / 70 suites）；Debug/Release 构建 EXIT 0。

### 6.1 独立失败的诚实文案

`AppPresentationState.sceneError` 文案由“无法读取快照，已保留上一版地图。” 改为
“无法读取当前位置的快照，请重试。”，不再假设旧图存在；旧图保留机制与重试动作不变。
新增 `AppPresentationTests.sceneErrorWording`。

详见 `/tmp/spacejudge-mvp-pi.ltveNY/feedback-5-report.md` 与 `logs/feedback5/`。

## 7. 菜单状态修复（feedback-6）

SwiftUI `.commands` 的启用条件读 `@Observable` 的 `AppModel`，而 `AppDelegate` 是
`ObservableObject`；两级生命周期未被正确观察，bootstrap 后菜单项仍长期 disabled（实测即使
去掉 `.disabled` 也一样）。修复：

- `AppSupport` 新增纯值 `AppCommandPolicy`（canChooseRoot/canRescan/canCancel）；
  `AppModel.commandPolicy` 派生，工具栏与菜单同源。
- `AppModel.observeCommandPolicy` 用 `withObservationTracking` 动态重发布；`AppDelegate`
  以 `@Published commandPolicy` 接住并刷新菜单。
- `AppDelegate` 安装真正的 AppKit “扫描”菜单（`target=self` + `validateMenuItem` +
  `autoenablesItems=false`），移除不可靠的 SwiftUI `.commands`。
- `AppCommandPolicyTests`（10）覆盖策略与动态重发布。

自测（DEBUG seam `SPACEJUDGE_TEST_MENU_SELFTEST=1` 发送 ⌘R key equivalent，不依赖系统激活）：
无根 `rescanEnabled=false` 且无动作；有根且完成 `rescanEnabled=true` 且动作触发。
本轮 `arch -arm64 swift test` EXIT 0（**538 tests / 71 suites**，`logs/feedback6/full-test.txt`），
Debug/Release 构建均 EXIT 0（`logs/feedback6/`）。详见 `/tmp/spacejudge-mvp-pi.ltveNY/feedback-6-report.md`。

## 8. 扫描中浏览与部分结果文案（feedback-7）

- 目录元数据不再等整棵子树聚合：`markSelfComplete` 在目录自身枚举完成/失败时就发布不可变
  `NodeRecord`（flags 已确定，根同样），`tryCompleteUpward` 只做 final aggregate 与回收。
  每 NodeID 仍只插入一次，不提前伪造 aggregate/面积；schema/API/边界/硬链接语义不变。
- 新增 `AppProgressWording` 共享规则：omitted toast 统一“未显示”，active 后缀“正在统计”、
  terminal incomplete 后缀“未完成”；cancelled/failed/permissionLimited 按 terminal 处理。
  `AppModel.hiddenOmittedMessage`/`focusSizeLine` 与 `ContentView` 信息面板改用该规则。
- 新增 `DirectoryPublicationTests`（真实 runner+SQLite 的 gated root→child→grand 集成测试，
  以及失败目录 flag 保留）与 `AppProgressWordingTests`。
- 本轮：`arch -arm64 swift test` EXIT 0（**545 tests / 73 suites**）；TSAN 定向 51 tests/8 suites
  无报告；取消/FD 定向 7 tests/3 suites；E2E 100k RSS 50.3 MB、first 46 ms；E2E 1m RSS
  **133,677,056 B < 250,000,000**、first 208.9 ms、13.89 s、fdDelta 0；Debug/Release 构建 EXIT 0。
  详见 `/tmp/spacejudge-mvp-pi.ltveNY/feedback-7-report.md` 与 `logs/feedback7/`。

## 9. 已选目录详情随扫描刷新（feedback-8）

- `AppModel` 在应用新 scene 时调用 `refreshSelectionFromScene`：用新 scene 刷新 `selectedItem`，
  选中目录页已加载时用 `TreemapSceneData.knownAggregate(for:)` 刷新 aggregate，否则仅对该目录
  发起有界单飞 aggregate 查询（独立于 `selectionToken`，select/clear/navigate/新扫描/shutdown
  均作废旧查询；complete 后不再重复查询）。
- 未知目录聚合不再显示 0：`selectedEffectiveBytes`/`listEffectiveBytes` 对未知目录返回 nil，
  UI 显示“—" + active“正在统计”/terminal“未完成”；真实 complete 0 仍为 0；项目列表不再对
  未知目录标“0 占用”。
- 新增 `SelectedDetailRefreshTests`（7）：scene 刷新不重选即更新、慢旧查询不覆盖新值、
  clear/导航无串线、取消后 terminal 诚实、complete 0 保持 0、列表未知目录非确定 0。
- 本轮：`arch -arm64 swift test` EXIT 0（**553 tests / 75 suites**）；定向 TSAN 46 tests/5 suites
  无报告；Debug/Release 构建 EXIT 0。scanner/core 未改，未重跑百万/MCP。详见
  `/tmp/spacejudge-mvp-pi.ltveNY/feedback-8-report.md` 与 `logs/feedback8/`。

## 10. 已选详情刷新的两个边界（feedback-9）

- `startAggregateQuery` 的 generation 检查移到所有 bookkeeping 之前：过期且不响应 cancel 的
  旧查询返回时不再擦掉新 task 句柄、不消费新 pending、不写 aggregate。新增可闸门、忽略 cancel
  的 actor double 回归 `staleQueryDoesNotDisturbNewTask`（验证过在旧代码下会失败）。
- 新增 `TreemapSceneData.containingPage(for:)`；`listEffectiveBytes` 在父页 aggregate complete
  时把未展开的 0 权重子目录认定为真实 0，父缺失/incomplete 仍为未知，不追加查询；selected 有效
  0 继续用点查询。Codex 的 `completedParentEstablishesZero` 通过。
- 本轮：`arch -arm64 swift test` EXIT 0（**557 tests / 75 suites**）；定向 TSAN 51 tests/6 suites
  无报告。按反馈未重跑 million/MCP/xcodebuild。详见 `/tmp/spacejudge-mvp-pi.ltveNY/feedback-9-report.md`。

## 11. 取消测试调度依赖修复（feedback-10）

- 因果：`FileSystemScanEngine.cancel()` 在终态已发布后是 no-op，已完成的扫描保留 completed 是
  正确语义；已有终态竞态回归。`AgentCLITests.scanCancels` 失败是测试时间窗不稳定，非产品缺陷。
- 将该用例改为可闸门 `GatedCancelEngine`（`.started` 后不结束，只有 `cancel` 被真实调用才发布
  恰好一个 `.cancelled`），经既有内部注入缝 `AgentScanCommand.runSession` 走真实 runner+SQLite；
  断言退出 0、outcome cancelled、持久化 cancelled 一致。产品源码零改动；保留真实 SIGINT 子进程
  测试与真实 E2E 取消基准。
- 本轮：`swift test --filter scanCancels` ×12 全绿（约 0.017 s/次，无时间窗依赖）；全量
  `swift test` 连续两次 EXIT 0（**557 tests / 75 suites**）；全量 TSAN EXIT 0（557 tests/75 suites，
  无报告）。详见 `/tmp/spacejudge-mvp-pi.ltveNY/feedback-10-report.md` 与 `logs/feedback10/`。

## 12. 取消后已提交节点可浏览（feedback-11）

- 取消时新增包内旁路（`package` 的 `CancelledDirectoryCheckpoint` /
  `CancelledCheckpointProviding`，不改 `ScanEvent`/`ScanSummary`/schema/CLI/MCP）：
  `FileSystemScanEngine` 在取消分支保留未发布目录身份与所需名字（含被抑制的在飞 flush
  批次），存入单个最新槽；`PersistingScanRunner` 在持久化 `cancelled` 前用自身最后收到的
  revision+1 写一个有界目录批次，写入失败走失败路径。设计见 ADR 0013。
- 新增 `CancelledCheckpointTests`（5）：真实 runner+SQLite 的可闸门取消后祖先链/页面完整、
  被抑制 flush 的目录保留、写入失败不发布 cancelled、完成/连续扫描不留槽。并修复既有
  时间窗依赖的 `VisibleVolumeGroupScanTests.syntheticCancel`。Codex 独立测试暴露的
  “forced cancel + checkpoint 写失败未 fail” 真实缺口已修复。
- 本轮：全量 `swift test` EXIT 0（**565 tests / 77 suites**）；全量 TSAN EXIT 0
  （565/77，无报告）；100k 取消 E2E cancelled、延迟 81.5 ms、fdDelta 0；包装百万 fixture
  Release CLI 重扫 completed、maxRSS 149,880,832 B、SQLite 重开 nodes=1,000,001。
  详见 `/tmp/spacejudge-mvp-pi.ltveNY/feedback-11-report.md` 与 `logs/feedback11/`。

## 13. 已知限制与未完成

- 百万节点峰值 maxRSS 已降至 174.7–186.3 MB（低于 250 MB 工程门，Pi 自测）；未做
  NameInterner 重写，也未改动聚合/硬链接/符号链接口径。
- 真实 NSOpenPanel / Finder / 导航 / 取消 / 代表尺寸 / 浅深色的独立 UI 验收属 Codex；Release
  负几何告警仍建议在最终 Release 交付时人工复核（Debug 同布局路径 736×560 未出现）。
- 自动预览每次场景刷新最多增加 6 次 SQLite 子页查询（每页 ≤80 项），有界；真机 UI p95 待复核。
- 未 commit/push，未安装替换用户 App，未触碰发布凭据。
- 未修改 Codex 的 `scripts/acceptance/`、docs 35/36 或独立测试。

## 14. 后台服务

本任务未启动任何常驻后台服务。真实 App 冒烟实例已按精确 PID 终止；Codex 管理的实例未被触碰。
