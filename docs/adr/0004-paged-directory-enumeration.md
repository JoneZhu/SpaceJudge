# ADR-0004：目录枚举按页交付

状态：Accepted

## 背景

Phase 1 已限制目录 frontier，但单个超宽目录仍一次返回完整数组。十万到百万个同级条目会绕过 frontier 上限并造成峰值内存增长，也无法把下游背压传回系统调用。

## 决策

`DirectoryEnumerator` 创建 worker 独占 cursor；每次只返回一个有界 page。worker 等 coordinator 处理当前 page 后才读取下一页。Reference cursor 保留 `readdir` 状态，Bulk cursor 复用一个 `getattrlistbulk` buffer。

Bulk 只允许在任何 page 尚未发布前 fallback；发布后不能 rewind，否则会重复事实。

## 后果

- 单目录内存从 O(目录条目数) 降为 O(page + batch)。
- cursor/FD 生命周期变长到目录完成，但同时数量仍由固定 worker 数限制。
- coordinator 需要区分 page submission 与 directory completion。
- page 边界不属于领域 API 稳定语义，不能影响最终规范树。
