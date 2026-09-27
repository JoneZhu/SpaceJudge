# Phase 5A Pi 实施报告

状态：**完成（含第 2 轮修正），等待 Codex 独立验收**

日期：2026-09-27
环境：MacBookPro18,2 / Apple M1 Max / arm64 / macOS 26.6.2 (25G83) / Xcode 26.6 / Swift 6.3.3
Host shell 为 x86_64（Rosetta），所有 Swift/Xcode 命令均以 `arch -arm64` 执行。

## 0. 第 2 轮修正摘要

1. **取消吞吐口径修正**：`nodesPerSecond` 现在对 completed/cancelled 一律使用本次**成功持久化**的 `statistics.nodeCount / scanAndPersistSeconds`；completed 时与 `actualNodes` 等价。日志改为 `persisted=… fixture=… (… persisted nodes/s)`，不再拿未持久化的 fixture 总数计算或冒充完整扫描。
2. **临时清理硬校验**：成功路径必须先确认 `artifact.cleanup() == true` 才打印 `removed temporary artifacts` 并返回；否则抛 `E2EBenchError.fixture`（退出码 3），不谎报已删除。失败路径不被 cleanup 失败覆盖，只输出短 warning。判断通过可注入 `artifactRootProvider` 覆盖，并有回归测试。
3. **移除无上限的 `--file-bytes`**：fixture 文件固定 1 字节，消除调用方可控的分配与乘法溢出面；`logicalBytes` 使用 `multipliedReportingOverflow`，溢出归类为 fixture 错误。五组基准默认口径仍为 1 字节。

## 1. 核心实现

### 1.1 扫描对账（纯派生）

- 新增 `Sources/SpaceJudgeAppSupport/ScanAttribution.swift`
  - `public enum ScanAttributionState { scanning, terminal(attributedBytes:isComplete:) }`
  - `ByteFormatting.attributionLine(_:volume:) -> String?`：
    - `nil` → 不显示；
    - scanning → `已扫描并归属 X`；
    - terminal + used 未知 → `当前范围 X`；
    - terminal + `used >= attributed` → `当前范围 X · 卷内其他/未纳入 Y`；
    - terminal + `attributed > used` → `当前范围 X · 与卷用量差异 +Y`；
    - 未完成终态加 `（未完成）`；差值先比较后相减，`UInt64.max`/`0` 不下溢；真正 0 显示 `0 B`。
- `Sources/SpaceJudgeAppSupport/AppModel.swift`
  - 新增只读派生值 `scanAttribution`（优先级 summary > progress > nil）与 `attributionLine`。不缓存第二份 attributed 状态。
- `App/SpaceJudgeApp/ContentView.swift`
  - footer 在容量行后增加对账行，accessibility identifier = `scan-attribution-line`，单行截断，保持 safe-area inset，不遮挡 treemap。
- 未改动 `ScanRequest` 单根、`stayOnRootFileSystem`、SQLite schema v1，也未写入任何用户路径；未修改 Phase 4 treemap 面积/上限/交互。

### 1.2 端到端规模 benchmark

- 新增内部库 `Sources/SpaceJudgeBenchSupport/`（`SpaceJudgeBenchSupport`，依赖 Domain/Scan/Store/UseCases；App 不依赖它）：
  - `E2EBenchOptions.swift`：CLI 合同、`--help` 文本、参数校验（退出码 2）。
  - `Fixture.swift`：有界内存 fixture 生成器 + `ArtifactRoot` 安全清理。
  - `SystemMetrics.swift`：可注入的 peak RSS（`getrusage`，Darwin 单位为 bytes）与 `/dev/fd` 计数；API 失败返回 `nil`。
  - `E2EBenchResult.swift`：稳定、有序、仅有限数值的 JSON。
  - `E2EBenchRunner.swift`：真实链路编排与完整性验证。
- 新增可执行 `Sources/SpaceJudgeE2EBench/main.swift`，产品名固定为 `spacejudge-e2e-bench`。
- 链路严格为：真实目录 fixture → `DarwinBulkEnumerator` → `FileSystemScanEngine` → `PersistingScanRunner` → `SQLiteSnapshotRepository` → `close` → `openReadOnly` → 校验；不合成 `NodeBatch`。
- fixture 生成器 `mixed` 使用显式栈（深度上限 32、分支 4），`wide` 单层流式；不保存 100 万条完整路径，1,000,000 节点实测成功。
- fixture 文件固定 1 字节（无 `--file-bytes`）：本阶段测元数据/持久化管线，不冒充大文件 I/O。
- `--nodes N` 定义为**包含 fixture 根目录**的扫描节点总数，输出同时给 `requestedNodes` 与 `actualNodes`。
- 默认在 `mkdtemp` 任务根内生成 `fixture/` 与数据库（互为兄弟，数据库不在被扫描目录内）；临时根带随机 marker，仅在 marker 匹配且路径位于临时 base 下时删除；`--keep-artifacts DIR` 要求 DIR 不存在、拒绝覆盖、保留并打印路径。
- 测量口径：`firstStartedMillis`/`firstCommittedMillis` 从调用 runner 起算；`scanAndPersistSeconds` 到 terminal 成功写入；close/reopen 校验不计入该字段。取消模式在第一个 `.committed` 后请求 `engine.cancel`，输出 `cancelRequestedMillis`/`cancelTerminalMillis`/`cancelLatencyMillis`/`updatesAfterCancelRequest`。
- `nodesPerSecond = statistics.nodeCount / scanAndPersistSeconds`（成功持久化节点数），completed 与 cancelled 一致。
- 退出码：0 成功，2 参数，3 fixture，4 scan/store，5 verification。
- 清理规则：成功时临时根必须确认删除，否则以 fixture 错误退出；失败路径优先保留原始 scan/store 错误，cleanup 失败仅 warning。

