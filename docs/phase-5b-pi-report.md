# Phase 5B Pi 交付报告：启动盘可见卷组与边界安全

状态：完成

日期：2026-09-27

## 1. 已实现

按 `docs/18-phase-5b-design.md` 与 `docs/adr/0008-visible-startup-volume-group.md` 实现，未改变设计方向，未触碰禁止范围。

### 1.1 领域与边界策略

- `BoundaryPolicy` 末尾追加 `visibleStartupVolumeGroup`，旧 `selectedTree`/`stayOnRootFileSystem` 语义不变；`Sources/SpaceJudgeDomain/ScanModel.swift`。
- 新值 `VolumeScanPlanKind`、`VolumeScanPlanEvidence`、`VolumeScanPlan`（不可变、`Sendable`、`Equatable`、`Codable`，`makeScanRequest` 复用既有 `ScanRequest`）；`Sources/SpaceJudgeDomain/VolumeScanPlan.swift`。
- `NodeFlags.firmlinkProjection = 1 << 9`；`Sources/SpaceJudgeDomain/NodeModel.swift`。
- 边界判定下沉为纯函数 `DirectoryBoundaryPolicy.decide(...)`，输出 `DirectoryTraversalDecision` 与内部 `BoundaryReason`（mount vs unexpected device transition）；`Sources/SpaceJudgeScan/DirectoryBoundaryPolicy.swift`。优先级：mount > firmlink > 授权的一次投影转换 > 设备不一致 > 未知/普通。

### 1.2 枚举事实

- parser 保留 `ATTR_CMN_FLAGS & SF_FIRMLINK`（`0x00800000`）为 `RawDirectoryEntry.isFirmlink`，仅当 returned bitmap 声明 FLAGS 时读取；FLAGS 槽位照常消费，FILEID/PARENTID offset 不变；`Sources/SpaceJudgeScan/DarwinAttributeBufferParser.swift`、`DirectoryEnumerator.swift`。
- `DarwinBulkEnumerator.markingFallback` 复制路径保留 `isFirmlink`；`Sources/SpaceJudgeScan/DarwinBulkEnumerator.swift`。
- 扫描器把 firmlink 标记为 `firmlinkProjection`，并给工作项携带 `enteredThroughFirmlink`，只授权该投影的直接子项落在 Data 卷上，不向孙代继承；投影内未知 device 不会继承旧卷 device，因此不会错误截断更深的数据卷目录，也不会变成全局跨设备开关；`Sources/SpaceJudgeScan/FileSystemScanEngine.swift`。
- `DirectorySpool` 编码新增 `enteredThroughFirmlink`，spool 往返不丢失授权事实；`Sources/SpaceJudgeScan/DirectorySpool.swift`。

### 1.3 计划解析与 App 接线

- 可注入协议 `VolumeScanPlanning`、`VolumePlanFactsProviding`、纯 `VolumeScanPlanResolver` 与生产 `FoundationVolumeScanPlanner`（只读 `isVolumeKey`、`volumeIsRootFileSystemKey`、`volumeTypeNameKey`、`volumeIsLocalKey`）；`Sources/SpaceJudgeAppSupport/VolumeScanPlanning.swift`。
- 仅“volume root + root filesystem + APFS（大小写不敏感）”为 visible group，其余（含任一未知、查询抛错、非 APFS、外部卷、普通目录）降级为 `selectedFileSystem + stayOnRootFileSystem`。
- `AppModel` 注入 planner，adopt 时解析一次 plan，beginScan 用 plan 构造 `ScanRequest`；rescan 复用 plan；picker 取消保留旧 plan；新 selection 覆盖；reset/shutdown 清理 plan；`Sources/SpaceJudgeAppSupport/AppModel.swift`、`App/SpaceJudgeApp/AppDelegate.swift`。Debug `SPACEJUDGE_TEST_ROOT_PATH` 走同一 planner。

### 1.4 Store

- `SchemaEncoding` 写入边界策略 `visibleStartupVolumeGroup = 2`，decode 接受 0/1/2，未知值仍抛错；schema 版本不变；`Sources/SpaceJudgeStore/SQLiteSchema.swift`。

### 1.5 诊断 CLI

