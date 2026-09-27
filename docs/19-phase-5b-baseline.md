# Phase 5B 验收基线：启动盘可见卷组与边界安全

状态：Accepted

日期：2026-09-27

## 1. 结论

Phase 5B 已完成 Pi 实施、一次隐私问题返修和 Codex 独立验收。

SpaceJudge 现在能在用户选择 macOS 启动盘根时，用公共 Foundation 卷事实生成 `visibleStartupVolumeGroup` 计划；扫描器保留 Darwin `SF_FIRMLINK`，沿系统公开的 firmlink 投影进入 Data volume，同时把真实 mount point 和未授权 device transition 截断。普通目录、外部卷和事实未知的选择继续安全降级为 `stayOnRootFileSystem`。

实现保持单根、只读、session-only 路径和 SQLite schema v1；没有加入删除、清理建议、AI、网络、FSEvents、Sandbox、签名、公证或更新。

验收结果：通过。

## 2. 最终实现

### 2.1 计划与 App 接线

- `VolumeScanPlanKind`：`selectedFileSystem` / `visibleStartupVolumeGroup`。
- `VolumeScanPlanEvidence`：只保留 `isVolume`、`isRootFileSystem`、通用文件系统类型和来源；未知保持 `nil`。
- `FoundationVolumeScanPlanner` 只读取公共 URL resource keys。
- 只有 `isVolume == true && isRootFileSystem == true && type == APFS` 才产生 visible plan；任一未知、抛错、普通目录、外部卷或非 APFS 都降级。
- `AppModel` 每次采用新 selection 时解析一次 plan，rescan 在本次会话复用；Debug `/` 测试入口也走生产 planner。

### 2.2 firmlink 与边界

- `RawDirectoryEntry.isFirmlink` 只来自 returned `ATTR_CMN_FLAGS & SF_FIRMLINK`。
- `NodeFlags.firmlinkProjection = 1 << 9`，SQLite flags 无需迁移。
- `DirectoryBoundaryPolicy` 为纯策略，优先级固定：mount point > firmlink > 该 projection 的一次设备转换 > 未授权设备变化 > 普通/未知。
- `enteredThroughFirmlink` 只存在于进入 projection 的目录工作项，授权其直接子项落入目标卷，不向子项继续继承。
- 该授权位进入 `DirectorySpool` 编解码，队列溢出不会丢失。
- raw `/System/Volumes/Data`、VM、Preboot、Update、模拟器 runtime、外接/网络卷等真实挂载根保留为可见边界节点，但不入队。

### 2.3 兼容与诊断

- `BoundaryPolicy.visibleStartupVolumeGroup` 的 SQLite 编码追加为 `2`，旧 0、1 不变，schema 版本仍为 v1。
- 新增 `spacejudge-volume-plan`：使用生产 enumerator/parser，只枚举根的 immediate children，输出一行路径脱敏 JSON。
- CLI 参数错误不回显未知参数内容；Codex 在首轮审查发现 positional 私密路径会进入 stderr，Pi 已按反馈修复并增加回归测试。

## 3. Codex 静态审查

审查重点及结论：

- parser FLAGS、FILEID、PARENTID 固定字段顺序正确，新增事实未改变 offset；
- mount 与 firmlink 同时为真时 mount 胜出；
- projection 授权不是扫描级全局开关，进入普通 Data 子目录后按该目录 device 继续约束；
- device unknown 不被伪造成 root/device 事实；mount 标志仍优先截断；
- spool、分页、fallback copy 和取消路径保留新增字段；
- schema 枚举只末尾追加，旧快照语义未被重编号；
- planner 不按 `/`、`Macintosh HD`、容量、固定 device ID、`/usr/share/firmlinks` 或 `diskutil` 猜测；
- CLI JSON 不含完整路径、条目名、用户名、卷 UUID、BSD disk 名或 mount-from location；
- 修复后的所有参数错误也不回显未知参数值。

没有发现剩余的阻断级或高优先级问题。

## 4. Codex 独立自动验收

独立目录：`/tmp/spacejudge-codex-phase5b.86rBRK`。所有构建均未复用 Pi scratch。

### 4.1 测试与构建

| 检查 | 结果 |
| --- | --- |
| `arch -arm64 swift test` | 377 tests / 53 suites，通过 |
| Swift Release build | 通过，无编译错误 |
| Thread Sanitizer filter | 37 tests / 3 suites，通过，无 data race 报告 |
| Xcode Debug，`CODE_SIGNING_ALLOWED=NO` | `BUILD SUCCEEDED` |
| Xcode Release，`CODE_SIGNING_ALLOWED=NO` | `BUILD SUCCEEDED` |

Xcode 仅有既有的 AppIntents metadata skipped 提示，不是 Phase 5B 编译或运行错误。

### 4.2 计划探针

真实 `/`：

```json
{
  "planKind": "visibleStartupVolumeGroup",
  "boundaryPolicy": "visibleStartupVolumeGroup",
  "isVolume": true,
  "isRootFileSystem": true,
  "fileSystemType": "apfs",
  "rootEntryCount": 21,
  "firmlinkEntryCount": 7,
  "mountPointEntryCount": 1,
  "unexpectedDeviceEntryCount": 0
}
```

