# Phase 5A 实施设计：扫描对账与端到端规模基准

状态：Accepted

日期：2026-09-27

## 1. 本阶段要回答的问题

Phase 4 已证明空间图本身足够快，但还没有证明“真实目录枚举 → 批次事件 → SQLite 落库 → 重开查询”在大规模下仍然有界，也没有把卷容量与当前扫描范围之间的差值诚实地呈现给用户。

Phase 5A 只解决两个问题：

1. 用户能看懂卷容量和本次扫描覆盖的是两件事，不把范围外数据误称为垃圾或遗漏。
2. 工程可以重复测量 10 万、50 万、100 万真实目录节点的完整扫描持久化链路，并留下机器可比较的 JSON 证据。

本阶段不是“全盘卷组扫描”。APFS System/Data 联合计划、firmlink 去重、快照/clone 独占空间、FSEvents、签名、公证和更新均不在本阶段实现。

## 2. 产品语义

遵守 [ADR-0007](adr/0007-volume-capacity-and-scan-scope.md)。footer 保留现有容量行，并在有扫描事实后增加一条紧凑对账信息：

| 状态 | 文案 | 说明 |
| --- | --- | --- |
| 尚未开始 | 不显示 | 不用占位符制造噪声 |
| 扫描中，有 progress | `已扫描并归属 18.2 GB` | best-known，不暗示百分比 |
| completed / permissionLimited | `当前范围 312.6 GB · 卷内其他/未纳入 100 GB` | 差值中性，不代表可清理 |
| cancelled | `当前范围（未完成）18.2 GB · 卷内其他/未纳入 394.4 GB` | 必须明确未完成 |
| 当前范围大于卷已用 | `当前范围 420 GB · 与卷用量差异 +7.4 GB` | 可能来自 clone、并发变化或计量口径 |
| 卷已用未知 | `当前范围 312.6 GB` | 不显示虚构差值 |

细节约束：

- 终态优先使用 `ScanSummary.rootAttributedBytes`，扫描中使用 `ScanProgress.attributedBytes`。
- 真正的 0 必须显示 `0 B`，未知继续显示 `—` 或不显示；不能混淆。
- 差值使用溢出安全的比较后减法；不能先做无保护减法。
- `permissionLimited` 保留地图和对账行，并继续显示权限入口；对账行本身不宣称权限是否完整。
- 对账信息应有稳定 accessibility identifier，建议 `scan-attribution-line`。
- 900×640 下 footer 仍须可见；空间不足时允许两条信息使用 `ViewThatFits`、换行或合并成一个辅助区域，但不能遮挡 treemap。

## 3. 代码边界

### 3.1 纯格式化

在 `SpaceJudgeAppSupport` 增加纯、可测试的对账格式化入口。推荐 API 形状：

```swift
public enum ScanAttributionState: Sendable, Equatable {
    case scanning(attributedBytes: UInt64)
    case terminal(attributedBytes: UInt64, isComplete: Bool)
}

public static func attributionLine(
    _ state: ScanAttributionState?,
    volume: VolumeFacts?
) -> String?
```

名称可在不改变语义的前提下调整。格式化逻辑不能依赖 SwiftUI、数据库、绝对路径或当前 Locale 之外的全局状态。

`AppModel` 暴露一个只读派生值；不得复制保存第二份可漂移的 attributed byte 状态。优先级：terminal summary > progress > nil。

### 3.2 不改动的底层契约

- 不改变 `ScanRequest` 单根模型。
- 不改变 `BoundaryPolicy.stayOnRootFileSystem`。
- 不新增 schema v2，不把 root path 写入 SQLite。
- 不删除或重新定义现有 `ScanSummary.unattributedBytes`，避免本阶段把兼容性修正扩大成迁移工程。
- 不把容量查询失败升级成扫描失败。

## 4. 端到端 benchmark 可执行程序

新增 SwiftPM executable：`spacejudge-e2e-bench`。它必须使用与 App 相同的生产组件：

```text
deterministic real-directory fixture
  -> DarwinBulkEnumerator
  -> FileSystemScanEngine
  -> PersistingScanRunner
  -> SQLiteSnapshotRepository
  -> close
  -> openReadOnly
  -> persisted state/statistics/root aggregate verification
```

禁止用直接合成 `NodeBatch` 的方式冒充端到端；现有 `spacejudge-store-bench` 继续保留，用于隔离 Store 性能。

