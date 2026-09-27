# Phase 5B 实施设计：启动盘可见卷组与边界安全

状态：Accepted

日期：2026-09-27

## 1. 本阶段要解决的问题

Phase 5A 已能扫描用户选择的目录、展示卷容量并诚实表达“当前范围”；但现代 macOS 的启动盘不是一个普通单卷目录树：只读 System volume 与可写 Data volume 组成 APFS volume group，Finder 和普通应用看到的是由 firmlink 拼接后的统一命名空间。

Phase 5B 的目标是让用户选择启动盘根目录时，SpaceJudge 能按“用户实际看到的启动盘目录树”扫描：

1. 沿系统提供的 firmlink 投影进入 Data volume；
2. 不再从 `/System/Volumes/Data` 等原始挂载入口扫描同一份数据；
3. 不进入外接磁盘、网络盘、模拟器 runtime、VM、Preboot、Update 等独立挂载；
4. 普通目录和普通外部卷继续保持原有单文件系统边界；
5. 计划识别失败时安全降级，不凭路径字符串或卷名猜测，不扩大范围；
6. 用可复现的解析器、策略矩阵、合成树和真实根目录探针证明规则成立。

本阶段仍是只读浏览器，不加入删除、废纸篓、AI、清理建议、内容读取、网络、FSEvents、签名、公证或自动更新。

## 2. 已核实的系统事实

### 2.1 Apple 的卷组语义

Apple 将一个 System volume 和一个 Data volume 组成 volume group，并在 UI 中显示为一个磁盘。Firmlink 是从系统卷目录到同一卷组数据卷目录的一对一穿越点，不能跨越 volume group 边界。

因此产品层的“启动盘”应对应统一可见命名空间，而不是把两个根分别递归后相加。分别扫描会遇到路径重复、身份归属不一致、排序层级不符合 Finder 心智模型等问题。

### 2.2 Darwin 枚举语义

本机 macOS SDK 和 `man 2 getattrlistbulk` 明确：

- 挂载点目录在 `ATTR_DIR_MOUNTSTATUS` 中带 `DIR_MNTSTATUS_MNTPOINT`；bulk 返回的是底层目录项属性，若要读取挂载后根目录属性需另行调用 `getattrlist`。
- firmlink 目录在 `ATTR_CMN_FLAGS` 中带 `SF_FIRMLINK`；bulk 返回 firmlink 自身属性，而不是目标属性。
- 普通 `open`/路径遍历会让 firmlink 对应用近似透明；打开该目录后即可枚举目标侧的可见内容。

当前扫描器已经请求 `ATTR_CMN_FLAGS`，但解析器丢弃了值；Phase 5B 必须把 `SF_FIRMLINK` 转成明确事实。不得读取或依赖 `/usr/share/firmlinks` 私有映射文件，也不得调用 `diskutil` 解析非 API 文本作为产品逻辑。

### 2.3 本机只读探针事实

2026-09-27 在当前测试机上：

- `/Applications`、`/Library`、`/Users`、`/private` 等位于启动盘可见根下，并由系统统一命名空间暴露；
- `/System/Volumes/Data` 是真实挂载入口；
- VM、Preboot、Update、硬件辅助卷和多个 CoreSimulator runtime 是独立挂载；
- System/Data 容量由 APFS space sharing 共同影响，容量 API 不能反推每个目录的独占物理块。

这些事实只用于验证设计，不得把当前机器的 BSD device number、卷名或 firmlink 列表硬编码进产品。

## 3. 核心决策

遵守 [ADR-0008](adr/0008-visible-startup-volume-group.md)：Phase 5B 使用“单根、统一可见命名空间、显式 firmlink、挂载点截断”的方案，不实现两个物理根的合并器。

```text
用户选择启动盘根
  -> Foundation 公共卷属性识别 root filesystem + APFS
  -> VolumeScanPlan(kind: visibleStartupVolumeGroup)
  -> 从所选根扫描统一可见命名空间
       ├── 普通目录：进入
       ├── SF_FIRMLINK：进入，并标记 projection
       ├── DIR_MNTSTATUS_MNTPOINT：记录边界，不进入
       ├── 未授权 device transition：记录边界，不进入
       └── symlink：保持不跟随
```