新建空目录返回 `selectedFileSystem + stayOnRootFileSystem`，firmlink/mount/unexpected counts 均为 0。注意该目录的 `volumeIsRootFileSystem` 可为 true，因为它位于启动卷上；`isVolume == false` 仍使解析器正确降级。

隐私错误路径：

```text
spacejudge-volume-plan /private/Users/secret-name
exit 2
stderr: error: unexpected argument
```

stdout/stderr 不含完整路径、路径组件或用户名。

### 4.3 端到端性能

环境与 Phase 5A 同一台 M1 Max / 64 GB Mac；Release，缓存未控制。

| 场景 | 结果 |
| --- | --- |
| 100,000 mixed | scan + persist 0.704962 s；peak RSS 60,063,744 B；persisted 100,000；fdDelta 0 |
| 1,000,000 mixed | scan + persist 14.338719 s；peak RSS 243,892,224 B；persisted 1,000,000；fdDelta 0 |
| 100,000 cancel after first commit | persisted 6,000；cancel latency 21.783708 ms；fdDelta 0 |

对比 Phase 5A：10 万总耗时 0.710 s、100 万 15.203 s，没有可确认的性能回退。100 万 RSS 仍低于 250,000,000 B 工程门，但只余 6,107,776 B（约 6.1 MB）余量；后续任何每节点字段都必须重跑该门。

## 5. 真实 App 与真实启动盘抽查

通过 `NSWorkspace.OpenConfiguration.environment` 正常启动独立 Debug App，使用：

- `SPACEJUDGE_TEST_ROOT_PATH=/`
- 任务专属 SQLite 路径

扫描中 accessibility 事实：

- 当前根：`/`；
- 状态：`正在扫描`；
- 空间图可浏览，首屏可见 15 项；
- 容量：总 994.66 GB、已用 947.52 GB、剩余 47.14 GB；
- footer 使用“已扫描并归属”，未显示虚假百分比；
- 取消按钮可操作。

取消后：

- 状态变为 `已取消`；
- footer 变为 `当前范围（未完成）… · 卷内其他/未纳入 …`；
- SQLite scan header 为 `boundary_policy = 2`、`status = cancelled (3)`；
- 任务实例已按精确 PID 停止，无 App 或 scanner 进程残留。

该次取消快照持久化 1,312,065 nodes、621,828 names、178,158 directory aggregates。真实边界节点包括：

- `Data`
- `VM`
- `Preboot`
- `Update`
- `Hardware`
- `iSCPreboot` / `xarts`
- 多个 CoreSimulator runtime / cryptex mount
- `/dev`

这些节点均带 `mountBoundary` 且 direct children 为 0。与此同时 `Caches`、`Volumes`、`opt`、`cups`、`snmp` 等已识别 firmlink 节点存在真实子项，证明生产扫描既沿 projection 工作，也没有进入真实挂载卷。

本次不等待全盘扫描完成：验收目标是计划、投影、挂载截断、取消和 UI 语义，不把长时间完整系统盘扫描变成自动门。

## 6. 已知限制与下一阶段输入

### 6.1 内存余量很小

100 万 mixed RSS 为 243.9 MB，距离 250 MB 门约 6.1 MB。Phase 5C 不得为每节点增加 String、URL、完整路径或 plan 对象。

### 6.2 全盘快照体积大

真实 `/` 取消快照在约 131 万节点时，主 SQLite 已约 398 MB，另有约 2.2 MB WAL；另一次只读测试在 266 万节点时临时主库约 779 MB。它证明扫描吞吐足够，但也说明完整启动盘快照很容易达到数百 MB 至 1 GB 以上。

Phase 5C 必须明确：

- 旧 snapshot 保留数量与回收时机；
- 取消/失败/中断快照的保留策略；
- checkpoint、磁盘空间预检和“数据库自身不能落在被扫描根内”的产品保护；
- UI 中对长扫描与本地缓存占用的说明。

本阶段测试数据库全部位于任务专属 `/tmp`，不会进入被扫描的生产结果，也不会污染用户的正式 App 数据。

### 6.3 fallback 与完整度

- `ReferenceEnumerator` 无法可靠取得 bulk 的 `SF_FIRMLINK` 事实；fast path 不可用时会保守截断可能的跨设备 projection，属于 fail-closed，但可能漏扫。
- 权限拒绝、TCC、APFS clone/snapshot 和 capacity/allocated 口径差仍然存在。
- visible plan 不等于 100% 物理空间归属，UI 继续禁止显示完整度百分比或把差值叫垃圾。

## 7. 验收后状态

- [Phase 5B 实施设计](18-phase-5b-design.md)：Accepted。
- [ADR-0008](adr/0008-visible-startup-volume-group.md)：Accepted。
- Pi 报告：[Phase 5B Pi 交付报告](phase-5b-pi-report.md)。
- 未 commit、未 push、未签名、未公证、未发布。
- 下一阶段：Phase 5C，优先处理全盘 snapshot 生命周期/空间保护、权限说明和发布前恢复行为；仍不自动加入删除或 AI。
