# Phase 3 验收基线

状态：Accepted

验收日期：2026-09-26

## 1. 交付结果

Phase 3 已把前两阶段的扫描与持久化内核接入一份可真实运行的 macOS 原生应用：

- 新增 `App/SpaceJudge.xcodeproj`、共享 scheme 与 SwiftUI App target；核心仍由本地 Swift Package 提供，没有第三方 package。
- 启动时不自动扫描。用户通过系统目录选择面板选择文件夹或磁盘后，本次进程获得访问范围并自动开始扫描；不保存绝对路径、安全作用域 bookmark 或下次启动的自动恢复信息。
- `FoundationVolumeFactsProvider` 在扫描开始时读取一次卷容量事实；同一份不可变 `VolumeFacts` 同时进入 metadata、terminal summary、SQLite 与 UI。
- `PersistingScanRunner` 在持久化成功后才发布应用层更新；进度和已提交 revision 合并到不超过 10 Hz，terminal、fatal error 与 cancel 立即处理。
- 应用保持一个可写 SQLite repository，并用独立只读 connection 查询已提交快照；UI 不接收节点 batch，也不在主线程执行扫描或 SQLite I/O。
- Phase 3 界面显示当前根、总容量/已用/剩余、状态、统计和按有效占用降序排列的最多 100 个直接子项。最终 treemap 仍属于 Phase 4。
- 应用退出会取消并等待活动扫描、释放访问范围、关闭读写 repository，再完成进程终止。
- `PrivacyInfo.xcprivacy` 声明 Disk Space（`85F4.1`）和 File Timestamp（`3B52.1`）required-reason API；实现没有网络请求、删除接口或 AI。

## 2. Codex 独立验收

Pi 完成实现和自测后，Codex 不复用 Pi 的结论，实际运行：

```sh
arch -arm64 swift test
arch -arm64 swift build -c release
arch -arm64 swift package show-dependencies --format json
arch -arm64 swift test --sanitize=thread --filter ScanUpdateBufferTests
arch -arm64 swift test --sanitize=thread --filter AppModelTests
xcodebuild -project App/SpaceJudge.xcodeproj -scheme SpaceJudge \
  -configuration Debug -derivedDataPath <new-debug-derived-data> \
  build CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/SpaceJudge.xcodeproj -scheme SpaceJudge \
  -configuration Release -derivedDataPath <new-release-derived-data> \
  build CODE_SIGNING_ALLOWED=NO
plutil -lint App/SpaceJudgeApp/PrivacyInfo.xcprivacy
```

最终结果：

- 214 tests / 29 suites 全部通过；Release Swift build 通过。
- `ScanUpdateBufferTests` 5 项与 `AppModelTests` 15 项在 Thread Sanitizer 下通过，没有报告 data race。
- 使用全新 DerivedData 的 Xcode Debug、Release 构建均成功。唯一提示是未依赖 AppIntents，因此跳过 AppIntents metadata extraction；它不是 Swift/Clang 编译错误，也不影响产物。
- package dependency 列表为空；应用只使用系统框架与系统 SQLite3。
- Privacy Manifest 通过 `plutil` 语法检查，并被复制到 Debug/Release App bundle。
- Codex 通过原生 macOS UI 实际启动最终 Debug App，选择一个包含 3 MiB、2 MiB、1 MiB 已分配文件的 fixture。界面依次显示 `Developer 3.1 MB`、`Downloads 2.1 MB`、`Photos 1 MB`，证明目录使用聚合后的有效占用而不是目录 inode 自身的 0 bytes。
- 同一实例重新扫描成功，容量小字显示真实卷数据；退出后没有 SpaceJudge 进程，SQLite 中两次扫描均为 completed，running 数量为 0，测试目录没有遗留扫描 spool。

测试数据库通过 Debug-only 的绝对 `.sqlite` 环境变量接缝注入；Release 构建忽略该变量，因此验收没有读写用户真实的 Application Support 数据库。

## 3. Codex 退回与修正

Pi 首次交付没有直接放行。Codex 的真实 App 与 SQLite 对照检查发现：目录节点本身的 `nodes.attributed_bytes` 为 0，但其子树占用保存在 `directory_aggregates`，因此“最大项目”把真实占用目录显示为 `Zero KB`。同轮还发现 0-byte 文案依赖系统 locale，以及即时唤醒 callback 安装/清除存在未同步读写。

Round 1 修正：

1. `SnapshotChildItem` 新增 `effectiveAttributedBytes`；目录优先取 partial/complete aggregate，没有 aggregate 才回退 node 值。
2. child query 使用 `nodes_by_parent` 过滤直接子项、LEFT JOIN aggregate，并按有效占用降序与 NodeID 升序确定性排序；UI 与 accessibility 使用同一个有效值。
3. 真实 0 固定格式化为 `0 B`，unknown 仍为 `—`，不再出现 locale 相关的 `Zero KB`。
4. `ScanUpdateBuffer` 对 callback 的安装、清除与捕获使用同一把锁，回调只在锁外执行；增加并发压力测试。

