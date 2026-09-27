# Phase 2 验收基线

状态：Accepted

验收日期：2026-09-26

## 1. 交付结果

Phase 2 已把扫描内核推进为可分页产出、可原子持久化并可供后续 UI 查询的快照流水线：

- `DirectoryEnumerator` 改为 worker 独占 cursor/page；Reference 默认每页不超过 1,024 项，Bulk 每页对应一次有界 `getattrlistbulk` buffer。
- worker 每页等待 coordinator 消费后再读取下一页；目录 work item 仅在 final、failure 或 cancel 时结束 `inFlight`。
- `SpaceJudgeStore` 使用系统 SQLite3，保存 scan、scan-local name、node、directory aggregate 与 issue；没有第三方 package。
- 所有领域 `UInt64` 使用固定 8-byte big-endian BLOB，完整覆盖 `UInt64.max`，并保持 SQLite 字节序排序与无符号数值排序一致。
- `PersistingScanRunner` 顺序等待每次写入，把 store 慢速反压到有界事件流；失败、无终态或终态不一致都会取消扫描并尝试把快照标成 failed。
- `spacejudge-persist-smoke` 可用 reference / bulk 对明确目录生成新数据库；`spacejudge-store-bench` 可生成并核验 10 万/100 万节点快照。

本阶段仍不包含 SwiftUI/AppKit、权限选择、磁盘容量采集、FSEvents、Finder 操作、删除/清理或 AI。

## 2. Codex 独立验收

实际运行：

```sh
arch -arm64 swift test
arch -arm64 swift build -c release
arch -arm64 swift package show-dependencies --format json
.build/release/spacejudge-persist-smoke --engine reference --database <new-db> <fixture>
.build/release/spacejudge-persist-smoke --engine bulk --database <new-db> <fixture>
/usr/bin/time -l .build/release/spacejudge-store-bench --nodes 1000000 --database <new-db>
```

最终结果：

- 171 tests / 24 suites 通过，退出码 0。
- Release build 通过，退出码 0，无编译 warning。
- `swift package show-dependencies` 的 `dependencies` 为空；Store 仅链接系统 `sqlite3`。
- Codex 另建真实临时 fixture，包含嵌套/空目录、隐藏文件、Unicode、稀疏文件、hard link、symlink 与真实分配的 12 KiB 文件；reference / bulk 核心 JSON 完全一致：9 files、5 directories、0 issues、12,288 attributed bytes、14 nodes、14 names、5 complete aggregates、10 root children。
- 独立 SQLite 检查确认 `user_version=1`、`journal_mode=wal`，revision 与 byte 字段均为 8 字节 BLOB。
- 所有 Codex 临时 fixture 与 benchmark 数据库在验收后移入废纸篓；没有新增后台服务。

## 3. 独立 100 万节点基线

Codex 使用 Release 构建在本机实际写入并在关闭后用只读连接重开核验：

| 指标 | 结果 |
| --- | ---: |
| synthetic nodes | 1,000,000 |
| directory aggregates | 30,303 |
| batches / final revision | 200 / 200 |
| writer wall time | 3.879787 s |
| throughput | 257,746 nodes/s |
| database bytes | 197,529,600 |
| children query p50 / p95 | 0.068 / 0.116 ms |
| maximum resident set size | 72,515,584 B（约 69.2 MiB） |
| reopened status | completed |
| reopened root | 64 children，aggregate complete |

这是一份单机、热缓存、synthetic store 基线，不是所有 Mac 或真实文件系统的产品 SLA。写入计时不包含 synthetic tree 生成；外层 `/usr/bin/time -l` 的完整进程 real time 为 4.79 秒。峰值 RSS 低于当前 250 MB 工程门。

## 4. Codex 退回与修正

Pi 首轮自测为 167 tests / 24 suites，但 Codex 没有直接放行，退回了以下问题：