- 新增 SwiftPM executable `spacejudge-volume-plan`，逻辑在可测试的 `SpaceJudgeVolumePlanKit`：`--root PATH`（默认 `/`），用生产 `DarwinBulkEnumerator` 与 parser 只枚举 root 立即子项，输出唯一 JSON；`Sources/SpaceJudgeVolumePlanKit/VolumePlanCommand.swift`、`Sources/SpaceJudgeVolumePlan/main.swift`、`Package.swift`。
- 退出码：0 成功/安全降级，2 参数，3 root 不可读，4 JSON 编码失败。stdout/stderr 不含输入路径、用户名、卷 UUID、BSD disk 名、mount-from 或条目名。
- 参数错误文案固定且脱敏：未知 flag → `unknown option`，未知 positional → `unexpected argument`，均不回显参数值；`--root` 缺值 → `--root requires a value`。

## 2. 验证

所有命令使用任务专属目录 `/tmp/spacejudge-phase5b-pi/`（marker 见下），不复用 Phase 5A 构建目录。原始日志见第 3 节。

| # | 命令 | 退出码 | 结果 / 关键数字 |
| --- | --- | ---: | --- |
| 1 | `arch -arm64 swift test --scratch-path /tmp/spacejudge-phase5b-pi/scratch` | 0 | **377 tests / 53 suites 通过**（0 warning） |
| 2 | `arch -arm64 swift build -c release --scratch-path /tmp/spacejudge-phase5b-pi/scratch-release` | 0 | Build complete，**0 warning** |
| 3 | `arch -arm64 swift test --sanitize=thread --scratch-path /tmp/spacejudge-phase5b-pi/scratch-tsan --filter 'AppModelTests\|ScanEngineTests\|PersistingScanRunnerTests'` | 0 | **37 tests / 3 suites**，无 data race 报告 |
| 4 | `<release>/spacejudge-volume-plan --root /` | 0 | `planKind=visibleStartupVolumeGroup`、`firmlink=7`、`mountPoint=1`、`rootEntryCount=21`、`rootDeviceKnown=true`；直接 wall 5 次 28–33 ms（< 500 ms） |
| 5 | `<release>/spacejudge-volume-plan --root <fresh-empty-dir>` | 0 | `planKind=selectedFileSystem`、`isVolume=false`、四项计数=0，wall 0.01 s |
| 6 | `<release>/spacejudge-e2e-bench --nodes 100000 --shape mixed` | 0 | scan+persist **0.678953 s**（Phase 5A 0.710 s，−4.4%），RSS **60,555,264 B**，fdDelta 0，100000 精确一致 |
| 7 | `<release>/spacejudge-e2e-bench --nodes 1000000 --shape mixed` | 0 | scan+persist **13.911135 s**（Phase 5A 15.203 s，−8.5%），峰值 RSS **239,337,472 B**（≈239.3 MB / 228.3 MiB）< 250 MB，fdDelta 0，1000000 精确一致 |
| 8 | `<release>/spacejudge-e2e-bench --nodes 100000 --shape mixed --cancel-after-first-commit` | 0 | status cancelled，persisted 6000，cancelLatency **20.62 ms**（<200 ms），updatesAfterCancelRequest 5，fdDelta 0 |
| 9 | `<release>/spacejudge-scan-smoke --engine bulk --timeout 2 /` | 130 | 真实 root 短时取消 smoke：status cancelled，files 229701 / dirs 50793，无持久化、无大型产物 |
| 10 | `xcodebuild ... Debug ... -derivedDataPath /tmp/spacejudge-phase5b-pi/derived-debug CODE_SIGNING_ALLOWED=NO build` | 0 | BUILD SUCCEEDED（仅既有 AppIntents metadata 提示） |
| 11 | `xcodebuild ... Release ... -derivedDataPath /tmp/spacejudge-phase5b-pi/derived-release CODE_SIGNING_ALLOWED=NO build` | 0 | BUILD SUCCEEDED（仅既有 AppIntents metadata 提示） |

### 2.1 新增自动化测试覆盖

- CLI 参数隐私回归：`Tests/SpaceJudgeVolumePlanTests/VolumePlanCommandTests.swift` 新增 `unknownPositionalPathNotEchoed`——未知 positional 私密路径退出 2，stdout 为空，stderr 不含完整路径、路径组件或用户名；`helpAndArgumentErrors` 同时断言未知 flag 不回显。复现与修复后输出见 `/tmp/spacejudge-phase5b-pi/logs/repro-unknown-positional.out` / `.err`。

