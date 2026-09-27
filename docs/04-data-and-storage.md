# 数据、计量与持久化

状态：Accepted；当前 schema v1、计量与 Phase 5B 卷组边界语义已验收。

## 1. 标识

- `ScanID`：每次扫描的 UUID。
- `NodeID`：扫描内单调递增 `UInt64`，用于紧凑父子关系。
- `FileIdentity`：`deviceID + fileID`，用于一次扫描内硬链接识别，不承诺跨重启持久。
- `Revision`：增量快照和 treemap 布局的单调序号。

路径不是身份。节点只存 `parentID + name`，需要时通过祖先链解析并缓存。

## 1.1 边界策略与投影标志（Phase 5B）

- `BoundaryPolicy` 在末尾追加 `visibleStartupVolumeGroup`，其 SQLite 编码固定为 `2`；旧值 `selectedTree = 0`、`stayOnRootFileSystem = 1` 的含义不变，schema 版本仍为 v1，不升级表结构。未知编码值仍拒绝。
- `NodeFlags` 在现有 bit 尾部追加 `firmlinkProjection = 1 << 9`（Phase 5B）与 `snapshotStorageBoundary = 1 << 10`（Phase 5C），表示系统公开的卷组投影入口和 SpaceJudge 自身快照工作区边界。`nodes.flags` 仍按整数保存，无需迁移，旧 bit 含义不变。
- `VolumeScanPlan` / `VolumeScanPlanEvidence` 是纯值类型，只保存公开、非敏感的卷属性；`nil` 表示未知，绝不伪造成 `false`。plan 不保存完整用户路径以外的内容（`ScanRoot.fileSystemPath` 仍是 session-only），不保存卷 UUID、BSD disk 名或 mount-from location。

## 2. 领域模型

```swift
struct NodeRecord: Sendable, Equatable {
    let id: NodeID
    let scanID: ScanID
    let parentID: NodeID?
    let name: NameID
    let kind: NodeKind
    let flags: NodeFlags
    let logicalBytes: UInt64?
    let allocatedBytes: UInt64?
    let attributedBytes: UInt64
    let modifiedAt: Date?
    let deviceID: UInt64?
    let fileID: UInt64?
}
```

`NodeFlags` 已知 bit：`package`、`duplicateHardLink`、`inaccessible`、`mountBoundary`、`sparse`、`changedDuringScan`、`symlinkLoop`、`clonedAllocation`、`fallbackEnumerator`、`firmlinkProjection`（Phase 5B）。

所有字节使用无符号 64 位。来自系统的有符号值必须先验证非负与溢出，再转换。未知与真实 0 必须区分。

## 3. SQLite schema 草案

```sql
CREATE TABLE scans (
  id TEXT PRIMARY KEY,
  root_display_path TEXT NOT NULL,
  root_bookmark BLOB,
  started_at REAL NOT NULL,
  finished_at REAL,
  status INTEGER NOT NULL,
  total_capacity INTEGER,
  available_capacity INTEGER,
  attributed_bytes INTEGER NOT NULL DEFAULT 0,
  file_count INTEGER NOT NULL DEFAULT 0,
  directory_count INTEGER NOT NULL DEFAULT 0,
  issue_count INTEGER NOT NULL DEFAULT 0,
  schema_version INTEGER NOT NULL
);

CREATE TABLE names (
  id INTEGER PRIMARY KEY,
  utf8 BLOB NOT NULL UNIQUE
);

CREATE TABLE nodes (
  scan_id TEXT NOT NULL,
  id INTEGER NOT NULL,
  parent_id INTEGER,
  name_id INTEGER NOT NULL,
  kind INTEGER NOT NULL,
  flags INTEGER NOT NULL,
  logical_bytes INTEGER,
  allocated_bytes INTEGER,
  attributed_bytes INTEGER NOT NULL,
  modified_at REAL,
  device_id INTEGER,
  file_id INTEGER,
  is_complete INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (scan_id, id)
) WITHOUT ROWID;

CREATE INDEX nodes_by_parent
ON nodes(scan_id, parent_id, attributed_bytes DESC);

CREATE TABLE issues (
  scan_id TEXT NOT NULL,
  node_id INTEGER,
  category INTEGER NOT NULL,
  errno_value INTEGER,
  count INTEGER NOT NULL DEFAULT 1,
  sample_name_id INTEGER,
  PRIMARY KEY (scan_id, category, errno_value, sample_name_id)
);
```

路径书签含用户授权信息，只在确有“记住此位置”功能时保存，并放在应用容器数据库中。诊断导出默认不包含 bookmark 和完整路径。

## 4. 写入策略

- `PRAGMA journal_mode=WAL`，`synchronous=NORMAL`；崩溃恢复测试通过后采用。
- 单 writer connection，prepared statement。
- 每 5,000 节点或 50 ms 提交一次，基准后调优。
- scan 行先写 `running`；正常结束、取消、失败都必须转终态。
- 启动时发现遗留 `running`，标记为 `interrupted`，不当作完成快照。
- 保存最近若干快照由产品策略决定；Phase 5C 起冻结为“单会话、单扫描缓存”（[ADR-0009](adr/0009-session-snapshot-cache.md)）：
  - `begin` 先检查/写入，随后在同一个事务中级联删除所有旧 `scans` 行（names/nodes/directory_aggregates/issues 随之消失）。任意时刻数据库只有一个 `ScanID`。
  - 删除发生在新扫描真正发出 `.started` 后；取消、失败后的当前快照保留到下一次 `begin` 或 App 下次启动。
  - 新库在建表之前设置 `PRAGMA auto_vacuum=INCREMENTAL`（schema 仍为 v1）；同一会话再次扫描时，旧扫描释放的页优先复用，避免文件随扫描线性增长。
  - 不执行普通 `VACUUM`。终态与正常关闭做有界 `wal_checkpoint(TRUNCATE)`（被活跃 reader 阻塞时退化为 `PASSIVE`）和单次页数上限的 `incremental_vacuum`。

