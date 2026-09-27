# Phase 2 实施设计：分页枚举与 SQLite 快照

状态：Accepted（实现与独立验收见 `11-phase-2-baseline.md`）

设计日期：2026-09-26

## 1. 目标与非目标

Phase 2 把 Phase 1 的“可正确扫描”推进为“可在大目录中持续产出并可持久化查询”：

1. 单目录枚举改成 page/chunk 接口，不再一次 materialize 完整 `[RawDirectoryEntry]`。
2. 新增无第三方依赖的 `SpaceJudgeStore`，用系统 SQLite3 原子保存 scan、name、node、directory aggregate 和 issue。
3. 增加扫描事件到数据库的有背压流水线，以及明确输入路径的持久化 smoke CLI。
4. 建立 10 万/100 万节点存储基准和超宽目录分页证据。

本阶段不做 SwiftUI/AppKit、FSEvents、书签/权限 UI、历史快照清理、Finder 操作、删除、AI 或远程遥测。

## 2. 分页枚举契约

`DirectoryEnumerator` 从“返回整个目录数组”改为“创建一个独占 cursor”：

```swift
public struct DirectoryEntryPage: Sendable {
    public let entries: [RawDirectoryEntry]
    public let isLast: Bool
}

public protocol DirectoryCursor {
    mutating func nextPage() throws -> DirectoryEntryPage
}

public protocol DirectoryEnumerator: Sendable {
    func makeCursor(
        in directory: DirectoryHandle,
        request: EnumerationRequest
    ) throws -> any DirectoryCursor
}
```

命名可调整，但语义必须满足：

- cursor 只由创建它的 worker 使用，不跨 actor、不跨 worker 共享 FD、`DIR*` 或 buffer。
- worker 每取得一页就 `await` coordinator 处理；不得在 worker 中重新拼回整个目录数组。
- coordinator 处理完当前页后 worker 才读取下一页，因此事件背压和存储背压可以一路传回系统调用。
- 空的 final page 合法；非 final page 不应无故为空。
- `ReferenceEnumerator` 默认每页最多 1,024 项，测试可配置更小；`fdopendir`/`readdir` 状态跨页保留，cursor 析构关闭它拥有的 duplicate FD。
- `DarwinBulkEnumerator` 的一页对应一次 `getattrlistbulk` buffer；buffer 默认 256 KiB，cursor 生命周期内只分配一次并复用。
- 每页开始与逐条 reference 处理时检查取消；取消不得再提交普通 page/batch。
- Bulk 只允许在“尚未发布任何 bulk page”时切换 reference fallback。已经发布后再 rewind 会产生重复项，因此后续 parser/syscall 错误必须显式失败该目录或扫描，不能静默 fallback。

### 2.1 Coordinator 调整

一个 `DirectoryWorkItem` 从 cursor 创建到 final/failure 始终算一个 `inFlight`：

```text
acquire directory
  -> open FD
  -> make cursor
  -> next page
  -> coordinator.process(page)
  -> ...
  -> final page
  -> coordinator.complete(directory)
  -> close cursor / FD
```

只有 final/failure/cancel 才递减 `inFlight`。目录 node、子目录计数和 aggregate completion 仍由单一 coordinator actor 维护。分页不能改变 Phase 1 的 NodeID、NameID、hard-link 或终态语义。

## 3. Store 模块边界

新增：

```text
SpaceJudgeStore
  ├── SQLiteSnapshotRepository
  ├── SQLite writer（单 actor / 单 connection）
  ├── SQLite reader（独立只读 connection）
  ├── UInt64BlobCodec
  └── SchemaMigrator

SpaceJudgeUseCases
  └── PersistingScanRunner
```

