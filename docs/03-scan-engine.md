# 扫描引擎设计

状态：Accepted；Phase 5B 已完成真实 APFS 根探针、合成卷组错误注入与 Codex 独立验收。

## 1. 目标

扫描引擎负责把一个用户授权的根目录转换成增量、可取消、可对账的节点流。它不负责 UI、清理建议、删除、文件内容分析或最终配色。

## 2. 为什么不用 Foundation 递归枚举作为主路径

`FileManager` 适合正确性基线和小规模回退实现，但热路径采用 `getattrlistbulk`：一次系统调用可返回一个目录中多个条目的名称、类型、ID、时间和大小，减少逐文件 URL/`stat` 开销。

第一阶段必须同时保留 `ReferenceEnumerator`，使用简单 Foundation/POSIX 枚举构建正确性基准。优化实现和参考实现对同一夹具的规范化结果必须一致。

## 3. 请求策略

```swift
enum SizeMetric { case allocated, logical }
enum SymlinkPolicy { case doNotFollow }
enum PackagePolicy { case descend, treatAsLeaf }
enum BoundaryPolicy {
    case selectedTree
    case stayOnRootFileSystem
    case visibleStartupVolumeGroup  // Phase 5B
}
```

MVP 默认：allocated、doNotFollow、descend、stayOnRootFileSystem。包默认继续扫描，因为照片库、Xcode 归档等包经常是空间大户；UI 可把包画成带类型标识的目录。

## 4. 请求的 Darwin 属性

`getattrlistbulk` 必须请求：

- common：`ATTR_CMN_RETURNED_ATTRS`、`ATTR_CMN_NAME`、`ATTR_CMN_ERROR`、`ATTR_CMN_OBJTYPE`、`ATTR_CMN_FILEID`、`ATTR_CMN_PARENTID`、`ATTR_CMN_DEVID`、`ATTR_CMN_MODTIME`、`ATTR_CMN_FLAGS`。
- file：`ATTR_FILE_TOTALSIZE`、`ATTR_FILE_ALLOCSIZE`、`ATTR_FILE_LINKCOUNT`。
- directory：`ATTR_DIR_MOUNTSTATUS`。

解析器必须读取 `ATTR_CMN_RETURNED_ATTRS`，不能假设文件系统返回了所有请求字段。使用 `FSOPT_PACK_INVAL_ATTRS` 时也只能在 returned bitmap 声明有效后消费字段。

推荐每个 worker 复用 64–256 KiB 对齐缓冲区；最终大小由基准决定，不写死为产品假设。

## 5. 安全解析规则

属性缓冲区来自内核，但仍按不可信二进制输入处理：

- 每个 record 先验证 `length >= 4` 且没有越过本次返回缓冲区。
- 所有固定宽度读取检查剩余字节数和对齐要求。
- `attrreference_t` 的 offset 和 length 必须落在当前 record 内。
- 名称必须找到 NUL 或严格使用提供长度；转换失败时记录 issue，不崩溃。
- 不依赖 Swift struct 的默认 padding 直接绑定完整 record。
- 未返回字段使用明确的 `unknown`，不填伪造的 0。
- 每个条目的 `ATTR_CMN_ERROR` 独立上报并继续。

解析器设计为纯函数：`RawBuffer -> [RawDirectoryEntry] / ParseError`，用构造字节和截断输入做单元测试、模糊测试。

## 6. 遍历算法

1. 对根目录做权限与卷预检，建立根节点。
2. 将根目录工作项放入有界 deque。
3. worker 打开目录 FD；失败则记录目录 issue 并完成该工作项。
4. 循环调用 `getattrlistbulk` 到返回 0。
5. 每个条目生成事实记录：名称、父 ID、种类、大小、文件身份、时间、标志。
6. 对普通文件执行硬链接归属策略。
7. 对目录检查符号链接、挂载边界与取消状态，再入队。
8. 达到批次大小或时间阈值时提交 `NodeBatch`。
9. 目录枚举完成后发出 completion marker，聚合器可结算目录。
10. 工作队列与活动 worker 都归零后完成扫描。

遍历使用显式队列，不使用递归调用栈。调度优先级先 breadth-first 产生可用顶层图，再转向估计更大的目录；没有大小提示时按发现顺序。

## 7. 文件类型行为

