# ADR-0005：SQLite 中用 big-endian BLOB 保存 UInt64

状态：Accepted

## 背景

领域模型使用 `UInt64` 表示标识、字节和计数；SQLite `INTEGER` 只有有符号 64 位。直接转换会在大于 `Int64.max` 时失败、截断或改变排序。

## 决策

所有领域 `UInt64` 使用固定 8 字节 big-endian BLOB。unknown 使用 SQL NULL，真实 0 使用 8 个零字节。数值聚合在 Swift 中完成；SQLite 只做精确保存和 lexicographic 排序。

## 后果

- 完整覆盖 `0...UInt64.max`，并保持 BLOB 排序与无符号数值排序一致。
- SQL 不能直接对这些列做 `SUM`，查询结果必须通过统一 codec 解码。
- schema、索引和调试工具可读性低于 INTEGER，但不会牺牲数据正确性。
