# 测试、基准与验收

状态：Accepted

## 1. 原则

Pi 的测试结果是实现证据，Codex 必须独立复跑关键命令、审查 diff，并在真实 UI / 文件系统上抽查。构建成功不能代替结果正确，扫描快不能代替 UI 流畅。

## 2. 测试分层

### Domain 单元测试

- 字节值未知、0、最大值和溢出。
- NodeID、ScanID、FileIdentity 等值与编码。
- 目录聚合 completion 顺序不同仍得相同结果。
- hard link 第二次归属为 0。
- issue 聚合与终态不变量。

### 属性解析器测试

- 每种请求属性的正常 record。
- returned bitmap 缺字段。
- 可变名称 offset、空名称、最长名称、多字节 UTF-8。
- record 截断、长度为 0、越界 offset、非对齐字段。
- 条目级 `ATTR_CMN_ERROR`。
- file 与 directory 属性组合。
- 随机字节 fuzz 至少 10,000 轮不崩溃、不越界。

### Treemap 单元测试

- 所有矩形位于父矩形内且不相互重叠。
- 面积误差在浮点容差内与权重成比例。
- 0 权重、单节点、极端长宽比、相同权重、百万级权重值。
- 输入顺序变化后稳定排序结果一致。
- 320 px、736 px、1,024 px、超宽窗口。
- 可见性裁剪与“其他”聚合不丢失总权重。

### 文件系统集成测试

在临时目录构造：

- 多层目录、空目录、隐藏文件、Unicode 名称。
- 符号链接环。
- 两个硬链接。
- 稀疏文件。
- 无权限目录；若当前测试身份无法稳定构造则用协议注入。
- 扫描中删除、重命名和新增文件。
- 深度大于 1,000 的逻辑 fixture，验证无递归栈风险。
- 取消时仍有大量待处理目录。

每次测试后核对临时目录已回收、FD 数量回到容差范围、没有悬挂 Task。

### Store 测试

- 批量写入、事务失败回滚、重开读取。
- running -> completed / cancelled / failed / interrupted。
- 父子查询顺序与索引计划。
- schema 迁移、损坏库错误处理。
- 100 万节点 fixture 的数据库大小、写入时间和查询 p95。

### UI / 交互测试

- 选择目录、开始、取消、完成。
- 扫描中浏览，增量更新不把用户导航弹回根。
- 单击展开、双击进入、后退、上一级、面包屑。
- 概览 / 详细。
- hover、右键、Finder 显示；失效路径有合理提示。
- 权限限制和不可访问汇总。
- 窗口 320、736、1,024、1,440 px；浅色 / 深色；增大字体。
- VoiceOver 至少能访问工具栏、当前路径、选中项摘要和操作；不要求逐个访问所有细小 tile。

## 3. 正确性对照

同一静态 fixture 运行：

1. ReferenceEnumerator。
2. DarwinBulkEnumerator。
3. `du` / `stat` 作为外部辅助，不直接假定口径一致。

比较规范化树：相对路径、类型、logical、allocated、hard-link attribution。差异必须分类解释，不能用误差百分比掩盖系统性漏扫。

## 4. 性能基准

报告必须包含：日期、commit、构建模式、机器型号、芯片架构、macOS、卷类型、冷 / 热缓存说明、fixture 生成方法。

基准矩阵：

- 宽目录：单层 10 万条目。
- 深目录：多层 10 万条目。
- 混合树：10 万、50 万、100 万节点。
- 小文件密集与大文件稀疏两类。
- 扫描 + SQLite；扫描不落库；布局；绘制分别测量。

记录：

- 首批结果延迟。
- 总 entries/s 与 p50 / p95。
- wall time、CPU time、峰值 RSS。
- 系统调用次数（可获取时）。
- SQLite 大小与写入吞吐。
- UI snapshot 频率、布局 p95、draw p95。
- 取消延迟和扫描后 FD 差值。

## 5. 阶段性能门

这些是工程门，不是对所有设备的保证：

