# Phase 1 实施设计：真实扫描器

状态：Accepted（实现与独立验收见 `09-phase-1-baseline.md`）

## 1. 阶段目标

把用户授权的真实目录转换成 Phase 0 已定义的增量事件流，建立两条行为一致的扫描路径：

- `ReferenceEnumerator`：优先正确、容易审查，用于差分基线与 fast path 回退。
- `DarwinBulkEnumerator`：使用 `getattrlistbulk` 批量读取目录条目元数据。

本阶段不做 SQLite、应用 UI、全盘 APFS 卷组计划、FSEvents、清理或 AI。

## 2. Phase 0 契约补充

当前 `NodeRecord` 只有 `NameID`，扫描批次还必须携带名字事实；目录最终大小也不能伪装成初次发现时的 immutable node fact。因此增加：

```swift
public struct NameRecord: Sendable, Equatable, Hashable, Codable {
    public let id: NameID
    public let utf8: Data
}

public struct DirectoryAggregateRecord: Sendable, Equatable, Hashable, Codable {
    public let nodeID: NodeID
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    public let attributedBytes: UInt64
    public let descendantFileCount: UInt64
    public let descendantDirectoryCount: UInt64
    public let inaccessibleDescendantCount: UInt64
    public let isComplete: Bool
}

public struct NodeBatch: ... {
    public let scanID: ScanID
    public let revision: Revision
    public let names: [NameRecord]
    public let nodes: [NodeRecord]
    public let directoryAggregates: [DirectoryAggregateRecord]
}
```

规则：

- `NameID` 在一次扫描内唯一；每个新 ID 必须在第一次被 node 引用的同一批或更早批次出现。
- 名称保存文件系统返回的 UTF-8 bytes，不保存重复完整路径。
- 无法构成有效 UTF-8 的名字产生 `nameEncoding` issue；MVP 可使用损失替换显示，但原始 bytes 仍保留。
- node facts append-only；directory aggregate 按 `(scanID,nodeID)` upsert，revision 递增。
- complete aggregate 一经发出不可回退、不可再次变化。

## 3. 内部扫描层

```text
FileSystemScanEngine (actor)
  ├── DirectoryEnumerator protocol
  │     ├── ReferenceEnumerator
  │     └── DarwinBulkEnumerator
  ├── ScanScheduler（有界目录队列）
  ├── NameInterner
  ├── NodeIDAllocator
  ├── HardLinkAttributor
  ├── DirectoryAggregateBuilder
  └── BatchEmitter
```

Enumerator 只枚举一个目录，不管理全局树：

```swift
protocol DirectoryEnumerator: Sendable {
    func entries(
        in directory: DirectoryHandle,
        request: EnumerationRequest
    ) throws -> [RawDirectoryEntry]
}
```

真实实现可以用 callback / sequence 降低临时数组，但必须保留可注入协议，让错误、取消和顺序测试不依赖真实磁盘。

## 4. Darwin 请求与解析

请求属性：

- common：`RETURNED_ATTRS`、`NAME`、`ERROR`、`OBJTYPE`、`DEVID`、`FILEID`、`PARENTID`、`MODTIME`、`FLAGS`。
- file：`TOTALSIZE`、`ALLOCSIZE`、`LINKCOUNT`。
- directory：`MOUNTSTATUS`。

调用使用 `FSOPT_PACK_INVAL_ATTRS`，并始终检查 returned bitmap；默认值只能用于推进 buffer，不能当成真实事实。

解析必须满足：