原始 `/System/Volumes/Data` 是 mount point，因此只作为边界节点出现；Data 内容通过 `/Users`、`/Applications`、`/Library`、`/private` 等可见投影扫描一次。`/Volumes` 的投影目录可以进入，但其下每一个真正挂载的外部卷仍被截断。

## 4. 领域模型与公开契约

### 4.1 新的边界策略

在 `BoundaryPolicy` 末尾追加：

```swift
case visibleStartupVolumeGroup
```

语义冻结如下：

| 策略 | 普通目录 | firmlink | mount point | 意外 device transition |
| --- | --- | --- | --- | --- |
| `selectedTree` | 进入 | 进入 | 进入 | 进入 |
| `stayOnRootFileSystem` | 进入 | 仅在原规则允许时进入 | 截断 | 截断 |
| `visibleStartupVolumeGroup` | 进入 | 进入并标记 | 始终截断 | 截断 |

`selectedTree` 是明确请求跨挂载的低层能力，App 本阶段不自动使用。默认普通选择仍为 `stayOnRootFileSystem`。

SQLite schema v1 的枚举编码只允许“末尾追加”：`visibleStartupVolumeGroup = 2`。这不是表结构迁移；旧值 0、1 的含义绝不能改变。所有 encode/decode 和未知值测试必须更新。

### 4.2 VolumeScanPlan

在不让 Domain 依赖 AppKit/SwiftUI 的前提下新增值类型，推荐形状：

```swift
public enum VolumeScanPlanKind: Sendable, Equatable, Codable {
    case selectedFileSystem
    case visibleStartupVolumeGroup
}

public struct VolumeScanPlan: Sendable, Equatable {
    public let kind: VolumeScanPlanKind
    public let root: ScanRoot
    public let boundaryPolicy: BoundaryPolicy
    public let evidence: VolumeScanPlanEvidence
}

public struct VolumeScanPlanEvidence: Sendable, Equatable {
    public let isVolume: Bool?
    public let isRootFileSystem: Bool?
    public let fileSystemType: String?
    public let source: VolumePlanEvidenceSource
}
```

具体名称可调整，但必须满足：

- plan 是不可变、可测试、可安全跨并发边界的值；
- evidence 只保存非敏感卷属性，不保存完整用户路径、卷 UUID、BSD disk 名或 mount-from location；
- plan 能构造现有 `ScanRequest`，不复制一套扫描参数；
- “未知”与 `false` 分开；查询失败不能伪装为确定事实；
- AppModel 可公开只读的 plan kind 供测试和未来 UI 使用，但第一版无需新增醒目的 UI 控件。

### 4.3 计划解析协议

在 AppSupport 建立可注入协议：

```swift
public protocol VolumeScanPlanning: Sendable {
    func plan(for selection: DirectorySelection) -> VolumeScanPlan
}
```

生产实现使用 `URL.resourceValues` 的公共键：

- `isVolumeKey`
- `volumeIsRootFileSystemKey`
- `volumeTypeNameKey`
- 可选读取 `volumeIsLocalKey` 作为诊断，不作为唯一判定依据

仅当事实明确满足：所选项是 volume root、是 root filesystem、文件系统类型为 APFS（大小写不敏感）时，生成 `visibleStartupVolumeGroup`。所有其他情况——包括属性缺失、抛错、非 APFS、外部卷根、普通目录——都生成 `selectedFileSystem + stayOnRootFileSystem`。

禁止以下判定：

- `url.path == "/"`；
- 显示名等于 `Macintosh HD`；
- 容量相同；
- device number 恰好相同；
- 读取 `/usr/share/firmlinks`；
- 解析 `diskutil` 输出。

计划解析不得在 MainActor 上执行可观测的长 I/O。若 `resourceValues` 在真实机器出现明显阻塞，后续可把解析放到短生命周期后台任务；本阶段先用 signpost/基准记录，不先做无证据并发复杂化。

## 5. 枚举事实与节点标记