- Store 只依赖 `SpaceJudgeDomain` 和系统 `SQLite3`，不得依赖 Scan/UI。
- UseCases 只依赖 Domain 协议，不依赖具体 SQLite/Darwin 类型。
- writer 串行执行 migration、begin、batch transaction、issue、finish/fail。
- reader 使用独立 read-only connection；WAL 下可在写入时查询已提交 batch。
- 所有 statement、connection 和 transaction 都有确定生命周期；任何 SQLite 返回码都检查，不能空 catch。

## 4. UInt64 的 SQLite 表示

SQLite `INTEGER` 是有符号 64 位，不能无损保存全部 Swift `UInt64`。本项目不允许 `UInt64 -> Int64` 截断、bitPattern 混用或把超大值静默钳位。

所有领域 `UInt64`（NodeID、NameID、revision、size、count、deviceID、fileID）保存为固定 8 字节 big-endian `BLOB`：

- 编解码必须恰好 8 字节；长度错误显式失败。
- big-endian BLOB 的 SQLite 字节序排序等价于 UInt64 数值排序。
- unknown 仍使用 SQL `NULL`，真实 0 使用 8 个零字节。
- 数值聚合在 Swift 的 overflow-safe 领域层完成，SQLite 不对 BLOB 做 `SUM`。

`UInt64BlobCodec` 必须覆盖 0、1、`Int64.max`、`Int64.max+1`、`UInt64.max` 的 round-trip 和排序测试。

## 5. Schema v1

Schema 使用 `PRAGMA user_version = 1`。SQL 名称可微调，但以下事实与约束不可丢失：

```sql
CREATE TABLE scans (
  id TEXT PRIMARY KEY,
  root_display_name TEXT NOT NULL,
  root_file_system_id BLOB,
  root_node_id BLOB NOT NULL,
  size_metric INTEGER NOT NULL,
  boundary_policy INTEGER NOT NULL,
  package_policy INTEGER NOT NULL,
  symlink_policy INTEGER NOT NULL,
  started_at REAL NOT NULL,
  finished_at REAL,
  status INTEGER NOT NULL,
  total_capacity BLOB,
  available_capacity BLOB,
  capacity_source INTEGER,
  last_revision BLOB NOT NULL,
  root_attributed_bytes BLOB NOT NULL,
  file_count BLOB NOT NULL,
  directory_count BLOB NOT NULL,
  inaccessible_count BLOB NOT NULL,
  issue_count BLOB NOT NULL,
  schema_version INTEGER NOT NULL
);

CREATE TABLE names (
  scan_id TEXT NOT NULL,
  id BLOB NOT NULL,
  utf8 BLOB NOT NULL,
  PRIMARY KEY (scan_id, id),
  UNIQUE (scan_id, utf8),
  FOREIGN KEY (scan_id) REFERENCES scans(id) ON DELETE CASCADE
) WITHOUT ROWID;

CREATE TABLE nodes (
  scan_id TEXT NOT NULL,
  id BLOB NOT NULL,
  parent_id BLOB,
  name_id BLOB NOT NULL,
  kind INTEGER NOT NULL,
  flags INTEGER NOT NULL,
  logical_bytes BLOB,
  allocated_bytes BLOB,
  attributed_bytes BLOB NOT NULL,
  modified_at REAL,
  device_id BLOB,
  file_id BLOB,
  PRIMARY KEY (scan_id, id),
  FOREIGN KEY (scan_id) REFERENCES scans(id) ON DELETE CASCADE,
  FOREIGN KEY (scan_id, name_id) REFERENCES names(scan_id, id)
) WITHOUT ROWID;

CREATE INDEX nodes_by_parent
ON nodes(scan_id, parent_id, attributed_bytes DESC, id ASC);

CREATE TABLE directory_aggregates (
  scan_id TEXT NOT NULL,
  node_id BLOB NOT NULL,
  logical_bytes BLOB NOT NULL,
  allocated_bytes BLOB NOT NULL,
  attributed_bytes BLOB NOT NULL,
  descendant_file_count BLOB NOT NULL,
  descendant_directory_count BLOB NOT NULL,
  inaccessible_descendant_count BLOB NOT NULL,
  is_complete INTEGER NOT NULL,
  PRIMARY KEY (scan_id, node_id),
  FOREIGN KEY (scan_id, node_id) REFERENCES nodes(scan_id, id) ON DELETE CASCADE
) WITHOUT ROWID;

CREATE TABLE issues (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  scan_id TEXT NOT NULL,
  node_id BLOB,
  category INTEGER NOT NULL,
  errno_value INTEGER,
  sample_name_id BLOB,
  count BLOB NOT NULL,
  FOREIGN KEY (scan_id) REFERENCES scans(id) ON DELETE CASCADE
);
```

