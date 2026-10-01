# Phase 6 CLI/MCP 双单位大小输出设计

状态：Accepted

日期：2026-09-28

## 1. 用户问题

现有 CLI 与 MCP structured output 只返回精确字节，例如：

```json
{"usedBytes":"952022115529"}
```

这对 Agent 计算安全，但人很难直接判断规模。输出应同时保留精确 bytes，并提供人可读的 GB。

## 2. 单位与格式

- `bytes`：原有无符号 64 位整数的十进制字符串，精确、不丢失。
- `GB`：十进制 SI 单位，`1 GB = 1,000,000,000 bytes`。
- GB 固定两位小数，以字符串编码，例如 `"952.02"`；不使用 JSON 浮点数。
- GB 使用整数算术四舍五入（half-up，半进位）到最接近的 0.01 GB；必须处理进位且不溢出。
- 格式固定使用 ASCII 数字和 `.`，不受系统 locale 影响，不使用科学计数法。
- 原始 bytes 为 `null` 时，对应 GB 也必须为 `null`；不得把未知伪装为 `0.00`。
- 本阶段不同时增加 GiB，避免 `GB`/`GiB` 含义混淆。

边界示例：

| bytes | GB |
| ---: | ---: |
| 0 | `0.00` |
| 4,999,999 | `0.00` |
| 5,000,000 | `0.01` |
| 999,999,999 | `1.00` |
| 1,000,000,000 | `1.00` |
| 1,005,000,000 | `1.01` |
| `UInt64.max` | 必须是普通十进制字符串且不溢出 |

## 3. 字段映射

现有字段保持不变，增加同级 `GB` 字段：

| 精确字段 | 人可读字段 |
| --- | --- |
| `capacityBytes` | `capacityGB` |
| `availableBytes` | `availableGB` |
| `usedBytes` | `usedGB` |
| `attributedBytes` | `attributedGB` |
| `rootAttributedBytes` | `rootAttributedGB` |
| `logicalBytes` | `logicalGB` |
| `allocatedBytes` | `allocatedGB` |
| `effectiveAttributedBytes` | `effectiveAttributedGB` |

覆盖范围：

- CLI `volume`；
- CLI scan `progress` 与 `completed/cancelled/failed`；
- CLI `status`；
- CLI `children.items[]`；
- MCP `get_volume_usage`；
- MCP `get_scan_status.progress/terminal`；
- MCP `list_children.items[]`。

计数、ID、revision 不是容量，不增加 GB 字段。

## 4. 兼容性

- 这是只增加字段的兼容扩展；原 bytes 字段名称、类型和语义不变。
- MCP 严格 output schema 必须同步声明新增字段，`structuredContent` 与 schema 一致。
- MCP 的人类文本摘要优先显示 `GB (bytes)`，例如 `952.02 GB (952022115529 bytes)`。
- Swift CLI 与 TypeScript MCP 的 GB 结果必须逐字段一致；TypeScript 可从 bytes 用 `BigInt` 计算，不能转成 `Number`。
- 不修改数据库 schema；GB 是输出层派生展示值，不落库。

## 5. 测试

Swift：

- 独立格式化单测覆盖表中边界、四舍五入进位、`UInt64.max`、可选 `null`；
- `volume`、scan terminal/progress、`status`、`children` 同时包含 bytes 与 GB；
- bytes 值保持原样，GB 与 bytes 可复算一致；
- JSON 中 GB 是字符串或 `null`，不是 number。

Node/MCP：

- `BigInt` 格式化边界与 Swift 一致；
- 三个相关工具的严格 schema 含新增字段；
- official client 端到端断言 structured output 与文本摘要；
- 路径脱敏、提示词式文件名、行长、生命周期测试不回归。

真实验收：

```json
{
  "capacityBytes": "994662584320",
  "capacityGB": "994.66",
  "usedBytes": "952022115529",
  "usedGB": "952.02"
}
```

实际值以验收当时卷状态为准，断言换算关系而不是写死容量。

## 6. 非目标

- 不提供 `--human-only`，防止脚本因缺少精确 bytes 失去可靠输入；
- 不改成纯文本表格，CLI 继续保持 JSON/NDJSON 契约；
- 不加入 KB/MB/TB 自动切换；
- 不改变磁盘分析、扫描、权限、AI 或清理能力。

## 7. 实现说明（Pi 自测记录）

本节只记录实现细节，不改变本设计的状态；独立验收见 [Phase 6 双单位 Pi 报告](phase-6-dual-size-pi-report.md)。

- Swift 侧：`AgentJSON.gigabytes(_:)` / `gigabytesOrNull(_:)` 以纯整数算术实现；
  `hundredths = bytes / 10_000_000`，余数 `>= 5_000_000` 时 `+1`（half-up），再拆成
  `整数部分.两位小数`。`UInt64.max` 得到 `18446744073.71`，不溢出。
- TypeScript 侧：`AgentMCP/src/sizes.ts` 的 `gigabytes(bytes)` 用 `BigInt` 做同样的
  `(value + 5_000_000n) / 10_000_000n` 半进位，绝不经过 `Number`；`null` 或非法输入返回
  `null`。
- MCP 严格 output schema 为 GB 新增专用字符串 pattern `^\d{1,11}\.\d{2}$`（bytes 仍是
  原有 UInt64 pattern），`structuredContent` 与人类文本同步。
- 人类文本摘要形如 `953.22 GB (953224705225 bytes)`；未知为 `unknown`。
- 未改数据库 schema，未落库 GB；所有原 bytes 字段名称、类型和语义不变。