### 4.1 CLI 合同

最低支持：

```text
spacejudge-e2e-bench --nodes N [--shape mixed|wide] [--files-per-directory K]
                     [--keep-artifacts DIR] [--cancel-after-first-commit]
```

- `--nodes` 是期望的总文件系统节点数，定义必须在 `--help` 中明确：是否包含 fixture root；输出同时给出请求值与实际值。
- 默认 `shape=mixed`，固定算法与固定 seed；同一参数产生相同目录/文件数量和拓扑。
- `wide` 用于单层宽目录；`mixed` 包含宽目录、多层目录、空目录和普通小文件，但不创建超深到触发系统路径上限的 fixture。
- 文件内容最小化，默认可使用 0 或极小固定字节文件；报告 `fixtureLogicalBytes`。本阶段测元数据管线，不冒充大文件 I/O 基准。
- 默认在 `mkdtemp` 创建的任务专属临时根内生成 fixture 与数据库，二者互为兄弟，数据库绝不能位于被扫描目录中。
- 默认只删除工具自己创建且已校验前缀/marker 的临时根。`--keep-artifacts DIR` 只允许一个不存在的新目录，拒绝覆盖；保留时输出精确路径。
- 所有错误写 stderr，唯一 JSON 对象写 stdout；成功退出 0，参数错误 2，fixture 3，scan/store 4，verification 5。
- 不打印 fixture 内部的绝对个人路径；保留产物模式可以在 stderr 明示用户主动提供的产物目录。

### 4.2 测量口径

fixture 生成与扫描分开计时。至少输出这些稳定 JSON 字段：

```json
{
  "schemaVersion": 1,
  "requestedNodes": 100000,
  "actualNodes": 100000,
  "shape": "mixed",
  "fixtureGenerationSeconds": 0.0,
  "fixtureLogicalBytes": 0,
  "firstStartedMillis": 0.0,
  "firstCommittedMillis": 0.0,
  "scanAndPersistSeconds": 0.0,
  "nodesPerSecond": 0.0,
  "peakResidentBytes": 0,
  "databaseBytesAfterClose": 0,
  "fdBaseline": 0,
  "fdAfterClose": 0,
  "fdDelta": 0,
  "status": "completed",
  "persistedNodes": 100000,
  "persistedNames": 0,
  "persistedAggregates": 0,
  "rootAggregateComplete": true,
  "cacheState": "uncontrolled"
}
```

约束：

- `firstCommittedMillis` 从开始调用 runner 到第一个成功 SQLite commit update；started 不能冒充首批可浏览结果。
- `scanAndPersistSeconds` 到 terminal 已成功写入为止；关闭/reopen verification 另计或明确包含字段，不能悄悄变口径。
- `peakResidentBytes` 使用当前进程可获取的 OS 计量并说明 macOS 单位；若 API 失败必须为 `null` 或显式 unavailable，不能填 0。
- FD 统计在启动生产组件前取 baseline，在 repository/reader 关闭后取 after；`fdDelta` 应接近 0。不能遍历到系统最大 FD 并造成 benchmark 自身明显失真，可使用 `/dev/fd` 或有界公开机制并测试失败分支。
- 数据库体积在 close/checkpoint 后统计主库、WAL、SHM 的合计，并分别保留字段会更好。
- JSON 数值必须有限；不能输出 `nan` / `inf`。
- 不在程序内用墙钟阈值判失败。性能门由验收脚本/人工比较，避免慢机器无法取得证据。

### 4.3 完整性验证

成功 JSON 之前必须验证：

- terminal status 与模式一致；普通模式为 completed，取消模式为 cancelled。
- persisted node count 等于实际 fixture node count。
- scan summary 文件/目录计数与 fixture manifest 一致。
- 重开只读库后 scan state、root aggregate、最后 revision 存在；completed 模式 root aggregate 完整。
- root aggregate attributed bytes 与 summary 一致。
- 临时产物清理发生在 reader/writer 全部关闭之后。

取消模式额外输出：

- `cancelRequestedMillis`；
- `cancelTerminalMillis`；
- `cancelLatencyMillis`；
- 取消请求后的普通 committed/progress update 数量。

取消必须在观测到第一个成功 commit 后请求，以便同时覆盖真实 scanner、backpressure 和 SQLite。允许 terminal 前收尾一个已经在途的批次，但验收要记录事实；不得继续无界发布。