父节点可能晚于子文件发布，因此 `nodes.parent_id` 本阶段不加自引用 foreign key。扫描完成后用完整性查询验证：除 root 外每个非空 parent 都存在。

数据库只保存 `displayName`，不保存 `ScanRoot.fileSystemPath`；bookmark 留待权限设计阶段。

## 6. 写入与状态机

连接初始化：

```text
PRAGMA journal_mode=WAL
PRAGMA synchronous=NORMAL
PRAGMA foreign_keys=ON
PRAGMA busy_timeout=5000
```

- `begin(metadata)` 插入唯一 `running` scan；同 ID 重复 begin 失败。
- `write(batch)` 是单个事务：names -> nodes -> aggregate -> last_revision。
- batch revision 必须与已保存 revision 连续；重复、倒退、跳号全部 rollback。
- 同一 NameID 只能对应同一 bytes；同一 NodeID 不允许被覆盖。
- directory aggregate 使用 upsert，但 complete 之后不得回退或改变。
- `record(issue)` append issue event；查询时按 category/errno/sample 聚合 count。
- `finish(summary)` 只允许 `running -> completed/cancelled`，scanID 必须一致。
- `fail(scanID)` 只允许 `running -> failed`。
- repository 打开时把遗留 `running` 更新为 `interrupted`，不得当作完成快照。
- store 错误导致当前 batch 整体 rollback；不得留下 name 成功、node 失败的半批数据。

`SnapshotRepository` 协议补充 issue 与 fail 方法。现有内存 stub 同步更新。

## 7. PersistingScanRunner

Runner 顺序消费 `ScanEngine`：

```text
started   -> repository.begin
batch     -> repository.write
issue     -> repository.record
progress  -> 不持久化
completed/cancelled -> repository.finish
stream error after started -> repository.fail
```

每次数据库写入都被 await，因此 SQLite 慢时会通过 bounded stream 反压扫描器。repository 写失败时，runner 取消对应 scan、尝试标记 failed，并把原始错误交给调用方；不能继续扫描并假装已持久化。

## 8. 查询契约

MVP 本阶段至少实现：

- `children(of:in:)`：按 attributed BLOB DESC、NodeID ASC。
- `name(id:in:)`：原始 bytes，无效 UTF-8 不丢失。
- `aggregate(of:in:)`。
- `ancestors(of:in:)`：返回 root -> current，检测缺父节点和循环。
- scan 状态/summary。
- issue summary。

查询只返回领域值，不暴露 SQLite statement、rowid 或 connection。

## 9. Smoke 与基准

新增 `spacejudge-persist-smoke`：

```text
spacejudge-persist-smoke --engine reference|bulk --database <new-db-path> <directory>
```

- 只扫描明确传入目录，只写明确数据库路径。
- stdout 输出稳定 JSON：status、file/directory/issue count、root attributed、persisted node/name/aggregate count、root child count、database bytes。
- 不输出绝对扫描路径；错误与进度到 stderr；输入错误和扫描/存储错误退出码可区分。

新增可重复 store benchmark（CLI 或测试辅助），至少支持 100,000 与 1,000,000 synthetic nodes，记录 Release 写入 wall time、nodes/s、数据库/WAL 大小、直接子查询 p95 和峰值 RSS。性能未达门槛要报告真实数字，不能缩小规模伪装通过。

