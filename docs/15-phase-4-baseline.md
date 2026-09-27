# Phase 4 验收基线

状态：Accepted

验收日期：2026-09-26

## 1. 交付结果

Phase 4 已把 Phase 3 的“最大项目诊断列表”替换为真实 SQLite 快照驱动的高性能原生空间图：

- 新增 `SpaceJudgeTreemapUI`：一个 `NSView`、一个 view-level tracking area、一个空间命中索引，由 Core Graphics 批量绘制；没有为每个 tile 创建 SwiftUI view、`NSView` 或 `CALayer`。
- 新增 `SpaceJudgeTreemapBench`，固定 seed 分别测量 layout、hit-index、point query、bitmap render 与 resize layout；App 与 benchmark 使用同一个 renderer。
- 当前目录最多读取 500 个直接子项；每个原位展开目录最多 200 个；同时展开最多 8 个；最终 drawable tile 上限 2,000。上限与磁盘总节点数无关。
- 面积只使用 `effectiveAttributedBytes`。SQLite 在同一个只读 transaction 中取得 revision、parent aggregate、总数和有界 child page。
- 已知的截断权重合并成每个 parent 唯一的“其他”tile；未知权重不猜测面积，只显示“还有 N 项正在统计”。
- 支持单击选择并原位展开、双击进入、后退、上一级、面包屑、概览/详细、右键菜单、信息面板、Finder 定位、键盘选择和单 canvas 可访问性摘要。
- 扫描 revision 更新保留 focus、selection 与 expansion；查询、布局、点击延迟和 tooltip 任务都受 generation/key 或 teardown 保护。
- 工具栏和 footer 使用 treemap 的 top/bottom safe-area inset，避免 AppKit canvas 在 macOS 混合合成时覆盖 SwiftUI 控件；900×640 下核心控件保持可见。
- 产品边界不变：没有删除、移动、清理建议、AI、网络、内容读取、哈希、签名、公证或发布。

## 2. Codex 独立验收

Pi 完成三轮实现与修正后，Codex 使用全新的 Swift scratch path 与 Xcode DerivedData 独立执行：

```sh
arch -arm64 swift test --scratch-path <new-test-scratch>
arch -arm64 swift build -c release --scratch-path <new-release-scratch>
arch -arm64 swift package show-dependencies --format json
arch -arm64 swift test --sanitize=thread \
  --scratch-path <new-tsan-scratch> \
  --filter 'TreemapNavigationTests|AppModelTests|ScanUpdateBufferTests|TreemapCoordinatorTests|TreemapCanvasTests'
xcodebuild -project App/SpaceJudge.xcodeproj -scheme SpaceJudge \
  -configuration Debug -derivedDataPath <new-debug-derived-data> \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/SpaceJudge.xcodeproj -scheme SpaceJudge \
  -configuration Release -derivedDataPath <new-release-derived-data> \
  build CODE_SIGNING_ALLOWED=NO
plutil -lint App/SpaceJudgeApp/PrivacyInfo.xcprivacy
spacejudge-treemap-bench --json <new-benchmark.json>
```

最终结果：

- 291 tests / 39 suites 全部通过。
- 聚焦的 56 tests / 5 suites 在 Thread Sanitizer 下通过，没有报告 data race。
- Swift Release build、Xcode Debug 和 Xcode Release 均成功。唯一 Xcode 提示是没有 AppIntents 依赖，因此跳过 metadata extraction；它不影响当前产品。
- package dependency 列表为空；Privacy Manifest 通过 `plutil`。
- 临时验收根和数据库都位于 `/tmp`；Debug-only 的根目录与数据库环境变量在 Release 中不可用，没有读写用户正式 SpaceJudge 数据库。

## 3. 独立性能基线

环境：Apple M1 Max（MacBookPro18,2）、arm64、macOS 26.6.2、10 核、64 GB；Release；固定 seed；layout/index/render warmup 5，hit warmup 2,000。

