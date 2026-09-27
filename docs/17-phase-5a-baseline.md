# Phase 5A 验收基线

状态：Accepted

验收日期：2026-09-27

## 1. 交付结果

Phase 5A 完成了两个发布前必须有、但不扩展产品权限的能力：

- footer 在卷 `总容量 · 已用 · 剩余` 之外，增加本次扫描的中性对账：扫描中显示 best-known “已扫描并归属”；终态显示“当前范围 · 卷内其他/未纳入”；取消明确标注“未完成”；当前范围大于卷已用时显示计量差异。任何差值都不声称是垃圾或可释放空间。
- 新增 `spacejudge-e2e-bench`，用真实目录项完整经过 `DarwinBulkEnumerator → FileSystemScanEngine → PersistingScanRunner → SQLiteSnapshotRepository → close → openReadOnly → verification`。现有直接合成批次的 Store benchmark 继续保留，两者不混用。

实现保持 SQLite schema v1、单根 `ScanRequest`、同文件系统边界和只读产品边界。没有加入 APFS 多卷/firmlink、删除、AI、网络、FSEvents、Sandbox、签名、公证或更新。

## 2. Codex 独立验收

Pi 完成实现和第一轮自测后，Codex 没有直接放行，而是退回并修正三项：

1. 取消模式最初用完整 fixture 节点数除以取消耗时，产生虚假吞吐；最终统一改为 `成功持久化节点数 / scanAndPersistSeconds`。
2. 临时根清理失败最初仍会退出成功并记录“已删除”；最终成功路径必须确认清理成功，失败路径保留原始错误并只记录 warning。
3. 非必要的 `--file-bytes` 最初没有上限，可能触发无界分配与乘法溢出；最终删除该参数，文件固定 1 byte，logical byte 总计使用 checked multiply。

修正后，Codex 使用全新的 Swift scratch path 和 Xcode DerivedData 独立执行：

```sh
arch -arm64 swift test --scratch-path <fresh>
arch -arm64 swift build -c release --scratch-path <fresh>
arch -arm64 swift test --sanitize=thread --scratch-path <fresh> \
  --filter 'AppModelTests|ScanUpdateBufferTests|PersistingScanRunnerTests'
xcodebuild ... Debug ... CODE_SIGNING_ALLOWED=NO
xcodebuild ... Release ... CODE_SIGNING_ALLOWED=NO
swift package show-dependencies --format json
plutil -lint App/SpaceJudgeApp/PrivacyInfo.xcprivacy
```

最终结果：

- 322 tests / 45 suites 全部通过。
- 聚焦的 32 tests / 3 suites 在 Thread Sanitizer 下通过，没有报告 data race。
- Swift Release、Xcode Debug、Xcode Release 全部成功；唯一 Xcode 提示仍是没有 AppIntents 依赖，因而跳过 metadata extraction。
- Swift package 外部依赖数为 0；Privacy Manifest 通过校验；SQLite schema 仍为 v1。
- benchmark 默认临时根全部被清理，验收后 `/tmp/spacejudge-e2e-*` 数量为 0。

## 3. Codex 独立端到端性能基线

环境：MacBookPro18,2、Apple M1 Max、arm64、macOS 26.6.2 (25G83)、10 核、64 GB、Swift 6.3.3、Xcode 26.6。Release 构建；缓存状态未控制；fixture 为确定性 1-byte 小文件元数据压力，不冒充大文件 I/O 或真实系统盘冷缓存。

| 场景 | 首批成功落库 | 扫描 + 持久化 | 持久化吞吐 | 峰值 RSS | DB close 后 | FD 差值 | 结果 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 100k mixed | 41.3 ms | 0.710 s | 140,839/s | 60.6 MB | 29.3 MB | 0 | 100,000 精确一致 |
| 500k mixed | 198.7 ms | 5.355 s | 93,370/s | 138.1 MB | 138.6 MB | 0 | 500,000 精确一致 |
| 1m mixed | 210.7 ms | 15.203 s | 65,777/s | **238.8 MB** | 277.6 MB | 0 | 1,000,000 精确一致 |
| 100k wide | 48.5 ms | 1.202 s | 83,167/s | 56.5 MB | 36.2 MB | 0 | 100,000 精确一致 |
| 100k mixed cancel | 38.7 ms | 0.060 s | 100,329 persisted/s | 20.0 MB | 2.8 MB | 0 | 6,000 已落库，cancelled |

