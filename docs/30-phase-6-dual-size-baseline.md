# Phase 6 CLI/MCP 双单位大小输出验收基线

状态：Accepted

日期：2026-09-28

## 1. 验收结论

CLI 与 stdio MCP 的容量输出已同时提供精确 bytes 与人类可读的十进制 SI GB，达到
[双单位输出设计](29-phase-6-dual-size-output.md) 的验收标准。

- 原有 `*Bytes` 字段名称、字符串类型和精确值保持不变；
- 同级新增 `*GB` 字符串，固定两位小数，`1 GB = 1,000,000,000 bytes`；
- 换算采用整数 half-up 四舍五入，Swift 不使用浮点数，TypeScript 使用 `BigInt`；
- 未知 bytes 与 GB 同时为 `null`，不会伪造 `0.00`；
- 数据库 schema、扫描语义、权限边界与取消语义均未改变。

## 2. 覆盖面

已验收以下输出：

- CLI：`volume`、scan progress、scan terminal、`status`、`children.items[]`；
- MCP：`get_volume_usage`、`get_scan_status`、`list_children`；
- MCP 的严格 output schema、`structuredContent` 和人类文本摘要；
- `capacity`、`available`、`used`、`rootAttributed`、`logical`、`allocated`、
  `attributed`、`effectiveAttributed` 八组 bytes/GB 字段。

## 3. 独立验证

Codex 在 Pi 实现和自测后独立执行：

- `arch -arm64 swift test --filter SpaceJudgeAgentCLITests`：15 tests / 2 suites 通过；
- `cd AgentMCP && npm test`：35/35 通过；
- `arch -arm64 swift test`：439 tests / 60 suites 通过；
- MCP typecheck 与 production build 通过；
- `git diff --check` 通过；
- release CLI 与 MCP 构建成功。

边界测试包括 `0`、舍入临界值、1 GB、进位和 `UInt64.max`。Swift 与 Node 对同一
真实卷数据的换算结果一致。

## 4. 本机安装验证

验收版本安装在：

```text
/Users/example/.local/share/spacejudge/releases/0.1.0-dual-size-20260928
```

`/Users/example/.local/share/spacejudge/current` 已指向该版本，现有
`/Users/example/.local/bin/spacejudge` 与 `spacejudge-mcp` 入口保持不变。上一版本目录
仍保留，可回滚；未修改任何全局 MCP 客户端配置。

真实命令 `spacejudge volume --root /` 已返回三组 bytes/GB 字段，例如：

```json
{"availableBytes":"41391745847","availableGB":"41.39","capacityBytes":"994662584320","capacityGB":"994.66","ok":true,"type":"volume","usedBytes":"953270838473","usedGB":"953.27"}
```

卷可用量会随系统活动变化，验收约束是每组字段的确定性换算关系。

## 5. 兼容性结论

本次是只增加字段的协议扩展。只读取原有 bytes 字段的客户端不需要修改；希望面向人
展示的客户端可直接读取对应 GB 字段。GB 仅为输出层派生数据，不作为计量真值存储。

Pi 的实现记录见 [Phase 6 CLI/MCP 双单位大小输出 Pi 报告](phase-6-dual-size-pi-report.md)。
