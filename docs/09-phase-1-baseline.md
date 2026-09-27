# Phase 1 验收基线

状态：Accepted

验收日期：2026-09-26

## 1. 交付结果

Phase 1 已把 Phase 0 的纯模型扩展为可运行的 macOS 目录扫描内核：

- `SpaceJudgeScan`：ReferenceEnumerator、Darwin `getattrlistbulk` fast path、安全二进制 parser、目录聚合、硬链接归属和扫描协调器。
- `spacejudge-scan-smoke`：对明确传入的目录运行 reference / bulk 扫描并输出稳定 JSON 摘要。
- `NodeBatch`：携带原始名称 bytes、节点事实和最终目录 aggregate；新名称不晚于首次引用它的节点发布。
- 有界调度：固定 worker 数；内存目录 frontier 有硬上限，超出部分进入 0600 权限的任务私有临时 spool。
- 有界事件流：慢消费者触发真实背压，不静默丢 batch、名称、aggregate 或终态。

本阶段没有实现 SwiftUI/AppKit 应用、SQLite 快照、FSEvents、全盘权限引导、删除/清理或 AI。

## 2. Codex 独立验收

实际运行：

```sh
arch -arm64 swift test
arch -arm64 swift build -c release
arch -arm64 swift package show-dependencies --format json
.build/release/spacejudge-scan-smoke --engine reference <fixture>
.build/release/spacejudge-scan-smoke --engine bulk <fixture>
```

最终结果：

- 123 tests / 19 suites 通过，退出码 0。
- Release build 通过，退出码 0，无编译 warning。
- `swift package show-dependencies` 为 0 个外部依赖。
- Codex 独立 fixture 覆盖嵌套/空目录、隐藏文件、Unicode、稀疏文件、硬链接和 symlink；reference / bulk 核心摘要一致：6 files、4 directories、0 issues、16,384 attributed bytes、root aggregate complete。
- parser 固定 seed fuzz 覆盖至少 10,000 个任意/truncated buffer；没有 crash、trap 或越界。
- event buffer=1、消费者暂停 1.3 秒时，全部节点/名称/aggregate 与连续 revision 可重建，只有一个终态。
- frontier=2、600 个目录时使用磁盘 spool，结果与宽 frontier 一致，内存 queue high-water 不超过 2；正常、取消和消费者终止后 spool/FD 回收。
- Pi 的开发机 20,000 个空文件基准约为 reference 62 万 entries/s、bulk 109 万 entries/s。该数字只用于回归比较，不是产品 SLA。

## 3. 两轮退回与最终修正

Pi 初次实现和自测通过后，Codex 没有直接放行。第一轮退回：

1. event buffer 满约 1 秒后会静默丢事件。
2. 所谓有界队列后仍有无界内存 `spillover`。
3. cancel 后可能继续 flush 普通 batch。
4. parser 接受无 NUL 名称和回指固定字段的 offset。
5. reference allocated bytes 使用 wrapping 乘法。
6. 非法 attributed fact 仍可能发布。
7. 计数/summary overflow 被饱和或伪装为 0。

第二轮退回：

1. `allocatedBytes=nil` 被误判为 I/O 损坏，而不是合法 unknown。
2. 完成诊断会随扫描次数永久积累。
3. progress 总数和 revision 仍有 wrapping 点。
4. terminal 背压期间 cancel 可改写已决定状态。
5. spool 没有正确处理 `EINTR` 与 offset/count overflow。

Pi 完成两轮修复后，Codex 最终又把无人读取的测试诊断设为最近 64 条硬上限，并增加回归测试。最终测试总数为 123。

## 4. 冻结的 Phase 1 语义

- `allocatedBytes=nil` 表示 unknown，不等同于 0，也不自动产生 issue；该节点 attributed 为 0，不 claim hard-link identity。
- known allocation 才能参与 attributed 归属；同一 `(deviceID,fileID)` 的第一次有效事实获得归属，后续为 0 并带 duplicate flag。
- known allocated 下若候选 attributed 大于 allocated，该事实是 invalid：发 issue，不发布 NodeRecord、不聚合、不 claim identity。
- reference 的 `st_blocks * 512` 必须先验证非负并检查乘法 overflow。
- parser 只逐字节读取；所有固定字段、record、attrreference、名称范围和终止 NUL 都必须在边界内。
- 取消后不再发布普通 batch/progress/issue；终态决策先锁定再等待投递，completed 与 cancelled 互斥且恰好一次。
- 扫描计数、revision、目录聚合和 spool 算术不得 wrapping 或静默饱和。
- `maximumQueuedDirectories` 是内存 frontier 的硬上限；临时 spool 不保存 FD，系统调用遇 `EINTR` 重试。
- 扫描顺序、NodeID、NameID 和 batch 边界不作为跨引擎一致性依据；差分以相对路径和事实字段规范化比较。

## 5. 当前已知边界

- Enumerator 仍会一次 materialize 单个目录的完整 `[RawDirectoryEntry]`；frontier 有界不等于总内存完全有界。超宽单目录分页是下一阶段的性能前置项。
- 真实子挂载点和 firmlink 尚未做可控实盘验证，只有代码路径与单元级证据。
- APFS clone、压缩文件、resource fork、xattr、快照与云文件的最终 allocated 口径尚未冻结。
- 临时 spool 保存运行期路径 bytes，权限为 0600，并在正常、取消、fatal 和析构路径关闭删除；后续安全评审仍需覆盖异常退出残留。
- 当前目录 aggregate 的 unknown allocated 贡献按 0 汇总；节点层仍保留 nil。若 UI 需要展示“部分未知”，Phase 2 的持久化 schema 必须另带 completeness/unknown 计数。

## 6. Phase 2 进入条件

Phase 2 应先解决“可增量消费与持久化”，再开始正式 UI：

1. 把单目录枚举改为 page/chunk 接口，避免超宽目录整批 materialize。
2. 增加单写者 SQLite snapshot repository，按 batch 事务写入 name/node/aggregate，并保留 unknown/completeness 语义。
3. 用百万级合成树与真实大目录记录峰值 RSS、吞吐、首批结果时间、取消延迟和数据库体积。
4. 完成 APFS/权限/挂载边界的实盘测试矩阵后，才把 scanner 接入 SwiftUI/AppKit 原生应用壳。

任何改变本文件冻结语义的实现，先更新 ADR 与测试，再进入 Pi 开发。