- Domain：`Tests/SpaceJudgeDomainTests/VolumeScanPlanTests.swift`（policy Codable/CaseIterable、新 flag bit、evidence unknown/false/true、plan → request）。
- Store：`Tests/SpaceJudgeStoreTests/SchemaEncodingTests.swift`（0/1/2、未知值失败、firmlink flag SQLite round-trip、visible policy 持久化）。
- Parser：`Tests/SpaceJudgeScanTests/FirmlinkParserTests.swift`（FLAGS 有/无/未返回、mount+firmlink、offset 不变、fallback copy 保留）。
- 边界矩阵：`Tests/SpaceJudgeScanTests/DirectoryBoundaryPolicyTests.swift`。
- 合成卷组：`Tests/SpaceJudgeScanTests/VisibleVolumeGroupScanTests.swift`（firmlink 只扫一次、Data/VM/External 可见不枚举、取消、未知子设备不错误截断、默认策略截断投影）。
- spool 不变量：`Tests/SpaceJudgeScanTests/DirectorySpoolTests.swift` 断言 `enteredThroughFirmlink` 经 spool round-trip 保留。
- Planner/AppModel：`Tests/SpaceJudgeAppSupportTests/VolumeScanPlanningTests.swift`。
- CLI smoke：`Tests/SpaceJudgeVolumePlanTests/VolumePlanCommandTests.swift`（`/`、普通目录、错误码、隐私、null evidence）。

## 3. 证据（绝对路径）

- scratch：`/tmp/spacejudge-phase5b-pi/scratch`、`.../scratch-release`、`.../scratch-tsan`
- DerivedData：`/tmp/spacejudge-phase5b-pi/derived-debug`、`.../derived-release`
- Marker：`/tmp/spacejudge-phase5b-pi/MARKER.txt`
- 日志：
  - `/tmp/spacejudge-phase5b-pi/logs/swift-test.log`
  - `/tmp/spacejudge-phase5b-pi/logs/swift-test-volumeplan-cli.log`
  - `/tmp/spacejudge-phase5b-pi/logs/repro-unknown-positional.out` / `.err`
  - `/tmp/spacejudge-phase5b-pi/logs/swift-build-release.log`
  - `/tmp/spacejudge-phase5b-pi/logs/tsan.log`
  - `/tmp/spacejudge-phase5b-pi/logs/volume-plan-probe.log`
  - `/tmp/spacejudge-phase5b-pi/logs/e2e-100k.json` + `.err`
  - `/tmp/spacejudge-phase5b-pi/logs/e2e-1m.json` + `.err`
  - `/tmp/spacejudge-phase5b-pi/logs/e2e-100k-cancel.json` + `.err`
  - `/tmp/spacejudge-phase5b-pi/logs/scan-smoke-root.json` + `.err`
  - `/tmp/spacejudge-phase5b-pi/logs/xcode-debug.log`
  - `/tmp/spacejudge-phase5b-pi/logs/xcode-release.log`

环境：MacBookPro18,2、Apple M1 Max、arm64、macOS 26.6.2 (25G83)、10 核、64 GB、Swift 6.3.3、Xcode 26.6；Release 构建；缓存状态未控制。

## 4. 限制与风险

