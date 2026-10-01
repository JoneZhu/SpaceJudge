# ADR 0013：取消时补齐目录身份的包内旁路

状态：Accepted（Pi实现，Codex独立测试与最终原生Release验收通过；见文档37）

## 背景

扫描被取消时，`ScanCoordinator` 会丢弃尚未完成自身枚举的目录身份
（`pendingDirectoryNodes`）。已经提交到 SQLite 的文件其 `parentID` 可能指向这些从未
持久化的目录，于是根的有界 child 页为空、祖先/名字链无法解析，取消后的已提交结果
不可浏览。完整扫描路径没有这个问题，因为它会在每个目录自身枚举完成时发布其节点。

## 决策

新增一个**仅本 Swift package 可见**（`package` 访问级别）的终态持久化旁路，不改动
`ScanEvent`、`ScanSummary`、公开 schema、CLI/MCP 输出或 SQLite 编码：

- `CancelledDirectoryCheckpoint`：只包含目录 `NodeRecord` 与其仍需的 `NameRecord`。
  不含 aggregate、面积或任何伪造权重。
- `CancelledCheckpointProviding`：可选协议，`takeCancelledCheckpoint(scanID:)` 一次性
  消费；未实现该协议的引擎保持原有路径不变。

引擎侧：

- 只在取消分支（普通取消与 flush 后的取消）构建 checkpoint：取 `pendingDirectoryNodes`
  中目录身份，加 `pendingNodes` 中尚未发布的目录记录，再加被取消抑制的在飞 flush 批次
  里的目录记录与名字。已发布的目录不会被重复放入（`duplicateNodeID` 仍会被 Store 拒绝）。
- checkpoint 存在 `CoordinatorRegistry` 的**单一最新槽**；新扫描开始时清空，完成/失败
  不留槽。引擎清理不会在 runner 取到之前丢弃它。

Runner 侧：

- 在持久化 `cancelled` 终态之前，若引擎实现了可选协议，则以**自身最后真正收到的
  revision + 1** 写入一个有界批次（目录身份），不发布任何普通 `onUpdate`。引擎可能因
  被抑制的 flush 递增过自己的 revision，因此绝不使用引擎计数。
- 取消 checkpoint 写入失败时，绝不发布数据库无法背书的 `cancelled` 终态：走既有失败
  路径，best-effort `fail` 后重新抛出。收到过终态事件但持久化失败时，也不会被“合成取消”
  路径掩盖。

取消目录自身的 aggregate 仍未知/未完成，不伪造 complete 或可释放空间；后代已提交叶子
进入后可正常显示其权重。

## 备选方案

- **在发现目录时就发布节点**：会让后续的 EACCES 等最终 failure flags 无法修正，违反
  “flags 必须最终”的要求，否决。
- **在 runner 里为每个缺失祖先单独查询**：会把取消路径变成对树的无界读取，且无法覆盖
  被丢弃的目录身份，否决。
- **加公开 schema 字段或 CLI 字段**：破坏公开接口兼容，否决。

## 影响

- 取消后已提交节点可沿真实目录链浏览；完整/失败扫描路径不增加每节点 ledger 或常驻副本
  （checkpoint 仅在取消分支产生且一次性消费）。
- 兼容性：旧的 `ScanEngine` 实现不受影响；公开 API、schema 与 CLI/MCP 输出不变。