- Debug 单元测试全部通过，Release 基准不崩溃。
- 混合 10 万节点：首批事件目标 < 500 ms，总扫描目标 < 2 s（本机 SSD、热缓存）。
- 100 万节点：峰值 RSS 目标 < 250 MB。
- 当前层级 10,000 tile 输入：布局 p95 < 50 ms；裁剪后绘制 p95 < 16.7 ms。
- UI 事件发布 <= 10 Hz。
- 取消后 200 ms 内停止普通事件，2 s 内结束 worker。

若未达标，报告真实数字和瓶颈；不得降低测试规模或静默修改口径来“通过”。

## 6. 每阶段验收清单

### Codex 静态审查

- 模块依赖方向正确。
- public API 与设计语义一致。
- 无主线程 I/O、无无界 Task、无重复完整路径。
- 所有 FD / buffer / SQLite statement 有确定生命周期。
- 错误未被空 catch 吞掉。
- 日志隐私标注正确。

### Codex 动态验收

- 独立运行 `swift test` / `xcodebuild test`，记录真实退出码。
- 至少一个真实临时目录扫描。
- 至少一个错误路径和取消路径。
- UI 阶段用实际应用操作与截图验证。
- 对性能变更重跑受影响基准并与前一基线比较。

### 交付证据

- Pi 简短报告。
- 测试与基准原始输出路径。
- 关键截图或 JSON 报告。
- 已知限制。
- 当前没有后台服务；若有，记录 PID、目录、端口和精确停止方法。

## 7. Phase 5B 启动盘可见卷组验收

除既有各层测试外，Phase 5B 必须额外覆盖：

- Domain/Store：`visibleStartupVolumeGroup` 的 Codable 与 `CaseIterable` 顺序；schema 编码 `0/1/2` 与未知值失败；`firmlinkProjection` bit 与旧 bits 不冲突且 SQLite round-trip 保留；plan/evidence 的 unknown / false / true 不混淆。
- Parser：`SF_FIRMLINK` 存在/缺失/未返回；mount 与 firmlink 同时为真；FLAGS 之后 FILEID/PARENTID offset 不变；fallback copy 保留 `isFirmlink`；既有 10,000 轮 fuzz 不回归。
- 边界策略矩阵：三种 policy ×（同设备普通目录、device 已知/未知排列、firmlink、mount、mount+firmlink、firmlink 后仅允许所需一次转换）。
- 合成扫描树：firmlink 投影只扫描一次；raw Data mount、VM、External 可见为边界但不枚举；终态聚合、计数、取消与 spool 序列正确。
- Planner/AppModel：可注入 facts，不依赖真实机器卷拓扑；APFS + volume root + root filesystem 才选择 visible group，其余与查询抛错降级；beginScan 使用 plan policy；picker 取消、rescan 复用、新 selection 覆盖、shutdown 清理 plan；不保存或输出绝对路径。
- CLI smoke：`spacejudge-volume-plan` 对 `/` 输出可解析 JSON 且当前受支持系统上为 visible group、firmlink count > 0；普通临时目录为 selected filesystem 且计数为 0；不存在路径/非目录退出 3；stdout/stderr 不含输入路径或用户名；`--help` 退出 0；参数错误退出 2。

性能与资源门（Release，本机 SSD，缓存状态未控制）：

- 10 万 mixed 完整扫描 + SQLite 总耗时相对 Phase 5A 回归不超过 10%。
- 100 万 mixed 峰值 RSS < 250 MB。
- root immediate probe < 500 ms（记录真实值，不在程序内硬失败）。
- 取消 200 ms 内停止普通事件、2 s 内 terminal；FD delta 不随规模或 firmlink/mount 数增长。
- `selectedFileSystem` 普通目录结果与 Phase 5A 节点/聚合计数一致。

## 8. Phase 5C 快照缓存自保护验收

除既有各层测试外，Phase 5C 必须额外覆盖：