## 10. 测试矩阵

### 分页扫描

- Reference page limit=1/7/128，规范树与旧 Phase 1 基线一致。
- Bulk 多 buffer page，与 reference canonical diff 一致。
- 10,000+ 同级 synthetic entries，观测最大 page 不超过配置/固定 buffer 上限，不出现全目录数组。
- 第 1 页前 fallback 无重复；已发布一页后的失败不能 rewind 产生重复。
- page 间 cancel、cursor failure、consumer termination，终态/FD/spool 正确。

### Store

- UInt64 BLOB 全域边界与排序。
- schema 创建、`user_version`、重开、WAL 与 foreign key。
- begin/write/issue/finish/fail/interrupted 状态机。
- batch 原子 rollback、revision 重复/跳号、NameID 冲突、NodeID 冲突。
- unknown/0 round-trip、invalid UTF-8、hard-link flags、aggregate complete。
- children 排序、ancestor、issue summary、查询计划命中 `nodes_by_parent`。
- 多次打开关闭后 statement/connection/FD 回基线。
- writer 与 reader 并发：写入未提交数据不可见，提交后可见且不阻塞到 busy timeout。

### 端到端

- reference 与 bulk 对同一 fixture 持久化到两个数据库，规范化查询结果一致。
- store 写失败会取消 scan 并留下 failed，而不是 completed。
- 取消扫描得到 cancelled snapshot；stream fatal 得到 failed/interrupted。

## 11. Phase 2 验收门

- Phase 1 的 123 项测试全部继续通过。
- Debug/Release build 无 warning、无第三方 package 依赖。
- 新分页和 Store 测试稳定；真实临时目录双引擎持久化结果一致。
- 1,000,000 synthetic node benchmark 完成且无 OOM；先记录基线，不以单一机器数字作为营销承诺。
- 无遗留 DB/WAL/SHM、spool、后台进程或 FD 泄漏。
- HTML 原型、只读 MVP 边界和 Phase 1 冻结语义不变。

通过后新增 `11-phase-2-baseline.md`，再决定是否进入原生应用壳。

## 12. 实现记录（与设计一致的细节）

本节只记录实现时的具体命名与测试接缝，不改变上面的语义。

- `DirectoryCursor` 的具体实现（`ReferenceCursor`、`BulkCursor`）是 final class；协议保持 `mutating func nextPage()`。`nextPage()` 在 final page 之后幂等返回空 final page，`deinit` 关闭 `DIR*`/释放 buffer。
- `DarwinBulkEnumerator` 增加 internal `bulkRead`/`parsePage` 注入接缝，仅用于确定性验证“已发布 page 后不得 fallback 回退”；生产 init 默认绑定系统 `getattrlistbulk` 与 `DarwinAttributeBufferParser`。
- 查询结果值类型放在 `SpaceJudgeDomain`：`ScanSnapshotState`、`ScanSnapshotSummary`、`IssueAggregateSummary`、`SnapshotStatistics`，因此 UseCases 与 CLI 不依赖 SQLite 类型。
- `SQLiteSnapshotRepository.init(path:)` 打开 writer + read-only reader 两个连接并在打开时把遗留 `running` 标为 `interrupted`；`openReadOnly(path:)` 提供只读视图；`close()` 显式释放两个连接。
- `SnapshotRepository` 新增 `record(_:)`、`fail(scanID:)`、`name(id:in:)`、`aggregate(of:in:)`、`ancestors(of:in:)`、`scanState(_:)`、`scanSummary(_:)`、`issueSummary(_:)`、`statistics(_:)`。
- `PersistingScanRunner.run(_:)` 返回终态 `ScanSummary`，自身违约抛 `PersistingScanRunnerError`；engine/store 错误原样重抛。
- 基准可执行文件名为 `spacejudge-store-bench`；持久化 smoke 为 `spacejudge-persist-smoke`，退出码 2 输入、3 扫描、4 存储。
