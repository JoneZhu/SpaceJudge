# 术语表

- allocated bytes：文件系统为文件分配的字节，包含所有 fork；不等于 APFS 独占可释放空间。
- attributed bytes：SpaceJudge 在一次扫描中归属给某节点的字节；硬链接重复项为 0。
- logical bytes：文件内容在逻辑地址空间中的大小。
- volume used：卷总容量减去系统报告的可用容量。
- unattributed：底层兼容属性，数值为 `max(0, volume used - 当前范围 attributed)`；当扫描根不是完整卷或存在 APFS 卷组边界时，它同时包含选择范围外的数据，因此产品统一称“卷内其他/未纳入”，不表示垃圾、扫描遗漏或可释放空间。
- node：一次扫描中的文件系统对象或容量对账虚拟项。
- snapshot：指定 revision 下供 UI 消费的不可变数据。
- issue：可恢复的扫描异常汇总，不等价于全局失败。
- firmlink：macOS 系统 / 数据卷之间由文件系统实现的链接机制，不按普通 symlink 处理。
- package：Finder 中表现为单个项目、文件系统中仍是目录的 bundle。
- treemap：用嵌套矩形面积表达层级和大小的布局。
