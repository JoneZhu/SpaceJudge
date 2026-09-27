# ADR-0008：以统一可见命名空间扫描启动盘卷组

状态：Accepted

日期：2026-09-27

## 背景

现代 macOS 启动盘由只读 System volume 与可写 Data volume 组成 APFS volume group。Apple 的文件系统层使用 firmlink 把多个 Data 目录投影进系统根，使 Finder 和应用看到一棵统一目录树。与此同时，`/System/Volumes/Data`、VM、Preboot、Update、模拟器 runtime、外部盘和网络盘仍可能作为真实 mount point 出现在这棵树中。

SpaceJudge 需要扫描用户理解的“启动盘”，但不能重复扫描 Data，也不能顺带进入其他挂载卷。

## 备选方案

### A. 分别扫描 System root 与 Data root，再在应用层合并

优点是两个物理成员显式；缺点是需要复制系统 firmlink 映射、重写路径层级、处理重复、合并身份，并依赖非公开卷组发现方式。展示结果也不等同于用户在 Finder 中看到的树。

### B. 读取 `/usr/share/firmlinks` 或解析 `diskutil`

实现直接，但两者都不是适合作为产品契约的稳定公共 API。文本和路径可能随系统变化，错误时容易扩大扫描范围。

### C. 扫描系统提供的统一可见命名空间

使用 Foundation 公共卷属性识别启动根；使用 `getattrlistbulk` 已公开的 `SF_FIRMLINK` 与 `DIR_MNTSTATUS_MNTPOINT` 区分投影和真实挂载。沿 firmlink 进入，遇 mount point 截断。

## 决策

选择 C。

1. 只有公共卷事实明确表明“APFS + volume root + root filesystem”时，计划才是 `visibleStartupVolumeGroup`；否则降级为现有 `stayOnRootFileSystem`。
2. 启动卷组只设一个扫描根，即用户选择的统一可见根。
3. `SF_FIRMLINK` 是允许进入同一启动卷组 Data 投影的明确事实，并在节点上留下 projection flag。
4. `DIR_MNTSTATUS_MNTPOINT` 优先级最高，始终作为边界；因此 raw Data mount 与其他服务卷、外接卷、网络卷不会被递归。
5. 未经 firmlink 授权的 device transition 继续作为边界。
6. 不读取私有 firmlink 列表，不解析 `diskutil`，不按 `/`、`Macintosh HD`、容量或 device number 猜测。
7. 容量与目录归属仍是两种口径。即使 visible plan 完成，也不显示 100% 覆盖或把差值命名为垃圾。

## 原因

- 与 Apple 给普通应用和用户呈现的目录层级一致。
- Data 内容从可见投影出现一次，raw mount 被截断，去重规则简单且可测试。
- 真正的外部/服务挂载由 Darwin mount-status 事实截断，安全边界不依赖名称表。
- 不需要私有 API、子进程或新的高权限能力。
- 每条记录只增加紧凑事实，不破坏百万节点内存目标。

## 后果

- `BoundaryPolicy` 新增向后兼容的末尾枚举值，SQLite 枚举编码追加 2，但 schema 版本不变。
- parser 必须开始保留已经请求的 `ATTR_CMN_FLAGS` 中的 firmlink 事实。
- App 需要一个可注入的 VolumeScanPlanner；属性未知时范围会更保守，而不是更宽。
- `/System/Volumes/Data`、VM、Preboot、Update、外部卷等会显示为边界节点但不展开。
- 权限受限、APFS clone/snapshot 和容量计量差仍可能存在，不能由本决策消除。

## 推翻条件

只有当 Apple 提供更高层、公开且稳定的卷组遍历/归属 API，或真实系统测试证明统一可见命名空间无法避免重复/漏扫时，才重新评估多根合并。任何替代方案仍必须 fail closed、保护路径隐私，并能证明不会跨入非目标挂载。

## 参考

- [Apple：Role of Apple File System](https://support.apple.com/en-ie/guide/security/seca6147599e/web)
- [Apple WWDC19：What's New in Apple File Systems](https://developer.apple.com/videos/play/wwdc2019/710/)
- `man 2 getattrlistbulk`：firmlink 的 `SF_FIRMLINK` 与 mount point 的 `DIR_MNTSTATUS_MNTPOINT` 返回规则。
- macOS SDK `usr/include/sys/stat.h`、`usr/include/sys/attr.h`：相关公开常量定义。