## 5. 自动化测试

至少新增：

### AppSupport

- nil state 不显示。
- scanning 显示 best-known attributed。
- completed：used > attributed、相等、used 未知。
- cancelled 明确“未完成”。
- attributed > used 显示正差异，不下溢。
- `UInt64.max` 与 0。
- `AppModel` 优先 summary、其次 progress；新 scan/reset 后清空。

### benchmark 小规模 smoke

- 100–1,000 节点 mixed 完成、JSON 可解析、计数一致、重开成功。
- wide 完成。
- cancel-after-first-commit 终态 cancelled，取消字段存在。
- 非法 nodes/shape、已存在 keep 目录被拒绝，绝不覆盖。
- 临时模式退出后任务根不存在；keep 模式产物存在。

如果 SwiftPM test 无法自然启动当前 package 的 executable，可以把参数解析、fixture plan、JSON result 和安全清理规则下沉到一个内部可测试模块，或者提供一个受控 shell smoke；不能因为测试接线困难而完全跳过错误路径。

## 6. 验收矩阵

Pi 自测和 Codex 独立验收都至少执行：

```sh
arch -arm64 swift test --scratch-path <fresh>
arch -arm64 swift build -c release --scratch-path <fresh>
arch -arm64 swift test --sanitize=thread --scratch-path <fresh> \
  --filter 'AppModelTests|ScanUpdateBufferTests|PersistingScanRunnerTests'

<release-bin>/spacejudge-e2e-bench --nodes 100000 --shape mixed
<release-bin>/spacejudge-e2e-bench --nodes 500000 --shape mixed
<release-bin>/spacejudge-e2e-bench --nodes 1000000 --shape mixed
<release-bin>/spacejudge-e2e-bench --nodes 100000 --shape wide
<release-bin>/spacejudge-e2e-bench --nodes 100000 --shape mixed --cancel-after-first-commit
```

Phase 5A 工程门沿用 `docs/05-testing-and-acceptance.md`：

- 10 万 mixed，热/未控缓存事实下记录首批和总耗时；目标首批 < 500 ms，总扫描 < 2 s，但失败时必须报告真实结果，不改规模。
- 100 万 mixed 峰值 RSS < 250 MB。
- 取消请求后 200 ms 内停止普通事件、2 s 内 terminal；记录在途批次。
- 完成后 FD delta 在可解释容差内，不能随节点数增长。
- 所有规模 persisted counts 与 manifest 精确一致。

还要重跑 Phase 4 treemap benchmark 与 Xcode Debug/Release build，证明 footer 改动没有破坏 UI 工程和既有性能基线。

## 7. 人工验收

在真实 App 中选择一个普通文件夹：

1. 扫描中只显示 best-known “已扫描并归属”，没有百分比。
2. 完成后显示“当前范围”和“卷内其他/未纳入”，容量行仍显示总容量/已用/剩余。
3. 取消后明确标注未完成。
4. 权限受限时保留对账行和权限帮助。
5. 900×640、宽窗口、浅色/深色下 footer 不遮挡地图；VoiceOver 能读到容量和对账摘要。

## 8. Pi 实施边界

Pi 可修改 `Package.swift`、AppSupport、App footer、相关 Tests，并新增 benchmark/support target 与 Phase 5A 实施报告。不得：

- 实现多根或 APFS firmlink 扫描；
- 改 SQLite schema；
- 加入删除、清理、AI、网络或遥测；
- 启用 Sandbox、签名、公证或自动更新；
- 修改 Phase 0–4 冻结的 treemap 面积、查询上限和交互语义；
- commit、push、发布或读取凭据。

Pi 完成普通修复和自测后一次性交付。Codex 审查 diff、从全新 scratch 独立复跑测试/基准，并用真实 App 验证 footer 后，才把状态改为 Accepted 并新增 Phase 5A baseline。

## 9. Phase 5B 入口

Phase 5B 才设计 `VolumeScanPlan`：识别 APFS volume group，明确 System/Data roots、firmlink 投影与去重、挂载边界、权限不足和容量对账。Apple 说明现代 macOS 的 System 与 Data volume 作为 volume group 呈现为一个实体，firmlink 连接两个文件系统；因此不能把当前单 device traversal 小修成“整盘扫描”。
