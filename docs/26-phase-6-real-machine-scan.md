# Phase 6 真实整机扫描观察

状态：Observed / Reliability Defect Resolved / Memory Follow-up Open

日期：2026-09-28

## 1. 背景

在 CLI 与 MCP 安装完成后，Codex 使用实际安装的 `spacejudge` 对本机启动盘和用户目录执行首次真实空间分析。所有操作只读取文件系统元数据；没有读取文件内容，也没有删除或修改用户文件。

## 2. 结果

容量查询成功：

- 容量：994,662,584,320 bytes；
- 已用：约 952.4 GB；
- 可用：约 42.2 GB；
- 使用率：约 95.8%。

大单根扫描失败：

| 根 | 已持久化节点 | 已访问条目 | issue | 终态 |
| --- | ---: | ---: | ---: | --- |
| `/` | 4,126,922 | 4,336,109 | 503 | `failed / INTERNAL` |
| `/Users/example` | 1,221,918 | 1,386,782 | 153 | `failed / INTERNAL` |
| `/Users/example/workspace` | 未形成可用根聚合 | 未记录于报告 | 0 | `failed / INTERNAL` |

失败发生在大量节点已经持久化、遍历数不再增长后的阶段。后续用同一个 `workspace` 做扫描引擎/持久化对照，已经确认并非最终聚合或 macOS 隐私权限：扫描引擎单独完成，而持久化链路收到不连续 batch revision，具体错误为 `revisionNotContiguous(expected: 284, found: 286)`。根因和修复设计见 [Phase 6 真实大目录可靠性修复设计](27-phase-6-scale-reliability-fix.md)。

## 3. 分段扫描验证

把同一台机器拆成较小的授权根后，以下代表性扫描都能持久化为 `completed`：

- `~/Library/Containers`：约 204.2 GB，约 53 万文件系统对象；
- `~/Library/Application Support`：约 71.1 GB；
- `/System`：约 60.1 GB；
- `/Applications`：约 45.8 GB；
- `~/Library/Developer`：约 32.6 GB；
- `~/miniconda3`：约 28.6 GB，约 95 万文件系统对象；
- `~/.cache`：约 25.8 GB，约 83 万文件系统对象；
- `~/Documents`：约 24.0 GB；
- `~/.codex`：约 20.2 GB；
- `~/Downloads`：约 19.9 GB。

这表明扫描枚举、批量持久化和查询本身可以处理较大数据量；缺陷更可能位于超大单根完成/聚合路径，而不是简单的固定文件数上限。该判断仍需代码级诊断确认。

## 4. 修复后对照

修复后已安装 CLI 的真实结果：

| 根 | 终态 | 节点 | issue | revision | wall | 峰值 RSS |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `workspace` | `completed` | 694,823 | 0 | 352 | 9.24 s | 174,768,128 B |
| 用户主目录 | `completed` | 6,766,424 | 154 | 3,917 | 154.04 s | 1,058,553,856 B |
| `/` | `completed` | 8,395,975 | 500 | 5,019 | 199.52 s | 1,286,356,992 B |

三者完成后根节点均可查询。主目录 154 个 issue 全部为 permission denied；`/` 为 497 个 permission denied 与 3 个 I/O issue。完整自动化、安装与资源证据见 [修复验收基线](28-phase-6-scale-fix-baseline.md)。

## 5. 当前结论与剩余限制

- 事件乱序导致的整机 `INTERNAL` 已解决，不再需要为了可靠性强制分段扫描。
- 分段扫描仍可用于更快回答局部问题，但不同根不能简单相加后与 APFS 卷 used 比较；clone、snapshot、跨范围 hard link、不可访问目录和系统卷语义都可能造成差异。
- 超大扫描峰值 RSS 达到约 1.29 GB，超过既有百万节点 250 MB 工程目标；这是下一项需要解决的规模缺陷。
- 对外 `INTERNAL` 仍缺少无路径内部阶段/原因码；本轮依赖诊断入口才定位到 revision gap。

## 6. 临时产物

本次分析一度生成约 3.9 GB 的私有 SQLite 临时数据。结果提取后，三个由本次任务创建的精确临时目录已删除；没有触碰用户原始文件。

修复验收又生成约 4.4 GB 的 `workspace`、主目录和 `/` 私有快照；结果提取后均按精确目录删除。验收结束时没有扫描进程、后台服务或 spool 残留。
