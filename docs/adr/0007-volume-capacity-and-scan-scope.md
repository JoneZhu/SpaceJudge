# ADR-0007：卷容量与当前扫描范围分开表达

状态：Accepted

日期：2026-09-27

## 背景

SpaceJudge 同时掌握两类来源不同的数据：

- Foundation 返回的卷总容量、可用容量和推导出的卷已用容量；
- 扫描引擎在用户本次选择范围内累计的已归属字节。

当用户只选择一个普通文件夹时，`卷已用 - 当前范围已归属` 的大部分是选择范围之外的数据；当用户选择现代 macOS 的启动盘根目录时，System/Data APFS 卷组、firmlink、挂载边界、权限限制、快照、clone 和不同计量口径也会造成差值。这个差值不能直接命名为“垃圾”“可清理”或“扫描遗漏”。

## 决策

1. 容量行只表达卷事实：`总容量 · 已用 · 剩余`。
2. 扫描对账行只表达当前扫描事实：
   - 扫描中：`已扫描并归属 X`；
   - 终态且 `卷已用 >= 当前范围`：`当前范围 X · 卷内其他/未纳入 Y`；
   - 终态且 `当前范围 > 卷已用`：`当前范围 X · 与卷用量差异 +Y`；
   - 卷已用未知：只显示 `当前范围 X`。
3. `卷内其他/未纳入` 是中性对账项，不代表可释放空间，也不能成为删除或清理建议。
4. Phase 5A 不通过路径字符串猜测用户是否选中了“整块磁盘”，不把 `/` 等同于完整 APFS 卷组。
5. `ScanSummary.unattributedBytes` 暂时保留为底层算术兼容属性；产品 UI 和新文档不得把它单独显示为“未归属垃圾”。未来多根 `VolumeScanPlan` 落地时再决定是否重命名或版本化持久化语义。
6. 当前阶段不新增 SQLite schema 字段，不持久化用户路径或选择类型。对账结果由现有 `ScanSummary`、`ScanProgress` 和 `VolumeFacts` 纯计算得到。

## 原因

- 同一卷容量是全卷计量，目录扫描是局部归属，两者不能假装属于同一覆盖范围。
- APFS system/data volume group 在 Finder 中看起来像一个磁盘，但底层是可共同挂载并通过 firmlink 连接的多个逻辑文件系统；单根、单 device traversal 不能自动声称覆盖整盘。
- 中性表达能给后续卷组计划、权限引导和快照口径留下空间，也避免用户误删。

## 后果

- footer 会多一条短对账信息，但仍保持只读、紧凑。
- Phase 5A 可以在不迁移数据库的前提下纠正产品语义。
- 真正的“全盘覆盖率”必须等待 Phase 5B 的 APFS 卷组扫描计划；在此之前不得显示百分比完整度。
- clone、快照和可释放空间仍然是未知事实，不能从当前差值反推。

## 参考

- [Apple：Role of Apple File System](https://support.apple.com/en-ie/guide/security/seca6147599e/web)
- [Apple WWDC19：What's New in Apple File Systems](https://developer.apple.com/videos/play/wwdc2019/710/)
- [Apple：Checking Volume Storage Capacity](https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity)