- 未对真实 `/` 做递归 visible-group 全盘扫描：遵守任务单只运行了非递归 `spacejudge-volume-plan` probe 与显式短时取消的真实 root smoke（默认策略）。visible-group 的 mount 截断与 firmlink 投影由合成卷组测试覆盖。
- `ReferenceEnumerator` fallback 无法读取 `SF_FIRMLINK`；当某目录无法使用 bulk fast path 时，firmlink 被报告为普通目录并在设备不一致时截断，属 fail-closed，但会漏扫该投影（已文档化）。
- `enteredThroughFirmlink` 授权 firmlink 的**全部**直接子项落在投影卷上（而非仅第一个不匹配者）；更深层的越界仍被截断。与设计“沿刚识别的 firmlink 授权一次”一致。
- 计划解析目前在 MainActor 同步执行 `resourceValues`；设计允许后续按基准再迁移到短生命周期后台任务。CLI probe 的直接 wall 28–33 ms 已包含该解析，未观察到阻塞。
- 100 万 RSS 余量仍小（239.3 MB / 250 MB 门）；Phase 5A 记录为 238.8 MB，本次数字在其噪声范围内，十进制/MiB 口径已在第 2 节标注。
- root immediate probe 直接 wall time 5 次为 28–33 ms（< 500 ms 门）；`/usr/bin/time` 报出的 0.49–0.71 s 主要来自该工具自身的 fork/exec/dyld 开销，不是枚举耗时。
- `/` 的 `mountPointEntryCount=1`、firmlink=7 为本机事实，不进入产品逻辑；产品不硬编码任何设备号/卷名。
- 未运行 `xcodebuild test`（任务单未要求）；App 构建通过。

## 5. 服务

无。交付时无本任务的 App、CLI、测试或 `xcodebuild` 子进程残留（仅 Pi harness 与 ChatGPT kernel 进程在运行，均非本任务启动）。`/tmp/spacejudge-e2e-*` 数量为 0。

## 6. Git

- 分支 `master`，**未 commit、未 push、未签名、未公证、未发布**。
- 修改（全部为既有未提交文件的增量，未删除任何用户成果）：
  - `Package.swift`
  - `Sources/SpaceJudgeDomain/ScanModel.swift`、`NodeModel.swift`、新增 `VolumeScanPlan.swift`
  - `Sources/SpaceJudgeScan/DirectoryEnumerator.swift`、`DarwinAttributeBufferParser.swift`、`DarwinBulkEnumerator.swift`、`FileSystemScanEngine.swift`、新增 `DirectoryBoundaryPolicy.swift`
  - `Sources/SpaceJudgeStore/SQLiteSchema.swift`
  - `Sources/SpaceJudgeAppSupport/AppModel.swift`、新增 `VolumeScanPlanning.swift`
  - 新增 `Sources/SpaceJudgeVolumePlanKit/VolumePlanCommand.swift`、`Sources/SpaceJudgeVolumePlan/main.swift`
  - `App/SpaceJudgeApp/AppDelegate.swift`
  - 新增 `Tests/SpaceJudgeDomainTests/VolumeScanPlanTests.swift`、`Tests/SpaceJudgeStoreTests/SchemaEncodingTests.swift`、`Tests/SpaceJudgeScanTests/FirmlinkParserTests.swift`、`Tests/SpaceJudgeScanTests/DirectoryBoundaryPolicyTests.swift`、`Tests/SpaceJudgeScanTests/VisibleVolumeGroupScanTests.swift`、`Tests/SpaceJudgeAppSupportTests/VolumeScanPlanningTests.swift`、`Tests/SpaceJudgeVolumePlanTests/VolumePlanCommandTests.swift`；`Tests/SpaceJudgeAppSupportTests/TestSupport.swift`
  - `docs/02-system-architecture.md`、`docs/03-scan-engine.md`、`docs/04-data-and-storage.md`、`docs/05-testing-and-acceptance.md`、`docs/references.md`、本报告
- 未修改 `docs/18-phase-5b-design.md` 与 ADR-0008 状态，留待 Codex 独立验收。

## 7. 修复记录（本轮）

- 问题：`parseRoot` 对未知 positional 参数返回 `unknown option '<argument>'`，会把私密路径回显到 stderr，违反“输入路径不出现在 stdout/stderr”的合同。
- 修复：未知 flag 固定输出 `unknown option`，未知 positional 固定输出 `unexpected argument`，不再拼接参数值；`Sources/SpaceJudgeVolumePlanKit/VolumePlanCommand.swift`。
- 回归：`unknownPositionalPathNotEchoed` 断言 `spacejudge-volume-plan /private/Users/secret-name` 退出 2、stdout 为空、stderr 不含完整路径/路径组件/用户名；`helpAndArgumentErrors` 断言未知 flag 同样不回显。
- 验证：`swift test --filter VolumePlanCommandTests` → 9 tests / 1 suite 通过；完整 `swift test` → **377 tests / 53 suites** 通过，0 warning。`--root` 缺值仍退出 2，有效路径行为不变。