- 普通文件：记录 logical / allocated。
- 目录：自身大小不计入子树容量，只聚合后代；可单独保留 metadata bytes 供诊断。
- 符号链接：记录链接本身，不跟随目标，不加入目录队列。
- 硬链接：以 `(deviceID, fileID)` 识别同一 inode。第一次计入 attributed bytes，后续节点标记 `duplicateHardLink` 且计量为 0；逻辑展示仍可显示文件自身大小。
- 稀疏文件：allocated 可能小于 logical，二者均保存。
- 克隆文件：公共 API 给出的 allocated 不等价于独占物理块。MVP 不承诺克隆去重，标记计量限制。
- Finder alias：按普通文件处理，不解析目标。
- package：默认当目录继续枚举，同时设置 package 标志。
- socket、FIFO、设备：记录类型，大小通常为 0，不打开。
- mount point：默认画为边界节点，不跨入其他文件系统；用户单独选择该卷时可扫描。
- firmlink：`SF_FIRMLINK` 来自 returned `ATTR_CMN_FLAGS`，只有声明返回时才读取，缺失或普通条目为 `false`，不按名称猜测。firmlink 节点以 `NodeFlags.firmlinkProjection` 标记，表示系统公开的卷组投影入口。

## 7.1 启动盘可见卷组与边界策略（Phase 5B）

现代 macOS 启动盘是只读 System volume 与可写 Data volume 组成的 APFS volume group，用户看到的是一棵由 firmlink 拼接的统一目录树。Phase 5B 只在公共 Foundation 事实明确为“volume root + root filesystem + APFS”时选择 `visibleStartupVolumeGroup`，否则降级为 `stayOnRootFileSystem`（见 ADR-0008）。

边界判定下沉为纯函数 `DirectoryBoundaryPolicy.decide(policy:rootDeviceID:currentDeviceID:childDeviceID:isMountPoint:isFirmlink:enteredThroughFirmlink:) -> DirectoryTraversalDecision`，不再堆在 coordinator 内。优先级冻结：

1. mount point 始终 boundary（即使同时带 firmlink 标记）；
2. `visibleStartupVolumeGroup` 下 firmlink 始终进入并标记；
3. 由 firmlink 进入的目录，其直接子项允许出现在投影卷上（该一次性授权由工作项的 `enteredThroughFirmlink` 携带，不向孙代继承）；
4. 明确的 child/current（或 `stayOnRootFileSystem` 下的 child/root）设备不一致为 boundary；
5. 任一侧设备未知时按普通目录继续，不伪造 ID。

`selectedTree` 保持不变，显式跨挂载。firmlink 目标是 Data 卷时，其 bulk 设备会切换；授权只限该投影入口的直接子项，之后的越界仍被截断，因此不会变成全局“允许任意跨设备”。symlink 继续不跟随，hard-link 去重继续使用 `(deviceID, fileID)`。

## 7.2 快照工作区边界（Phase 5C）

SpaceJudge 自己的快照缓存不能出现在结果里，也不能在写入时被自己重新枚举。扫描请求携带一个 session-only、有界（最多 8 个）的 `SnapshotWorkspaceExclusion` 集合，元素为规范化绝对路径、可选的 `(deviceID, fileID)` 和原因枚举。它不写入 SQLite、日志或诊断 JSON。

判定顺序：

1. 发布 `.started` 之前，若扫描根等于某个排除项或位于其内部，整个扫描以 `ScanError.scanRootInsideSnapshotWorkspace` 失败，不产生任何快照行。根与排除路径各做一次 canonical（解析符号链接）路径解析，因此根是工作区的 symlink 别名或其任意后代也会被拒绝；解析只在根预检发生，不进每节点热路径，也不记录真实路径。
2. 枚举到工作区目录时，保留该目录节点，设置 `NodeFlags.snapshotStorageBoundary = 1 << 10`，不入队、不读取其子项；它优先于 package/firmlink 决策，但不跨越真实 mount point 的既有截断语义。
3. 优先用 `(deviceID, fileID)` 匹配；事实缺失时才用规范化绝对路径做精确（按路径分量）比较，绝不能只按目录名匹配。

工作区同时承载 SQLite 与 `DirectorySpool`，因此一个边界即可覆盖数据库、WAL、SHM 和队列文件。该边界不计为权限错误，也不宣称目录大小已完整归属；它自然进入 UI 的“卷内其他/未纳入”。匹配集合只持有至多 8 个排除项，不增加每节点常驻字段。

超出排除数量上限的请求在打开根之前以 `ScanError.tooManyWorkspaceExclusions` 失败。目录 spool 的位置由 `ScanConfiguration.spoolDirectory` 指定，生产指向工作区的 `spool/` 子目录，生命周期与工作区一致。

## 8. APFS 与全盘边界

