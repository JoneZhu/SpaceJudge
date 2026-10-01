# Phase 6 Agent 全局热点查询设计

状态：Accepted

日期：2026-09-28

## 1. 问题

`list_children` 能准确查看一个节点的直接子项，但 Agent 为定位整棵树的大目录，需要像本次
整盘分析一样反复调用十几次并自行维护层级。对 800 万级节点，这增加了往返、上下文与
误读风险。

本阶段增加一个只读的 `hotspots` / `get_hotspots` 查询，让 Agent 用一次调用得到某个
scope 下按有效归属容量排序的 Top-K 后代节点。它只提供文件系统事实，不判断“可清理”，
不读取文件内容，也不执行删除。

## 2. 查询语义

### 2.1 输入

- `scanId`：现有扫描 ID；
- `scopeNodeId`：查询范围节点，通常是 `start_scan` 返回的根节点；
- `limit`：默认 30，范围 `1...50`；
- `minimumBytes`：可选 UInt64 十进制字符串，默认 `1`。

CLI：

```text
spacejudge-agent-cli hotspots \
  --database ABSOLUTE_DB --scan-id UUID --node-id U64 \
  [--limit N] [--min-bytes U64]
```

MCP：

```text
get_hotspots(scanId, scopeNodeId, limit?, minimumBytes?)
```

### 2.2 输出

顶层字段：

- `scanId`、`scopeNodeId`、`status`、`snapshotComplete`；
- `snapshotRevision`；
- `limit`；
- `minimumBytes` / `minimumGB`；
- `overlapSemantics = "ancestorInclusive"`；
- `truncated`；
- `items`，最多 50 项。

每个 item 与 `children.items[]` 保持相同的节点、名称、flags、时间和四组容量字段，另增：

- `depth`：相对 scope 的深度，直接子项为 1；
- `effectiveAttributedBytes` / `effectiveAttributedGB` 是排序真值。

不返回绝对路径。名称仍是非可信展示元数据，只能出现在 `structuredContent`，不得进入 MCP
人类文本摘要。`parentId + depth` 足以重建已返回的热点树。

### 2.3 重叠语义

目录的 effective attributed size 包含后代，因此祖先和后代可能同时进入结果。结果用于
定位和继续钻取，不可直接求和。协议用固定字段 `ancestorInclusive` 明示这一点，MCP 文本
也必须提醒“do not sum”。未来若需要不重叠的回收候选，另建语义，不复用本接口。

## 3. 有界最佳优先算法

不对数百万节点执行全表排序，也不新增全局 size index。算法只复用现有
`childPage(of:in:limit:)`：

1. 验证 scan、scope 和终态；scope 本身不进入结果；
2. 读取 scope 的前 `limit` 个直接子项，放入候选优先队列；
3. 每次弹出最大候选，将其加入结果；
4. 若该候选是可下钻目录，则读取它的前 `limit` 个子项并入队；
5. 达到 `limit`、队列为空或最大候选低于 `minimumBytes` 时结束。

稳定排序：

1. `effectiveAttributedBytes` 降序；
2. 容量相同时 `depth` 升序，保证祖先先于后代；
3. 再按 `nodeId` 升序。

正确性依据：目录容量不小于任一后代；每次扩展只省略某父节点第 `limit + 1` 名之后的
子项，而它前面已有至少 `limit` 个不小于它的兄弟，因此省略项不可能进入全局 Top-K。

资源上界：最多输出 50 项、最多扩展 50 个目录、每次最多读取 50 个子项、队列最多约
2,500 个候选；不复制整棵树，不新增数据库 schema/index。

## 4. 快照与错误

- `running` / `cancelling` 快照拒绝热点查询并返回 `CONFLICT`，避免多次分页跨 revision；
- `completed` 为完整结果；`cancelled`、`failed`、`interrupted` 可查询已持久化部分，且
  `snapshotComplete=false`；
- 每个分页返回的 revision 必须等于初始 `lastRevision`，否则 fail-closed 为 `CONFLICT`；
- 不存在的 scan/scope 返回 `NOT_FOUND`；limit、minimumBytes 非法返回
  `INVALID_ARGUMENT`；
- 零字节默认被 `minimumBytes=1` 排除；用户显式传 `0` 时可以返回。

## 5. CLI 与 MCP 兼容性

- CLI 新增命令，不改变现有命令字段；
- MCP 从七个工具增加为八个，新增 `get_hotspots`；
- 现有工具名、schema 与行为不变；
- bytes 继续是精确十进制字符串，GB 继续是十进制 SI、固定两位字符串；
- `get_hotspots` 标记 `readOnly=true`、`destructive=false`、`idempotent=true`、
  `openWorld=false`。

## 6. 安全与隐私

- MCP 只能查询本实例创建的 scan，不能提交数据库路径；
- scope 只能是该 scan 内的节点；
- 不读取内容、不访问网络、不修改文件；
- 文件名可包含提示词、换行、无效 UTF-8 等，只作为 name/nameBase64 数据返回；
- MCP 文本、stderr 与错误不得包含文件名、绝对路径或用户名；
- 输出 schema 严格，`additionalProperties=false`。

## 7. 验收标准

Swift / CLI：

- 构造多层、容量交错和同容量树，证明全局排序、祖先优先、稳定 nodeId 次序；
- 证明结果不是“仅直接子项”，且深层热点可在一次调用中出现；
- limit、minBytes、零值、空目录、文件 scope、坏 ID、running 冲突、终态完整性；
- 每对 bytes/GB 可复算；输出最多 50；
- revision 不一致 fail-closed；
- 全量 Swift 回归。

MCP：

- tools/list 正好八个工具并含正确 annotations；
- 严格 input/output schema；
- 官方 client 完成真实 fixture scan 后一次调用看到深层热点；
- 人类文本不含名称并明确结果不可求和；
- 提示词式名称只在 structured content；
- 未知 scan/node、running、超限参数拒绝；
- Node 全量回归，无孤儿进程或任务目录泄漏。

性能：

- 10 万节点多层 fixture 的热点查询目标小于 1 秒；
- 查询额外内存保持有界，不随全树节点数线性增长；
- 不增加扫描数据库索引或改变扫描写入路径。

## 8. 非目标

- 不分类缓存、构建产物、聊天数据或用户文件；
- 不计算可释放容量，不生成删除命令；
- 不做跨祖先去重或把结果容量相加；
- 不解释 APFS 快照和未归因空间；
- 不保存绝对路径，不改变现有授权模型。