第二轮状态机 review 又发现：失败状态下打开 picker 再取消，会被错误改成 ready；picker 挂起期间也可以重入第二次 `chooseRoot()`。

Round 2 修正：

1. picker 取消精确恢复进入 picker 前的稳定 phase，包括原 `.failed` 错误和原 `.completed` summary。
2. `isChoosingRoot` 在任何 `await` 前同步置位，第二次选择请求成为 no-op；对应工具栏与菜单在面板打开时禁用。
3. 协议文档明确 child page 按 `effectiveAttributedBytes` 排序：返回结果与内存受 limit 限制，但为了正确排序可能检查全部直接子项，不能宣称常数查询时间。
4. 增加失败后取消、完成后取消、picker 重入三个回归测试。

## 4. 冻结的 Phase 3 语义

- 应用启动不扫描；只有明确的用户选择才开始扫描。
- Phase 3 是直接分发、session-only access 模型。选择 URL 只在当前进程存活，不持久化 bookmark、绝对路径或访问权；以后若改为持久访问、App Sandbox 或 Mac App Store，必须新增 ADR。
- 同一次扫描只能采集一次 `VolumeFacts`。metadata、summary、store 与 UI 不得各自重新读取而产生口径漂移。
- unknown 容量显示 `—`，真实 0 显示 `0 B`；`used = total - available` 只在两个输入都已知且合法时计算。
- 应用只有一个 writer；UI 查询使用单独的 read-only repository。未提交内容不可见，提交 revision 后才允许刷新。
- 目录在列表/后续 treemap 中的权重是 `effectiveAttributedBytes`，即优先使用 `directory_aggregates.attributed_bytes`；不能用目录 inode 的 node bytes 代替子树占用。
- child page 最多 100 项（repository 合法范围 1...500），按有效占用降序、NodeID 升序；名称来自 scan-local name table。
- progress/commit 刷新不超过 10 Hz；terminal、fatal error、permission-limited 与 cancel 不等待下一次节流 tick。
- 一个时刻最多一个 active scan。替换 root、重扫和退出必须 cancel-and-wait，随后释放旧访问范围并清理 repository。
- 只有根目录的 `EACCES`/`EPERM` 可映射为 permission-limited 证据；其他 fatal error 进入 failed。用户可见错误不得泄露绝对路径。
- Phase 3 不提供删除、移动、清理建议、AI、网络、Finder 操作或最终 treemap。

## 5. 权限与隐私依据

实现和 ADR 以 Apple 官方文档为依据：

- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [NSPrivacyAccessedAPITypes](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [NSPrivacyAccessedAPITypeReasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons)
- [TN3183: Adding required reason API entries to your privacy manifest](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)

当前 Privacy Manifest 是对现有 API 使用的声明，不等于应用已经完成签名、公证、Sandbox 或上架合规验收。

## 6. 当前已知边界

- Phase 3 的“最大项目”只是端到端诊断列表，不是用户最终要用的 SpaceSniffer 风格空间图。
- child query 的结果与返回内存由 limit 限制，但按 aggregate 权重排序可能检查某个目录的全部直接子项；超宽目录需要 Phase 4/5 的实盘查询基准与必要索引策略。
- Phase 2 已知的 coordinator 未完成目录 bookkeeping 仍可能随未完成目录数增长；尚未完成 scanner + SQLite 的真实百万文件联合基准。
- 仍未完成 APFS clone、压缩、resource fork、firmlink、卷组、全盘权限与冷缓存口径冻结。
- 当前未执行签名、公证、Sandbox、Full Disk Access 产品引导或 Mac App Store 硬化。
- Xcode 的 AppIntents metadata skipped 提示已记录；当前产品没有 AppIntents 功能，不为消除提示而引入无用依赖。
- 取消、重扫与退出已通过小型真实 fixture 和单元测试；长时间/海量真实目录的取消延迟与 UI 流畅度仍需 Phase 4/5 记录。

## 7. 下一阶段入口

Phase 4 只接高性能 treemap，不改变本文件冻结的扫描、持久化、容量和权限语义。开始实施前应先写单独设计与 Pi 任务单，至少明确：

1. AppKit `NSView` + Core Graphics 单绘制面的数据快照、布局缓存和线程边界。
2. `effectiveAttributedBytes` 到矩形面积的唯一权重链路；partial aggregate 更新时如何增量失效。
3. 可见节点裁剪、最小像素阈值、命中索引、hover、单击展开、双击进入和面包屑。
4. 深浅色、900×640 / 1,280×800、增大字体、键盘和 VoiceOver 的行为。
5. 真实扫描期间首屏延迟、布局耗时、绘制帧时间、峰值 RSS 与查询 p95 的验收阈值。
6. 保留现有最大项目列表作为 Debug/诊断能力，不把它冒充最终产品界面。

任何改变本基线冻结语义的实现，先更新 ADR 与回归测试，再交给 Pi。