- record 的首个 `UInt32 length` 合法且不越过本次 buffer。
- 按 Darwin 规定顺序和 4-byte packing 读取，不把未对齐内存直接 bind 成 Swift struct。
- `attrreference_t` 的 data offset 相对于 reference 自身；offset、length 和 NUL 都必须落在当前 record 内。
- `ATTR_CMN_ERROR` 是条目级错误，记录 issue 后继续下一条。
- returned bitmap 未声明的值映射为 unknown，不映射为 0。
- 名字按明确长度解码，不使用无界 `String(cString:)`。`ATTR_CMN_NAME` 的 `attr_length` 必须包含终止 NUL，最后一个字节必须是 NUL，终止 NUL 之前不得出现 interior NUL。
- name 数据必须完整落在当前 record 内，且起始位置不得早于本 record 所有固定字段解析完成后的 cursor（不允许回指 header / `attrreference` / 任一固定字段）。
- 任意截断、超长、负 offset、无 NUL、interior NUL、name 与固定字段重叠、非法 UTF-8 或 record 数不匹配都返回可测试的 parser error，不崩溃。

Parser 应是独立纯类型，可直接接收 `Data` / raw bytes 做单元与 fuzz 测试；系统调用封装不参与解析器单元测试。

## 5. 文件类型与计量

- 普通文件：logical 来自 total size，allocated 来自 allocation size。
- Reference 路径允许用 `lstat` 的 `st_size` 与 `st_blocks * 512`，差分测试要说明 resource fork 口径可能不同。
- 目录：初始 node 自身 attributed 为 0；最终数字来自 aggregate。
- symlink：使用 link 自身属性，不进入队列。
- hard link：`linkCount > 1` 时按 `(deviceID,fileID)` 去重；第二次及以后设置 duplicate flag、attributed=0。
- sparse：allocated < logical 时设置 sparse flag。
- package：默认 `.descend`；`.treatAsLeaf` 允许仅在该策略启用时调用较慢的 Foundation package 判断。
- mount point：`.stayOnRootFileSystem` 下记录 boundary node，不跨入；`.selectedTree` 可继续，但仍不跟随 symlink。
- socket / FIFO / device：记录种类，不打开内容。

所有系统有符号整数先验证非负，再转 `UInt64`；reference 的 `st_blocks * 512` 使用 reporting overflow，不可表示时作为 unknown 而不是 wrap。归属必须区分三种状态：`known`（allocated 已知且 candidate<=allocated）、`unknown`（`allocated == nil`，合法的不完整事实：发布 `allocatedBytes=nil, attributedBytes=0`，计入 file/logical aggregate，不发 issue，不 claim identity）、`invalid`（known allocated 但 candidate>allocated：发 issue，不发布 NodeRecord、不进聚合、不 claim identity）。先验证原始 sizes，再做 hard-link claim，避免 unknown/invalid 项污染后续合法项的首次归属。计数/聚合 overflow 是明确的 fatal error，不饱和、不伪装为 0；progress 计数与 scan revision 也使用 reporting overflow。

## 6. 调度、背压与事件

- `FileSystemScanEngine` 是 actor；同一实例可拒绝重复 scanID。
- 显式有界队列；`maximumQueuedDirectories` 是内存队列的硬上限，不是软提示。默认并发不超过 `min(4, activeProcessorCount)`，测试可配置为 1。
- 内存队列满时，溢出的 `DirectoryWorkItem` 进入扫描私有的长度前缀临时磁盘 spool；spool 只保存 `nodeID`、可选 parent/device、路径 bytes 和 root 标记，绝不序列化 FD。正常完成、取消和 fatal error 都 RAII 关闭并 unlink spool。spool 创建/读写/解码失败是明确的 fatal error，不得漏项；`pread`/`pwrite` 对 `EINTR` 原地重试，offset/count 算术使用 reporting overflow。
- 完成诊断（frontier high-water、spool 使用）是测试用 per-scan 一次性记录，读取即删除；即使无人读取也只保留最近 64 条，不随扫描次数无界增长。
- 已知限制：单个目录仍会一次性 materialize 完整的 `[RawDirectoryEntry]`。因此“目录 frontier 已有硬上限”不等于“整个扫描内存完全有界”；单目录分页留待后续阶段。
- 每个 worker 独占目录 FD 和 64–256 KiB buffer。
- 不创建“每个目录一个 Task”。
- Batch 默认最多 2,000 nodes 或 50 ms 刷新一次，以先到为准。
- Stream continuation 设置 `bufferingOldest` 有界策略。缓冲区满时生产者使用真实背压：持续重试直到 `.enqueued` 或 `.terminated`，不因缓冲满而丢弃 NodeBatch/NameRecord/aggregate；消费者终止或扫描取消后能退出。
- UI 事件最终会再节流；本阶段 emitter 只保证批次，不保证 10 Hz UI 节流。
- NodeID / NameID 分配、hard-link claim、aggregate completion 在单一 actor 隔离域内完成。
- 扫描顺序不作为 API 保证；测试用相对路径规范化比较。