APFS 系统卷、数据卷、firmlink、快照和克隆共享会让“目录相加 = 磁盘已用”不成立。设计采用两层事实：

- 卷事实：系统容量 API报告的 total / available / used。
- 扫描归属：当前授权树中可枚举项目的 allocated bytes。

底层兼容属性提供 `unattributedBytes = max(0, volumeUsed - attributedBytes)`，同时保留 `overAttributedBytes` 诊断值，应对克隆、并发变化或不同计量口径导致 attributed 大于 used 的情况。按照 [ADR-0007](adr/0007-volume-capacity-and-scan-scope.md)，产品不得把这个算术差值直接解释为“未归属垃圾”或扫描完整度；当前 UI 使用“卷内其他/未纳入”。

全盘扫描不是核心枚举器的特殊分支，而是一个 `VolumeScanPlan`：Phase 5B 已把它实现为不可变值 `VolumeScanPlan(kind:root:boundaryPolicy:evidence:)`，其解析协议 `VolumeScanPlanning` 由 App 注入。生产实现只读 `isVolumeKey`、`volumeIsRootFileSystemKey`、`volumeTypeNameKey`（可选 `volumeIsLocalKey` 作诊断），不按 `/`、显示名、容量、固定 device number、`/usr/share/firmlinks` 或 `diskutil` 猜测。

## 9. 增量聚合

每个节点有以下计数：

- `logicalBytes`
- `allocatedBytes`
- `attributedAllocatedBytes`
- `descendantFileCount`
- `descendantDirectoryCount`
- `inaccessibleDescendantCount`
- `isComplete`

新文件批次到达后沿父链累加可能导致 O(depth × files)。实现使用目录局部累加与 completion marker：worker 为当前目录生成直接子项小计，聚合器在子目录完成时把最终值合并到父目录。UI 中间值通过脏目录集合批量发布。

## 10. 进度与速率

扫描开始前不知道总节点数，因此不显示虚假的 0–100%。实时进度包含：

- 已发现文件数 / 目录数
- 已归属字节数
- 待处理目录数
- 当前吞吐 entries/s，使用 3 秒移动窗口
- 已用时间
- 当前状态：扫描、取消中、完成、受限完成

若加载历史快照做重扫，可用上一快照的节点数给出“估计”，必须带估计标识。

## 11. 取消、错误和一致性

- 取消后不再产生新的普通 UI 批次，但必须产生一次 `cancelled` 终态。
- 用户明确取消或 shutdown 已先调用 `engine.cancel` 后，若目录 syscall 超过宽限期未返回、调用方必须强制取消 consumer task，runner 会以“Task 已取消 + 已 started + 无合法 terminal”为条件，基于最后进度与已持久化 issue 合成 `cancelled` summary 并调用 `finish(.cancelled)`，不会记为 failed。该 summary 只在 `finish` 成功后才会发布与返回；`finish` 失败时不发布 terminal、best-effort 标 failed 并抛出持久化错误。普通 store/stream 错误仍必须 failed，不得伪装成取消。`AppModel` 的取消宽限期可注入，测试不等待生产的 2 秒。
- writer 完成当前事务后标记 scan 为 cancelled，不留下 running 状态。
- 根目录无法打开是 fatal；子目录失败是 recoverable issue。
- 常见错误归类：permissionDenied、notFound、io、nameEncoding、mountBoundary、changedDuringScan、resourceLimit、unsupported。
- 扫描期间文件消失按 `changedDuringScan` 计数，不弹出逐项错误。
- 同一路径被替换时，以打开时得到的 file identity 为准。
- 每个 FD 都以作用域 guard 关闭；测试记录扫描前后进程 FD 数量。

## 12. 性能策略

- 批量属性系统调用；避免为每个项目创建 URL 和 NSDictionary。
- 节点名称以 UTF-8 byte pool / intern table 存储，路径按 parent + name 延迟构造。
- 批量 SQLite transaction，prepared statement 复用。
- 有界 worker 和 batch channel，存储或 UI 慢时产生背压。
- UI 快照合并到最多 10 Hz。
- OS signpost 分别记录 open、syscall、parse、aggregate、database、layout、draw。
- 性能优化必须以基准报告为依据，不接受仅凭代码复杂度的推断。

## 13. 回退策略

若文件系统不支持所需属性：

1. 使用 returned bitmap 识别缺失字段。
2. 对当前目录切换到 ReferenceEnumerator 或补充 `fstatat`。
3. 在扫描摘要记录 fallback 次数和受影响文件系统。
4. UI 保持工作，但性能报告不得混合为相同基准。