### 4.1 空间保护（Phase 5C）

- 开始门：写新 header 前要求缓存卷“重要用途可用空间 + SQLite 可复用空闲页”至少 512 MiB；
- 运行门：每次持久化批次提交前要求有效可用空间至少 256 MiB；
- `effectiveAvailable = saturatingAdd(volumeAvailableForImportantUsage, pageSize × freelistCount)`，所有乘加检查溢出并饱和；WAL/SHM 已反映在卷可用量中，不重复相减；
- 容量事实无法取得时拒绝开始/继续，不把 unknown 当 0；SQLite 自身返回 `SQLITE_FULL`/`SQLITE_IOERR` 仍按存储失败终止；
- 生产 `VolumeStorageCapacityProvider` 对 Foundation 卷查询使用一个短 TTL 缓存，使长时间扫描不会因每批系统级查询而累积常驻内存；注入的测试 provider 不缓存，边界测试仍然即时。

## 5. 查询模式

UI 核心查询：

- 某节点的直接子项，按 attributed bytes 降序。
- 从节点到根的祖先链，用于面包屑。
- 节点详细信息和聚合计数。
- 扫描 issue 汇总。

不在 SQLite 中预计算每个可能层级的 treemap。布局按当前焦点的有限可见子树生成，并带缓存。

## 6. 快照模型

`ScanViewSnapshot` 只包含 UI 当前需要的数据：

- scan 状态与 revision
- 容量计量与来源
- 当前焦点祖先链
- 当前层级与可展开子节点
- 进度和 issue 摘要

Snapshot 是不可变、Sendable 的。UI 不观察数据库行，也不接收完整百万节点数组。

## 7. 容量 API 与隐私

卷容量优先读取：

- `volumeTotalCapacity`
- `volumeAvailableCapacityForImportantUsage`
- fallback：`volumeAvailableCapacity`

记录 `capacitySource`，保证 UI 和测试知道数字来源。使用 required-reason API 时，应用必须配置 Privacy Manifest，不把容量与设备身份、账号或遥测结合用于指纹识别。

## 8. 数据迁移

- Schema 版本放在数据库 `user_version` 和 scan 记录中。
- 迁移必须在事务内执行，失败时保留旧库并创建错误报告。
- 开发阶段允许删除测试数据库，但不能静默删除用户快照。
- 每次 schema 变化增加 fixture DB 的前向迁移测试。

## 9. 数值不变量

- `attributedBytes <= allocatedBytes` 对普通唯一文件成立。
- `duplicateHardLink` 节点的 attributed 为 0。
- 已完成目录的 attributed 等于直接文件 attributed 与已完成子目录 attributed 之和。
- `volumeUsed = total - available`，当两者都已知且 total >= available。
- `unattributed = max(0, volumeUsed - rootAttributed)` 是底层算术不变量；其产品解释遵守 ADR-0007，目录扫描时包含范围外数据，不表示可清理空间。
- 任意加法必须检测 UInt64 overflow；异常记录 issue 并停止污染聚合。

## 10. 受管快照工作区（Phase 5C）

`SnapshotWorkspace`（`SpaceJudgeAppSupport`）管理缓存路径与文件生命周期，不涉及扫描业务：

- 生产根为 Foundation 返回的 `<user Caches>/SpaceJudge`；用不跟随的 `lstat` 校验根：symlink 根、非目录、类型或权限不可确认均 fail-closed，绝不被跟随或枚举。目录权限目标 `0700`，只在现有权限更宽松时收紧；权限属性不可读或不可写时报错而不静默成功。
- 白名单成员：`snapshots.sqlite`、`snapshots.sqlite-wal`、`snapshots.sqlite-shm`、`spool/spacejudge-spool-<UUID>.bin`。受管三件套在建库前以 `0600` 预创建（使 SQLite 采用而非自行创建 WAL/SHM），打开后再收紧；成员已存在但不是普通文件时 fail-closed。spool 文件新建时为 `0600`。
- 启动清理分两阶段：先校验全部成员，再删除。遇到符号链接、未知文件名、非 `spool` 子目录或删除失败都以 `SnapshotWorkspaceError` fail-closed 并拒绝 bootstrap；校验先于删除，因此不会被部分删除留下模糊范围。
- 正常关闭只做到有界 checkpoint/回收，实际文件到下次启动才回收；不在退出过程中删除用户仍在浏览的快照。
- 错误与日志不包含绝对路径、用户名或所选根的完整路径。

存储错误新增可区分、无路径的 `storageCapacityUnavailable` 与 `insufficientStorage(requiredBytes:availableBytes:)`；`scanRootInsideSnapshotWorkspace` 与 `unsafeWorkspaceEntry` 分别位于扫描与工作区层。UI 把低空间映射为“可用空间过少……”，把选择缓存映射为“不能扫描 SpaceJudge 自己的工作缓存……”。