1. stream 正常 EOF 但没有 terminal 时会抛错，却不会 cancel engine 或把 running snapshot 标为 failed。
2. transaction body 成功而 `COMMIT` 失败时不会 rollback，连接可能永久停在未结束事务。
3. Store 忽略 `NodeRecord.scanID`，可把 scan B 的 node 静默写入 scan A。
4. `.completed` / `.cancelled` event 没有验证其 `summary.status` 是否一致。
5. benchmark 用 `try?` 吞掉 children 查询错误，也没有 finish、计数核对或关闭后重开验证。

修正后增加了无终态清理、双向 terminal mismatch、batch ScanID rollback 和 deferred-FK COMMIT failure 回归测试；benchmark 现在任何查询失败都会非零退出，并验证 completed 状态、连续 revision、node/name/aggregate 数量与重开读取。

## 5. 冻结的 Phase 2 语义

- page 是枚举器与 coordinator 的背压边界；worker 不得把 page 重新拼成完整目录数组。
- Bulk 只可在尚未发布任何 bulk page 前切换 reference fallback；发布后失败必须显式结束该目录，不能 rewind 造成重复事实。
- SQLite `NULL` 表示 unknown；真实 0 是 8 个零字节。NodeID、NameID、revision、size、count、deviceID、fileID 均不得经有符号截断。
- batch 是单事务：names -> nodes -> aggregates -> revision；任一错误整批 rollback。
- batch revision 必须严格连续；NodeID 不覆盖，NameID/bytes 不冲突，complete aggregate 不回退、不改变。
- `NodeRecord.scanID` 必须等于外层 `NodeBatch.scanID`。
- 运行期绝对扫描路径不进入数据库；当前仅保存 root display name，bookmark 留待权限阶段。
- 可写 repository 打开时把遗留 `running` 标为 `interrupted`；应用层必须保持单 writer。实时 UI 并发读取应使用独立 `openReadOnly` repository/connection。
- terminal event、summary status 与 scanID 必须一致；任何已 started 但未合法完成的 runner 退出都执行 cancel + best-effort fail，并保留原始错误。

## 6. 当前已知边界

- 分页已消除“单个超宽目录一次生成完整 entry array”的缺口，但 coordinator 的未完成目录 bookkeeping 仍会随尚未完成的目录数增长。极端的百万同级子目录需要单独 RSS 实盘基准；有界 frontier 不等于所有扫描状态为常量内存。
- 100 万节点结果是 Store synthetic 基准，不是 100 万真实文件的 scanner + SQLite 联合基准；真实首批延迟、冷缓存、取消延迟仍需继续记录。
- writer repository 自身是单 actor；其内部读写方法会串行。需要边写边浏览时，使用单独的只读 repository，WAL 测试已证明未提交不可见、提交后可见。
- Writable repository 的 crash recovery 假设应用只有一个 writer；同时打开第二个 writable repository 会把已有 `running` 视为遗留任务。
- 磁盘总容量/已用/剩余的领域与 schema 已具备，但真实容量 API 采集、Privacy Manifest 和 UI 小字属于 Phase 3。
- APFS clone、压缩、resource fork、firmlink、真实挂载边界与全盘权限仍未完成实盘口径冻结。

## 7. 下一阶段入口

Phase 3 开始前先写原生应用壳设计与单独 Pi 任务单，至少明确：

1. Xcode app target、签名边界和 Swift Package 接入方式。
2. 目录选择、安全作用域/bookmark 与 Full Disk Access 状态模型。
3. `VolumeFacts` 的系统 API、fallback、Privacy Manifest 和显示口径。
4. 扫描 start/cancel/error 生命周期，以及 UI 使用独立只读 SQLite connection 的刷新节流。
5. 本阶段只做应用壳和真实端到端接线，不提前实现高性能 treemap 绘制、删除或 AI。

任何改变本文件冻结语义的实现，先更新 ADR 与测试，再交给 Pi。