### 5.1 RawDirectoryEntry

增加 `isFirmlink: Bool`，来源只能是已返回的 `ATTR_CMN_FLAGS & SF_FIRMLINK`。

解析规则：

- 只有 returned common bitmap 声明 `ATTR_CMN_FLAGS` 存在时才能读取；
- 未返回、fallback 不可确认或普通条目均为 `false`，不能根据名称猜测；
- 现有 parser 已消费 4 字节 FLAGS 槽位，Phase 5B 只补事实，不改变后续字段 offset；
- `DarwinBulkEnumerator.markingFallback` 等复制路径必须保留字段；
- fuzz、截断、returned-bitmap 测试要覆盖 FLAGS 存在/缺失。

### 5.2 NodeFlags

在现有 bit 尾部追加：

```swift
public static let firmlinkProjection = NodeFlags(rawValue: 1 << nextBit)
```

该标志表示“此目录节点是系统公开的卷组投影入口”，不是 symlink、不是 mount point、不是错误。SQLite 已按整数保存 NodeFlags，无需 schema 迁移；旧 bit 含义不得改变。

UI 第一版不必单独画图标。标志首先用于正确性、诊断和未来说明。

## 6. 边界判定必须成为纯策略

把 `FileSystemScanEngine.processEntries` 中内联的 mount/device 判断下沉为可穷举测试的纯函数或小值类型。输入至少包含：

- `BoundaryPolicy`
- root device ID
- 当前工作目录的 best-known device ID
- child device ID
- `isMountPoint`
- `isFirmlink`
- facts 是否来自 fallback（若实现需要）

输出至少包含：

```swift
enum DirectoryTraversalDecision {
    case descend(extraFlags: NodeFlags)
    case boundary(extraFlags: NodeFlags, reason: BoundaryReason)
}
```

内部 reason 至少区分 actual mount 与 unexpected device transition，便于测试；本阶段可继续对外聚合为现有 `mountBoundary` issue/flag，避免扩大数据库结构。

### 6.1 visibleStartupVolumeGroup 的优先级

顺序不可交换：

1. `isMountPoint == true`：始终 boundary，即使同时出现 firmlink 或 device 相同；
2. `isFirmlink == true`：允许 descend，增加 `firmlinkProjection`；
3. child device 与当前授权 device 明确不一致：boundary；
4. device 任一侧未知：普通目录允许继续，但保留现有 unknown 语义；不得伪造 ID；
5. 其余普通目录：descend。

若实际打开 firmlink 后系统报告的 device identity 从 System 切到 Data，授权只能沿“刚刚明确识别的 firmlink”发生一次。实现可以给目录工作项携带 `enteredThroughFirmlink`，或在打开目录后取得当前 device 并更新工作项；不得把“已经遇到过一个 firmlink”变成允许后续任意跨设备的全局开关。

### 6.2 防重复和防越界不变量

- mount point 与 firmlink 同时为真时，mount point 胜出；
- `/System/Volumes/Data` 原始挂载根不得入队；
- 外部卷/网络卷/模拟器 runtime 的 mount root 不得入队；
- firmlink 目标的普通后代只出现一次；
- symlink 即使指向同卷也不入队；
- hard-link 去重继续使用 `(deviceID,fileID)`，Phase 5B 不把 firmlink 当 hard link；
- 取消、spool、分页和 worker 并发不能丢失新增标志或越过策略。

## 7. App 接线

`AppModel` 注入 `VolumeScanPlanning`。采用 selection 后先生成 plan，再从 plan 构造 `ScanRequest`。要求：

- 新选择覆盖旧 plan；取消 picker 恢复旧稳定状态和旧 plan；
- rescan 复用当前 selection 重新解析或复用不可变 plan，二选一但测试固定；推荐每次新 selection 解析一次，rescan 复用，避免同一次会话语义漂移；
- reset/shutdown 清理 plan 的用户可见状态，但不额外持久化路径；
- 属性查询失败不阻止扫描，只降级为 `stayOnRootFileSystem`；
- Debug 的 `SPACEJUDGE_TEST_ROOT_PATH=/` 也必须走同一 planner，不能有测试专用策略捷径。