- Workspace：启动仅删除白名单三件套与合法 spool；相邻普通文件、子目录、符号链接、名称近似文件不被删除；清理幂等；删除失败/未知成员明确失败；Debug override 不删父目录；目录权限 `0700`。
- Store：第二次 `begin` 后只剩新 `ScanID`，四张子表旧行级联消失；取消/失败在下一次 `begin` 前仍可查询；被拒绝的 `begin` 保留旧快照且不留下伪 running 行；新库 `auto_vacuum=INCREMENTAL`；不执行全量 `VACUUM`；开始门 512 MiB 与运行门 256 MiB 的下/等于/上边界；unknown、复用页、乘加溢出和 `SQLITE_FULL`/`SQLITE_IOERR` 分类；低空间失败后无伪 commit、scan 仍为 running 并可 `fail`；连续两次同规模扫描 `scan_count == 1` 且主库不呈近似 2 倍线性增长。
- Scanner/App：工作区位于 fixture 深处时节点存在、带 `snapshotStorageBoundary`、direct children 为 0；同名不同路径目录不误排除；identity 缺失时精确路径 fallback；根等于/位于工作区时在 `.started` 前失败；超过排除数量上限失败；强制 spool 时文件位于配置的工作区目录并在完成/取消/失败后删除；两个新错误文案无路径且 rescan 可恢复。
- 取消一致性：engine 接受 `cancel` 但不发布 terminal、consumer 被强制取消时，runner 写入 `finish(.cancelled)` 且不调用 `fail`；该末态必须先持久化成功才发布/返回，持久化失败时 runner 抛出错误、不发布 cancelled terminal 并 best-effort `fail`；普通 store/stream 错误仍 failed；`AppModel` 可注入短宽限期验证强制取消后 phase/summary 为 cancelled 且 `userError == nil`。
- UI 错误可见性：`AppUserError` 映射的文案通过 `AppModel.userError` 暴露，并在 ContentView footer 以 `accessibilityIdentifier = scan-error` 的一行可截断文本展示；真实 `/` 强制取消后不残留 scan-error。
- 真实 App：Debug `/` smoke 中查询工作区边界 direct children 为 0，且数据库中没有 sqlite/wal/shm/spool 子节点；任务 PID 按精确 PID 停止。

性能与资源门（Release，本机 SSD，缓存状态未控制）：

- 10 万与 100 万 mixed 端到端基准继续满足既有门；100 万峰值 RSS < 250,000,000 B；排除集合不得增加每节点常驻字段。
- 连续两次同规模扫描后 `scan_count == 1` 且主库不线性翻倍。
- 取消延迟与 FD 门不回归；Store/runner/AppModel/scan exclusion 关键组通过 Thread Sanitizer。

## 9. Phase 5D-A 发布工程就绪验收

Phase 5D-A 只验收不需要发布凭据的部分；正式签名、公证、staple 与 Gatekeeper 属性仍属于 5D-B。

### 9.1 配置与资源

- Release target `ENABLE_HARDENED_RUNTIME = YES`，Debug 保持现状；`ENABLE_APP_SANDBOX = NO` 不变；不添加 runtime exception entitlement。
- `AppIcon.appiconset` 的 16/32/128/256/512 1x/2x 槽位完整，`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`，Xcode 构建无缺图或未分配子项警告；生成器 `scripts/assets/generate-app-icon.swift` 可重复产出，不下载素材。
- Info.plist 含 Desktop/Documents/Downloads/removable/network volume 五个 usage description 的英文 fallback；`en.lproj` 与 `zh-Hans.lproj` 的 `InfoPlist.strings` 提供本地化，语义统一为只读元数据、不读内容、不修改/删除、不上传。
- Xcode Debug/Release 在 `CODE_SIGNING_ALLOWED=NO` 下构建成功；Release `-showBuildSettings` 显示 Hardened Runtime YES。

### 9.2 脚本 fail-closed 自测

`bash scripts/release/test-release-scripts.sh` 必须全绿（本轮 108 项），覆盖：