## 2. 测试与构建命令（真实退出码）

| 命令 | 退出码 | 结果 |
| --- | ---: | --- |
| `arch -arm64 swift test --scratch-path <fresh>` | 0 | **322 tests / 45 suites 全部通过**（原 291/39 + 新增 31/6） |
| `arch -arm64 swift build -c release --scratch-path <fresh>` | 0 | Build complete |
| `arch -arm64 swift test --sanitize=thread --scratch-path <fresh> --filter 'AppModelTests\|ScanUpdateBufferTests\|PersistingScanRunnerTests'` | 0 | 32 tests / 3 suites 通过，无 TSan 报告 |
| `xcodebuild ... Debug ... CODE_SIGNING_ALLOWED=NO` | 0 | **BUILD SUCCEEDED** |
| `xcodebuild ... Release ... CODE_SIGNING_ALLOWED=NO` | 0 | **BUILD SUCCEEDED** |

新增测试覆盖（设计第 5 节）：

- 格式化：nil、scanning、completed（used> / 相等 / 未知）、cancelled 未完成、attributed>used 正差异、`UInt64.max`、`0`。
- AppModel：fresh 为 nil、progress 显示 scanning、summary 覆盖 progress、cancelled 终态标未完成。
- benchmark：参数合法/缺参/非法 nodes/shape/未知项（含已移除的 `--file-bytes`）/help；`ArtifactRoot` 临时清理、marker 被篡改时拒绝删除、keep 目录已存在拒绝覆盖、keep 模式 cleanup 空操作、fixture 计数与确定性；小规模 mixed/wide 完成并可解析 JSON、计数一致、重开成功；取消模式终态 cancelled 且取消字段存在；**取消吞吐按 persistedNodes 计算（显式断言其 ≠ fixture 总数口径）**；OS 指标不可用时序列化为 `null`；非法 fixture 参数被拒；keep 模式产物存在；**临时清理失败不能成功且不谎报已删除**。

## 3. Release benchmark（本机实测，未控缓存）

第 2 轮重跑受影响的 100k cancel 与 1k completed 清理 smoke；其余四组沿用第 1 轮结果（本轮未改动其代码路径，但已重新编译 Release）。

| 场景 | status | actualNodes | firstStarted | firstCommitted | scanAndPersist | nodes/s（persisted 口径） | peak RSS | db after close | fdDelta | persisted | rootAggComplete |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 100k mixed | completed | 100000 | 41.9 ms | 61.6 ms | 0.842 s | 118,718 | 59.6 MB | 29.5 MB | 0 | 100000 | true |
| 500k mixed | completed | 500000 | 26.6 ms | 186.9 ms | 5.723 s | 87,366 | 132.8 MB | 138.2 MB | 0 | 500000 | true |
| 1m mixed | completed | 1000000 | 32.1 ms | 215.3 ms | 16.866 s | 59,291 | 244.9 MB | 276.1 MB | 0 | 1000000 | true |
| 100k wide | completed | 100000 | 26.9 ms | 42.8 ms | 1.155 s | 86,588 | 56.3 MB | 36.2 MB | 0 | 100000 | true |
| 100k mixed cancel | cancelled | 100000 | 30.7 ms | 45.0 ms | 0.0675 s | **88,951（persisted 6,000 节点）** | 19.6 MB | 2.8 MB | 0 | 6000 | false |
| 1k completed 清理 smoke | completed | 1000 | 31.4 ms | 55.9 ms | 0.0586 s | 17,070 | 14.4 MB | 0.44 MB | 0 | 1000 | true |

- completed 时 `nodesPerSecond == actualNodes/scanSeconds`；cancel 时 `nodesPerSecond == persistedNodes/scanSeconds`，不再出现 1,703,985 nodes/s 这类虚高值。
- fixture 生成分别耗时：100k mixed 9.4 s、500k mixed 47.8 s、1m mixed 92.9 s、100k wide 9.0 s、cancel 9.6 s；生成与扫描分开计时。
- 取消：请求 45.0 ms，terminal 67.5 ms，**cancelLatency 22.5 ms**（门 <200 ms 停止普通事件、<2 s terminal），请求后普通 committed/progress 更新 5 次（在途批次/进度收尾）。
- 工程门对照：100k mixed 首批 61.6 ms（<500 ms ✓）、总 0.842 s（<2 s ✓）；1m 峰值 RSS 244.9 MB（<250 MB ✓）；所有 completed 持久化计数与 manifest 精确一致；fdDelta 全为 0。
- `peakResidentBytes` 使用 `getrusage.ru_maxrss`（Darwin 单位 bytes），未做缩放；API 失败分支已由单测覆盖为 `null`，未伪造 0。
- 清理 smoke：默认小规模运行前后 `/tmp/spacejudge-e2e-*` 均为 0，退出码 0；清理失败路径由单测断言非 0 且不打印已删除。