现有 UI 保持紧凑。容量行和对账行不改名，不显示“100% 已覆盖”，因为 APFS clone、snapshot、权限和计量口径仍会产生差值。

## 8. 诊断 CLI

新增 SwiftPM executable `spacejudge-volume-plan`，用于人工和 CI 环境验证公共事实与根目录首层属性。最低合同：

```text
spacejudge-volume-plan [--root PATH]
```

默认 root 为 `/`。输出唯一一行 JSON，错误写 stderr。JSON schemaVersion 1 至少包含：

```json
{
  "schemaVersion": 1,
  "planKind": "visibleStartupVolumeGroup",
  "boundaryPolicy": "visibleStartupVolumeGroup",
  "isVolume": true,
  "isRootFileSystem": true,
  "fileSystemType": "apfs",
  "rootDeviceKnown": true,
  "rootEntryCount": 22,
  "firmlinkEntryCount": 8,
  "mountPointEntryCount": 0,
  "unexpectedDeviceEntryCount": 0
}
```

约束：

- 不输出输入绝对路径、用户名、卷 UUID、BSD disk 名、mount-from location 或条目名称；
- root 首层枚举必须使用生产 `DarwinBulkEnumerator` 与生产 parser，不能另写一套旗标解析；
- 只枚举 root 的 immediate children，不递归；因此它不是性能基准，也不触碰个人文件内容；
- root 不可读退出 3，计划/资源值错误若已安全降级仍退出 0，并用 nullable evidence 表达；JSON 编码错误退出 4；参数错误退出 2；
- `--help` 清楚说明隐私和非递归行为；
- 非启动盘目录也可运行，预期 plan 为 selectedFileSystem。

## 9. 自动化测试

### 9.1 Domain / Store

- 新 `BoundaryPolicy` Codable round-trip 与 CaseIterable。
- schema encoding 0、1 不变，新值为 2，未知值仍失败。
- 新 NodeFlags bit 与旧 bits 不冲突，SQLite round-trip 保留。
- plan/evidence 的 unknown、false、true 不混淆。

### 9.2 Parser / Enumerator

- FLAGS 带 `SF_FIRMLINK` -> `isFirmlink == true`。
- FLAGS 不带、未返回 -> false。
- mount + firmlink 可同时被表达，策略由后续层决定。
- flag 后的 FILEID/PARENTID offset 仍正确。
- fallback copy 保留 `isFirmlink`。
- 既有 10,000 轮 fuzz 不回归。

### 9.3 边界策略矩阵

至少覆盖三种 policy 与以下组合：

- same device normal directory；
- root/current/child device 的已知和未知排列；
- firmlink same device；
- firmlink device transition；
- mount same device；
- mount different device；
- mount + firmlink 同时为真；
- firmlink 后只允许所需的一次转换，后续无授权转换仍截断。

### 9.4 合成扫描树

用 scripted enumerator 构造：

```text
root(system)
  Applications [firmlink -> data]
    AppA
  Users [firmlink -> data]
    user
      file
  System
    Volumes
      Data [mount -> same data root]
      VM [mount]
  Volumes [firmlink -> data]
    External [mount]
```

断言：AppA、user/file 各一次；Data、VM、External 节点可见但不枚举后代；firmlink 节点带 projection；boundary 节点带 mountBoundary；终态聚合、计数、取消、spool 序列都正确。

### 9.5 Planner / AppModel

通过注入 facts provider 覆盖：

- APFS + volume root + root filesystem -> visible group；
- APFS 外部卷、APFS 普通目录、非 APFS、任一 unknown、查询抛错 -> selected filesystem；
- beginScan 使用 plan 的 policy；
- picker 取消、rescan、新 selection、shutdown；
- 不保存或输出绝对路径。

### 9.6 CLI smoke

- `/` 输出可解析 JSON，当前受支持的 macOS 上识别为 visible group，firmlink count > 0；
- 普通临时目录输出 selected filesystem，firmlink/mount count 为 0；
- 不存在路径和非目录错误码；
- stdout 不含输入路径或当前用户名。