| 场景 | iterations | p50 | p95 | max | 工程门 | 结果 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 10,000 sibling 纯布局 | 100 | 0.836 ms | 1.096 ms | 1.395 ms | p95 < 50 ms | 通过 |
| 2,000 tile hit-index build | 200 | 0.102 ms | 0.106 ms | 0.110 ms | p95 < 10 ms | 通过 |
| point query | 100,000 | 0.125 µs | 0.167 µs | 8.084 µs | 平均 < 20 µs | 0.132 µs，使用同一命中索引，通过 |
| 1,280×800 bitmap render | 60 | 5.786 ms | 6.082 ms | 6.118 ms | p95 < 16.7 ms | 通过 |
| 100 次纯 resize layout | 100 | 0.536 ms | 0.547 ms | 0.621 ms | 记录项 | 通过 |

`/usr/bin/time -l` 的 maximum resident set size 为 27,131,904 bytes；benchmark 自报告峰值为 26,804,224 bytes。resize 数字只代表 composer 的纯布局耗时，不冒充窗口 resize 的端到端帧时间；latest-wins、取消和 task 有界性由 coordinator 测试覆盖。

这些数字是当前机器上的工程回归基线，不是对所有 Mac、卷和冷缓存场景的营销承诺。

## 4. 真实 GUI 验收

验收 fixture 包含 12 个大小明显不同的顶层目录、3 层嵌套，以及一个含 650 个直接文件的宽目录。Codex 实际启动最终 Debug App 并验证：

1. 约 900×640 窗口中，“选择位置、后退、上一级、面包屑、扫描状态、重新扫描、取消、概览/详细”全部可见；treemap 从工具栏下方开始，footer 显示图例和真实卷容量。
2. 单击 `Top12` 后，`big-12.bin` 与 `SubA` 在 expanded scene 到达时立即出现，不需要再切换概览/详细来强制刷新。
3. 双击 `Top10` 进入目录；后退与上一级分别恢复预期 focus，面包屑同步更新。
4. 进入 `Wide/650` 后，canvas 显示 500 个真实项和“其他（150 项）614 KB”；选择“其他”只显示合计摘要，不伪造 NodeID，也没有 Finder/进入操作。
5. 右键 `Top8` 只选择并显示“进入目录 / 展开 / 查看信息 / 在 Finder 中显示”，没有因为右键误触发单击展开；选择摘要仍显示“展开”。
6. 信息面板显示类型、相对路径、有效占用、聚合值、完成状态和修改时间；重新扫描会清除旧选择与旧面板，并重新收敛到完成状态。
7. 大小窗口间 resize 后布局立即收敛，toolbar/footer 不消失，canvas 没有创建 per-tile subview。

浅色 App 级像素验收已完成。dark palette、dark text/selection/empty/other 路径由 renderer 测试覆盖；当前桌面环境没有接受 process-local 的 dark appearance 覆盖，因此真实系统深色截图保留为发布硬化前的人工复验项，不改变本阶段的绘制架构结论。

## 5. Codex 退回与三轮修正

Pi 的首次交付没有直接放行。

### Round 1：渲染、并发与选择语义

- 修复 renderer 早退没有恢复 CGContext 状态。
- scene query 增加完整 stale token、取消和 latest-wins；迟到查询不再覆盖新 focus/scan。
- 统一鼠标与键盘 selection；修复旧/新 tile invalidation、消失 hover/tooltip 和 terminal best-known 文案。
- “其他”成为无 NodeID 的明确 synthetic selection；真实 transaction 异常恢复、空目录 aggregate、overflow、相对路径与 benchmark 口径都补了回归。

### Round 2：在途 mode、右键与 omitted 口径

- detail mode 不再属于数据库查询 token；在途查询完成时使用 live mode 重盖，mode-only 更新只触发重排。
- 右键走 `select`，不再进入延迟单击的展开路径。
- 未知 omitted 数量不再混入一个只有部分已知权重的“其他”tile；未知项只显示“正在统计”。
- tooltip 保存 tile 而不是旧文本，terminal 状态在绘制时实时决定文案。