- 相对/非空输出目录拒绝，且不覆盖既有产物；
- marketing version 必须是 `N.N.N` 数字语义、build 必须是正整数、bundle ID/min OS 字符集安全且无 `/`、`..` 或控制字符；非法值在任何路径拼接前拒绝；
- 无 Git HEAD、dirty 工作树拒绝；
- Apple Distribution / Apple Development / 未知身份拒绝，只有 Developer ID Application 通过；同名 label 多匹配拒绝；Team ID 必须回到父 shell；
- notary status 非 `Accepted` 拒绝；notarization log 缺失/空/非 JSON/非 Accepted/含 error issue 拒绝，warning 计数但不阻断；staple、`spctl` 非零退出拒绝；
- get-task-allow 或任何非空 entitlement 拒绝，空 entitlements 通过；
- `lipo` 架构必须精确为排序后的 `arm64 x86_64`，单一或额外架构拒绝；未知 nested Mach-O 拒绝，仅主 executable 通过；
- version/build/bundle ID/min OS 在源 Info.plist、pbxproj 与 built bundle 之间不一致时拒绝；
- DMG 根只允许真实 App 目录与精确指向 `/Applications` 的 symlink，其他（含隐藏）条目、App symlink 或错误 symlink 目标均拒绝；
- `.sha256` 必须存在且 hash 与文件名都绑定 DMG；manifest 的 sha256/version/build/bundle ID/min OS/architectures 必须绑定挂载后的 App，local 必须 `local-adhoc`/false/not-submitted，release 必须 `developer-id`/true/Accepted/非空 submission ID/40-hex commit/非空 team；
- 官方 `distribute.sh` 与 `verify-artifact.sh` 拒绝所有 `SJ_*_BIN` 测试工具替换；`local-candidate.sh` 不引用 `notarytool`；所有脚本 `bash -n` 通过且无 `eval`、无 `rm -rf`、无明文密码参数、不通过命令替换调用有副作用的 temp helper；
- temp helper 必须在父 shell 设置全局并在 cleanup 时回收；
- 三个面向使用者的入口在启动时把 `PATH` 固定为 `/usr/bin:/bin:/usr/sbin:/sbin`，在恶意前置 `plutil`/`xcrun`/`notarytool`/`ditto`/`security`/`git` 等替身时只使用系统工具、替身零执行痕迹，且真实门禁/验证行为不变。

### 9.3 本地候选与真实 App

- `local-candidate.sh` 真实产出 universal2 ad-hoc Hardened Runtime DMG，名称与 manifest 都标注 `LOCAL-ADHOC-NOT-FOR-DISTRIBUTION` / `distributionReady=false`，不调用 Apple 服务；成功后不留下任务 temp，失败时也能回收任务 temp。
- `lipo -archs` 精确覆盖 `arm64 x86_64`；`codesign` flag 含 runtime；effective entitlements 为空；bundle 内含 `PrivacyInfo.xcprivacy`、`AppIcon.icns` 与两个 lproj；DMG 根只有 App 与 `Applications -> /Applications`。
- `verify-artifact.sh` 必须要求 manifest 与 `.sha256`，并证明错误/过期 manifest 不能与 DMG 搭配通过。
- local hardened App 真实启动并在 fixture 上完成一次扫描；在同一 hardened 构建上对真实 `/` 完成一次 UI 取消（status 转 `cancelled`，界面显示已取消），随后按精确 PID 停止且无残留进程。
- 官方 `distribute.sh --release --preflight-only` 在无 Developer ID 且无 HEAD 的机器上明确失败并列出阻断原因，不发生任何网络上传（含不调用 `notarytool history`）；带 `SJ_*_BIN` 的调用在本地门之前就被拒绝。

### 9.4 5D-B 待凭据项

Developer ID 签名链、notarization Accepted、staple、Gatekeeper、浏览器 quarantine、离线打开、Intel/Apple Silicon 实机矩阵与覆盖安装仍必须等 Developer ID Application、Keychain notary profile 和干净 commit 到位后由 5D-B 验收。