## 10. 性能与资源验收

新增字段只复用已经请求的 FLAGS，不增加逐条 syscall。工程目标：

- 10 万 mixed 完整扫描 + SQLite 相对 Phase 5A 基线总耗时回归不超过 10%；
- 100 万 mixed 峰值 RSS 仍 < 250 MB；
- root immediate probe < 500 ms（热/未控缓存，记录真实值，不在程序内硬失败）；
- 取消 200 ms 内停止普通事件，2 s 内 terminal；
- FD delta 不随 firmlink/mount 数增长；
- `selectedFileSystem` 普通目录结果与 Phase 5A 节点/聚合计数一致。

Phase 5A 基线 100 万节点 RSS 238.8 MB，只余约 11.2 MB。不得给每个节点增加 String、URL、完整路径或 plan 对象；新增事实应为紧凑 Bool/flags，并在现有批次内传递。

## 11. Pi 自测矩阵

Pi 必须使用全新 scratch/output 目录并保留原始日志：

```sh
arch -arm64 swift test --scratch-path <fresh>
arch -arm64 swift build -c release --scratch-path <fresh>
arch -arm64 swift test --sanitize=thread --scratch-path <fresh> \
  --filter 'AppModelTests|ScanEngineTests|PersistingScanRunnerTests'

<release-bin>/spacejudge-volume-plan --root /
<release-bin>/spacejudge-volume-plan --root <fresh-empty-directory>
<release-bin>/spacejudge-e2e-bench --nodes 100000 --shape mixed
<release-bin>/spacejudge-e2e-bench --nodes 1000000 --shape mixed
<release-bin>/spacejudge-e2e-bench --nodes 100000 --shape mixed --cancel-after-first-commit

xcodebuild -project App/SpaceJudge.xcodeproj -scheme SpaceJudge \
  -configuration Debug -derivedDataPath <fresh> CODE_SIGNING_ALLOWED=NO build
xcodebuild -project App/SpaceJudge.xcodeproj -scheme SpaceJudge \
  -configuration Release -derivedDataPath <fresh> CODE_SIGNING_ALLOWED=NO build
```

不得用完整 `/` 长时间扫描作为自动测试门。Pi 可以运行显式超时/取消的真实根 smoke，但必须把 DB 和日志放在任务专属临时目录、记录终态和清理结果，并避免生成不可控的大型产物。

## 12. Codex 独立验收

Pi 交付后 Codex 将：

1. 审查领域枚举兼容、parser offset、边界优先级和 planner 的 fail-closed 行为；
2. 从全新 scratch 独立运行全套 Swift、TSan、Release 和 Xcode 构建；
3. 独立运行 root/普通目录 plan probe，核对 JSON 不泄露路径；
4. 复跑 10 万与 100 万端到端基准，与 Phase 5A 比较；
5. 运行 synthetic volume-group 回归和真实根的短时取消 smoke；
6. 用 Debug App 的测试根 `/` 验证 plan 生效、可取消、UI 不假称完整覆盖；
7. 检查没有进入外部/模拟器挂载的证据，并确认无残留进程、数据库和大型临时目录；
8. 只有全部通过后把本文件和 ADR 状态改为 Accepted，并新增 Phase 5B baseline。

## 13. 明确不在本阶段

- 直接扫描 APFS snapshots 或计算 snapshot reclaimable bytes；
- clone 独占物理块、purgeable space 或“删除后释放”承诺；
- 扫描其他登录用户受保护数据的授权绕过；
- Full Disk Access 自动授予或系统设置自动操作；
- 外接卷联合视图、网络卷、Time Machine、CoreSimulator runtime；
- FSEvents 增量更新和历史快照差异；
- 删除、废纸篓、清理建议、AI、网络、遥测；
- 签名、公证、更新和发布。

## 14. 后续入口

Phase 5C 再处理权限说明与崩溃/中断恢复；发布硬化单独成阶段。只有在可见卷组遍历与权限边界都有真实验收证据后，才讨论“哪些空间可清理”的产品规格和安全模型。