## 7. 取消与终态

- `cancel(scanID:)` 设置扫描级取消状态并取消 worker group。
- consumer 终止 stream 时触发相同取消路径。
- 系统调用返回、每批解析结束、目录入队前都检查取消。
- 取消后不再发普通 batch/progress/issue；未发布的 pending 缓冲被丢弃，只发一次 `cancelled(summary)` 后 finish。cancelled terminal 自身不因普通 cancellation 状态被跳过。
- 终态决策在开始 await 终态投递前原子锁定；之后的 `cancel` 是 no-op。cancel 先到则只能 cancelled，completed 决策先到则只能 completed；两种路径都恰好一个终态，summary status 与事件一致。
- consumer 主动终止 stream 时 continuation 已 terminated，扫描可直接结束而不要求消费者收到 terminal。
- 正常路径只发一次 `completed(summary)`。
- 根目录打不开可用 stream error 结束；子目录错误发 issue 并继续。
- 每个打开成功的 FD 都由小型 RAII wrapper 管理，任何 throw / cancel 路径都关闭。

## 8. Reference / Bulk 差分标准

对同一个静态临时 fixture 收集完整事件，构建 canonical rows：

```text
relative path
kind
logical bytes
allocated bytes
deviceID + fileID
duplicateHardLink
sparse
mountBoundary
```

忽略 NodeID、NameID、批次边界和发现顺序。目录 aggregate 比较最终 attributed、文件/目录计数和 complete。口径差异必须明确 allowlist，不能简单设百分比误差。

## 9. 测试矩阵

### Parser

- 正常 file / directory / symlink。
- returned bitmap 缺字段。
- 条目 error。
- 多 record 和可变长名称。
- 截断 length、0 length、record 越界。
- name offset 越界、length 越界、无 NUL、非法 UTF-8。
- 至少 10,000 个固定 seed 随机 bytes；不得 crash / trap / 越界。

### 真实临时目录

- 嵌套、空目录、隐藏文件、Unicode 名称。
- symlink loop，确认不跟随。
- 两个 hard links，只归属一次。
- sparse file，logical > allocated。
- 扫描中删除 / 重命名。
- 取消：大量待处理目录，终态只有一次。
- Reference 与 Bulk canonical 结果一致。
- 重复扫描后进程 FD 数回到基线；容差必须解释。

权限拒绝若在当前测试身份下无法稳定构造，使用可注入 enumerator 精确测试 error mapping，不通过更改用户目录权限实现。

## 10. 本阶段 CLI

新增 `spacejudge-scan-smoke`：

- 参数：`--engine reference|bulk <directory>`，仅扫描用户明确传入的位置。
- stdout：稳定 JSON summary，包括状态、计数、root aggregate 和 issue 分类；默认不输出绝对路径。
- stderr：进度 / 错误。
- 支持 SIGINT 或超时取消。
- 仅用于工程验收，不作为产品 UI。

## 11. 完成门槛

- `arch -arm64 swift test` 退出 0，无 warning。
- Debug 与 Release build 通过。
- 两种 enumerator 对真实 fixture 差分通过。
- CLI 用 reference / bulk 扫描同一 fixture，summary 一致。
- parser fuzz 通过。
- 取消、条目错误和根错误均有测试。
- 重复扫描无 FD 增长。
- 没有第三方依赖，没有修改 HTML / UI 原型。