### Round 3：真实 GUI 阻断项

- 修复“旧 scene + 新 model expansionVersion”先布局后，新 expanded scene 因 key 碰撞被跳过。布局 key 现在取 `scene.scanGeneration` 与 `scene.expansionVersion`。
- 删除不会随 scan 生命周期重置的本地 `revealMessage`；footer 直接显示模型 `revealError`，新 scan/root 会清除它。
- 像素诊断证明 AppKit canvas 覆盖了作为前序 sibling 的 SwiftUI 工具栏；改用 safe-area inset 后，900×640 与宽窗口均恢复可见。

对应回归包括 `staleModelVersionDoesNotSkipNewScene`、`revealErrorClearedOnNewScan`、右键只选择、在途 mode 收敛、tooltip 终态刷新、canvas contract 与 coordinator latest-wins。

## 6. 冻结的 Phase 4 语义

- tile 面积唯一来自有效归属字节；目录不能用 inode 自身字节替代 aggregate。
- focus page 500、expanded page 200、同时展开 8、drawable tile 2,000 是硬上限；不能为了更完整的画面让内存随全盘节点数增长。
- 概览最大深度 2、最小 tile area 64；详细最大深度 3、最小 tile area 24。
- `other(parent:)` 在 parent 内唯一；未知 omitted weight 不画虚假面积，已知权重必须守恒。
- layout key 必须描述已经安装的 scene，而不是可能先行的模型意图；scan、focus、revision、expansion、mode、size 和 scale 变化都必须得到新 key。
- 扫描中显示 best-known 值；terminal refresh 收敛到最终 revision。revision 更新不得无故跳回根或丢失仍有效的 focus、selection、expansion。
- 单击约 230 ms 后展开；双击取消待执行单击并进入；hover tooltip 约 350 ms；右键永远不走单击展开。
- canvas 是一个 accessibility group；原生 toolbar、面包屑、状态、容量和选择摘要承担可访问操作，不创建数千个 accessibility tile。
- Finder 操作只解析当前 scan 的受控相对路径；`.`、`..`、slash、非法 UTF-8、root mismatch 与消失项目不能越界定位。
- DEBUG 根目录/数据库接缝只用于验收；Release 必须忽略。

改变上述语义前应先更新设计、测试与必要 ADR。

## 7. 当前已知边界

- 多个 expanded parent page 在扫描中可能来自相邻 revision；它们是明确的 best-known 视图，terminal refresh 后收敛。
- 信息面板相对路径只使用 scan-local breadcrumb 与当前可达 scene；不可达时显示“—”，不伪造绝对路径。
- 超小的“其他”矩形若在 inset 后不足 1 point 可以不绘制，但其权重仍参与父级布局。
- 当前没有持久化布局缓存、FSEvents、APFS clone/快照独占可释放空间、全盘卷组/firmlink 口径或海量真实系统盘冷缓存基准。
- 仍未执行真实系统深色外观截图、增大字体、VoiceOver 人工走查、签名、公证、Sandbox 与发布验收。
- 当前 Finder 操作只有“显示”，没有移动、删除或清理；AI 和建议仍不在范围内。

## 8. 下一阶段入口

Phase 5 是全盘与发布硬化，不自动加入 AI 或清理能力。开始前应先写独立设计，至少冻结：

1. APFS 卷组、firmlink、clone、压缩、resource fork、云文件和快照的展示口径。
2. Full Disk Access 产品引导、Sandbox/直接分发选择、签名、公证与更新策略。
3. 真实大盘、冷缓存、百万级扫描 + SQLite + UI 联合基准，以及崩溃恢复与数据库迁移。
4. FSEvents 或重新扫描的产品语义，不能把不完整的实时更新冒充最终占用。
5. 深色、增大字体、键盘、VoiceOver、Finder 与权限受限路径的发布级人工验收矩阵。

任何删除、废纸篓、清理建议或 AI 判断都需要新的产品规格和安全 ADR，不属于 Phase 5 的默认授权。