## 4. Phase 4 treemap 回归

Release `spacejudge-treemap-bench` 退出码 0：

| 场景 | p50 | p95 | max | 基线 p95 | 门 |
| --- | ---: | ---: | ---: | ---: | --- |
| layout 10k | 0.865 ms | 1.216 ms | 1.781 ms | 1.096 ms | <50 ms ✓ |
| hit-index 2k | 0.104 ms | 0.114 ms | 0.219 ms | 0.106 ms | <10 ms ✓ |
| render 1280×800 | 6.099 ms | 6.456 ms | 6.944 ms | 6.082 ms | <16.7 ms ✓ |
| resize layout ×100 | 0.537 ms | 0.560 ms | 0.585 ms | 0.547 ms | 记录项 |
| point query avg | 0.135 µs | p95 0.167 µs | — | 0.132 µs | <20 µs ✓ |

峰值 RSS 自报 26,886,144 bytes（Phase 4 基线 26,804,224）。无可见回退（差异在噪声范围）。

## 5. 证据路径

根：`/tmp/spacejudge-phase5a-pi.ykWHzl/`
报告：`/tmp/spacejudge-phase5a-pi.ykWHzl/report.md`
证据：`/tmp/spacejudge-phase5a-pi.ykWHzl/evidence/`

- `tests.log`：全量测试 stdout/stderr + EXIT=0（322 tests / 45 suites）。
- `release-build.log`、`xcode-debug.log`、`xcode-release.log`、`tsan.log`。
- `bench-100k-mixed.{json,err}`、`bench-500k-mixed.{json,err}`、`bench-1m-mixed.{json,err}`、`bench-100k-wide.{json,err}`、`bench-100k-mixed-cancel.{json,err}`（已按 persisted 口径修正）、`bench-1k-completed.{json,err}`（清理 smoke）。
- `treemap-bench.json` / `.stdout` / `.err`。
- `release-bin-path.txt`。

## 6. 限制与说明

- 缓存状态为 `uncontrolled`（`cacheState`），未做冷/热缓存分离，也未用墙钟阈值在程序内判失败；性能门由本报告人工比较。
- 吞吐口径固定为“本次成功持久化节点数 / scanAndPersistSeconds”；取消运行因此反映真实落库速度，而非 fixture 规模。
- `mixed` fixture 是确定性合成拓扑（宽根目录 + 多层 + 空目录 + 1 字节小文件），不是真实系统盘采样；测元数据管线，不冒充大文件 I/O。
- cancel 模式在取消点后 persistedNodes 必然小于 fixture 总数，因此完整性验证对取消模式只断言“不超过 fixture 且重开后状态/计数一致”，对 completed 模式才断言与 manifest 精确一致。这与设计 4.3 的完整性条目在取消场景下存在天然张力，已按事实处理，未放宽 completed 门。
- `--nodes` 包含 fixture 根目录。
- 未实现（且明确不做）：APFS 多卷/firmlink、FSEvents、schema 迁移、删除/清理/AI/网络/遥测、Sandbox、签名、公证、更新；未修改 Phase 4 treemap 语义。
- 未在真实 App 中做人工 footer 走查（无法在本任务中驱动 GUI 交互）；footer 行为由纯格式化与 AppModel 单测覆盖，建议 Codex 在真实 App 复验 900×640 / 深色 / VoiceOver。

## 7. 进程 / 服务

无后台服务。所有 benchmark 进程已退出，无残留 PID；无 `killall`/`pkill`；默认临时 fixture 与数据库已由工具自身清理，运行前后 `/tmp/spacejudge-e2e-*` 均为 0，测试临时目录均无残留。

## 8. Git 修改范围

不创建分支、不 commit、不 push、不发布。工作区仍为初始未提交状态。本阶段新增/修改：

- 修改：`Package.swift`、`Sources/SpaceJudgeAppSupport/AppModel.swift`、`App/SpaceJudgeApp/ContentView.swift`
- 新增：`Sources/SpaceJudgeAppSupport/ScanAttribution.swift`
- 新增：`Sources/SpaceJudgeBenchSupport/{E2EBenchOptions,Fixture,SystemMetrics,E2EBenchResult,E2EBenchRunner}.swift`
- 新增：`Sources/SpaceJudgeE2EBench/main.swift`
- 新增：`Tests/SpaceJudgeAppSupportTests/ScanAttributionTests.swift`
- 新增：`Tests/SpaceJudgeBenchSupportTests/E2EBenchTests.swift`
- 新增：`docs/phase-5a-pi-report.md`（本报告副本）
- 未改动 HTML 原型、`output/`、Phase 0–4 文档、treemap 行为。

明确：**未 commit、未 push、未 publish、未签名/公证、未启用 Sandbox。**