取消请求到 terminal 为 21.1 ms，请求后有 5 个在途 committed/progress update；它们是有界收尾。取消结果明确不冒充完整 fixture：`persistedNodes=6,000`、root aggregate 未完成、重开后的状态与计数一致。

工程门：

- 100k mixed 首批 < 500 ms、总链路 < 2 s：通过。
- 1m mixed RSS < 250 MB：通过，但余量约 11.2 MB，Phase 5B 改变扫描计划后必须重跑，不能把本数字外推到多卷全盘。
- 取消 < 200 ms 停止普通工作、< 2 s terminal：通过。
- FD 不随规模增长、完成场景持久化计数精确一致：通过。

fixture 生成耗时与扫描严格分开：100k mixed 8.23 s、500k 43.97 s、1m 87.43 s、100k wide 8.84 s、cancel 8.56 s。生成器使用有界栈，不保留百万条完整路径。

## 4. Phase 4 性能回归

同一独立 Release build 重跑 treemap benchmark：

| 场景 | Phase 5A p95 / 平均 | 工程门 | 结果 |
| --- | ---: | ---: | --- |
| 10,000 sibling layout | p95 1.224 ms | < 50 ms | 通过 |
| 2,000 tile index | p95 0.109 ms | < 10 ms | 通过 |
| 100,000 point query | 平均 0.140 µs | < 20 µs | 通过 |
| 1,280×800 render | p95 6.354 ms | < 16.7 ms | 通过 |
| 100 次 resize layout | p95 0.603 ms | 记录项 | 通过 |

峰值 RSS 27.1 MB。与 Phase 4 基线差异处于运行噪声范围，没有结构性回退。

## 5. 真实 App 验收

Codex 使用 Debug-only root/database 接缝启动真实 App，扫描 2,000 节点 mixed fixture：

1. 扫描终态为空间图，不是测试列表或静态原型。
2. 约 900×640 逻辑窗口（Retina 截图约 1,800×1,344 pixels）中工具栏、treemap 和 footer 均可见，footer 没有覆盖地图。
3. footer 完整显示 `总容量 994.66 GB · 已用 945.28 GB · 剩余 49.38 GB` 和 `当前范围 6.6 MB · 卷内其他/未纳入 945.28 GB`。
4. accessibility tree 能读到扫描完成状态、目录空间图、图例、容量和完整对账摘要；没有为 tile 创建数千个 accessibility 节点。

取消、权限受限、未知卷容量、0、`UInt64.max` 和 attributed > used 的文案由纯格式化与 AppModel 自动化测试覆盖。真实系统深色外观、增大字体和 VoiceOver 人工逐项走查仍属于发布硬化矩阵，不在本阶段伪称完成。

## 6. 冻结的 Phase 5A 语义

- 卷容量与当前扫描范围是两类事实；不得把差值重命名为垃圾、可清理、扫描遗漏或完整度百分比。
- terminal summary 优先于 progress；取消必须显示未完成。
- benchmark 的 `nodesPerSecond` 只使用成功持久化节点；完成场景等于完整 fixture，取消场景不是。
- fixture root 计入 `--nodes`；默认文件固定 1 byte；生成和扫描分别计时；缓存状态写明 uncontrolled。
- 完成场景必须精确验证 manifest、summary、持久化计数、重开状态、revision 与根 aggregate；取消场景验证有界性和重开一致性。
- 临时根和数据库互为兄弟；默认成功必须确认清理，保留模式拒绝覆盖既有目录。
- benchmark 不在程序内部用墙钟阈值判失败，慢机器仍应输出真实证据。

改变上述语义前先更新设计、测试和必要 ADR。

## 7. 当前边界与下一阶段

当前仍是单根、单文件系统 traversal。现代 macOS 启动盘的 System/Data volume group、firmlink 投影、权限限制、snapshot 与 clone 不能由当前差值推断。

下一阶段是 Phase 5B：设计并实现只读 `VolumeScanPlan`，先解决 APFS 卷组覆盖与去重，再讨论全盘权限引导。签名、公证、更新、FSEvents 和完整发布验收继续分阶段处理；删除、AI 与清理建议仍需要新的产品规格和安全 ADR。
