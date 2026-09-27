# Phase 5C 实施设计：快照缓存自保护与异常恢复

状态：Accepted

日期：2026-09-27

验收结果见 [Phase 5C 验收基线](21-phase-5c-baseline.md)。实现过程中补充了三项必须保持的安全不变量：工作区根不能是符号链接、通过符号链接别名进入工作区也必须在 `.started` 前拒绝、强制取消只有在 cancelled 终态成功持久化后才能向 UI 发布。

## 1. 本阶段目标

Phase 5B 证明启动盘扫描在约 131 万节点时已产生约 398 MB SQLite 主库，另一轮 266 万节点只读抽查达到约 779 MB。Phase 5C 解决由此暴露的四个问题：

1. 扫描数据库和目录队列不能被本次扫描再次枚举，避免缓存自增长；
2. 快照不能跨扫描、跨启动无界累积；
3. 磁盘空间不足时必须在填满磁盘前拒绝或停止，并给出明确、无路径泄漏的提示；
4. 崩溃、强制退出和正常退出后，只清理 SpaceJudge 自己可再生成的缓存，不触碰用户文件。

本阶段不实现扫描历史、断点续扫、删除、清理建议、AI、FSEvents、App Sandbox、签名、公证或自动更新。发布签名需要开发者身份和分发决定，另行验收。

## 2. 产品决策

### 2.1 快照是工作缓存，不是用户文档

MVP 没有历史扫描入口，也不持久化根路径或 security-scoped bookmark。旧快照即使保留到下一次启动，也不能完整支持 Finder 定位或可靠重扫。因此：

- 正常、取消和失败快照只服务于当前 App 会话；
- 当前结果保留到下一次扫描或 App 下次启动；
- 新扫描开始时逻辑删除上一扫描；
- App 下次启动时删除上次遗留的受管数据库、WAL、SHM 与 spool 文件，再创建新工作区；
- 用户选择的目录、文件和任何非 SpaceJudge 受管文件永不由该清理流程删除。

这意味着“取消后仍能浏览已完成部分”继续成立，但“扫描历史”明确不属于 MVP。

### 2.2 缓存位置

生产缓存从 `Application Support/SpaceJudge` 移到系统返回的用户 `Caches/SpaceJudge`。缓存可重建、不应备份，符合 Caches 语义；路径必须由 Foundation API 获取，不能硬编码用户主目录。

Debug 的 `SPACEJUDGE_TEST_DATABASE_PATH` 继续存在，但只能控制本轮明确的测试数据库。测试清理只能处理该数据库及其 `-wal` / `-shm`，不得递归删除父目录。

### 2.3 空间阈值

阈值是产品保护值，不是对扫描规模的预测：

- 开始扫描硬门：缓存卷“重要用途可用空间 + SQLite 可复用空闲页”至少 512 MiB；
- 运行中硬门：上述有效可用空间至少 256 MiB；
- 每次持久化批次提交前检查，保证低空间反馈及时；
- 容量事实无法取得时，生产模式拒绝开始扫描，不把 unknown 当作 0，也不猜测；
- SQLite 自身返回 `SQLITE_FULL` / `SQLITE_IOERR` 时仍按存储失败终止，不能依赖预检替代真实错误处理。

512/256 MiB 只保护系统不被 SpaceJudge 缓存耗尽。第一次全盘扫描仍可能因缓存增长而提前停止；此时保留已成功提交的部分结果，状态为失败，并说明“缓存空间不足”。

## 3. 受管工作区

新增一个小型、可独立测试的 `SnapshotWorkspace`，只负责路径和文件生命周期，不负责扫描业务。

### 3.1 受管成员

生产工作区只允许以下成员：

- `snapshots.sqlite`
- `snapshots.sqlite-wal`
- `snapshots.sqlite-shm`
- `spool/spacejudge-spool-<UUID>.bin`

目录权限目标为 `0700`，新建 spool 文件保持 `0600`。SQLite 文件权限在创建后核对并收紧，不放宽现有更严格权限。

### 3.2 启动清理

启动准备顺序固定：

1. 通过 Foundation 取得 Caches 目录并追加 `SpaceJudge`；
2. 创建并收紧工作区；
3. 用白名单删除上次的数据库三件套和符合严格前缀/后缀的普通 spool 文件；
4. 遇到符号链接、目录、未知文件名或删除错误时不跟随、不扩大范围，并让 bootstrap 失败；
5. 创建全新 SQLite 库，随后打开只读连接。

禁止对 Caches、用户目录、`/tmp` 或工作区父目录做递归清理。正常关闭顺序为：停止扫描 -> 关闭 reader -> writer checkpoint/close；实际文件到下次启动才回收，以免退出过程中破坏仍在浏览的快照。

### 3.3 旧开发位置

本阶段不自动递归清理旧 `Application Support/SpaceJudge`。如处理早期开发版，只允许删除已验证为普通文件的精确三件套 `snapshots.sqlite{,-wal,-shm}`，并用测试证明相邻文件不受影响。若实现风险高，可作为已知限制记录，不得扩大删除范围。

## 4. 扫描自身排除

### 4.1 请求模型

`ScanRequest` 增加 session-only 的有界排除集合，元素包含：

- 规范化绝对目录路径；
- 可取得时的 `FileIdentity(deviceID,fileID)`；
- 原因枚举，目前只有 `snapshotWorkspace`。

排除集合不写入 SQLite、日志或诊断 JSON。生产 App 只传一个工作区根；测试可传 0–8 个。超过上限应明确失败，防止请求携带无界路径数组。

### 4.2 判断与结果

- 根目录本身等于工作区，或位于工作区内部：扫描在发布 `.started` 前失败；
- 枚举到工作区根：保留该目录节点，加入 `NodeFlags.snapshotStorageBoundary = 1 << 10`，不入队、不读取其子项；
- 优先用 `(deviceID,fileID)` 匹配，事实缺失时用规范化路径精确匹配；不能只按目录名匹配；
- 该边界优先于 package/firmlink 决策，但不能越过真实 mount point 的既有安全语义；
- 不把它计为权限错误，也不假装该目录大小已完整归属；它自然进入“卷内其他/未纳入”。

工作区必须同时承载 SQLite 和 `DirectorySpool`，这样一个边界即可覆盖数据库、WAL、SHM 和队列文件。

## 5. SQLite 生命周期

### 5.1 单扫描保留

`SQLiteSnapshotRepository.begin` 在写入新 scan header 前，于一个事务中删除所有旧 `scans` 行。外键级联清理 names、nodes、directory aggregates 和 issues。因此任意时刻数据库只含一个 scan。

删除发生在新扫描真正发出 `.started` 后，不在用户仅打开或取消选择面板时发生。取消、失败后当前快照继续保留；下一次 begin 才替换。

### 5.2 页复用和回收

- 新建数据库在创建任何表之前设置 `auto_vacuum=INCREMENTAL`；schema 仍为 v1，因为表结构和编码未变化；
- 同一会话再次扫描时，旧扫描释放的页优先供新扫描复用，避免文件随每次扫描线性增长；
- 终态和正常关闭时执行有界 checkpoint；`TRUNCATE` 被活跃 reader 阻塞时不得把已完成扫描改成失败，可退化为 PASSIVE 并在关闭连接后由 SQLite 收尾；
- 不执行普通 `VACUUM`。SQLite 官方说明它可能需要接近原库两倍的额外空间，与低磁盘保护目标冲突；
- `incremental_vacuum` 只在没有活动扫描时运行，并设置单次页数上限，不能让 UI 因回收数百 MB 长时间卡住。

### 5.3 可用空间计算

`effectiveAvailable = saturatingAdd(volumeAvailableForImportantUsage, reusableBytes)`，其中：

`reusableBytes = page_size × freelist_count`

所有乘加检查溢出。`-wal` / `-shm` 的现有占用已反映在卷可用容量中，不重复相减。运行时检查在 writer actor 内完成，不在 MainActor 执行。

## 6. 错误与 UI

新增可区分、无绝对路径的错误：

- `storageCapacityUnavailable`
- `insufficientStorage(requiredBytes, availableBytes)`
- `scanRootInsideSnapshotWorkspace`
- `unsafeWorkspaceEntry`

`AppUserError` 至少区分：

- 缓存空间不足：`可用空间过少，SpaceJudge 已停止写入扫描缓存。请先释放少量磁盘空间后重试。`
- 选择了应用缓存：`不能扫描 SpaceJudge 自己的工作缓存，请选择其他位置。`
- 其他数据库错误：保留现有“无法保存扫描快照”。

错误文案和测试输出不得包含数据库路径、用户名或所选根的完整路径。UI 不增加大面板；只复用现有错误位置和状态行。

## 7. 并发与关闭不变量

- 只有 repository writer actor 删除旧 scan、检查空间、checkpoint 和回收页；
- reader 只执行有界短事务；旧 generation 的查询结果继续由 AppModel generation guard 丢弃；
- `begin` 的旧数据清理、空间检查和新 header 写入必须形成清晰的失败边界，不能留下伪 running row；
- runtime 空间门触发后，runner 取消 engine，尝试把 scan 标为 failed，停止普通批次；
- shutdown 先等待扫描结束，再关闭 reader，最后 checkpoint/关闭 writer；
- 任意失败后不得残留 scanner task、FD 或 spool 文件。

## 8. 测试设计

### 8.1 Workspace

- 启动仅删除白名单数据库三件套和合法 spool；
- 相邻普通文件、子目录、符号链接和名称近似文件不删除；
- 清理幂等；删除失败明确报错；
- Debug override 不删除父目录；
- 权限为 `0700/0600`。

### 8.2 Store

- 第二次 begin 后数据库只剩新 ScanID，四张子表旧行均级联消失；
- 取消/失败在下一次 begin 前仍可查询；
- 新库 `auto_vacuum=INCREMENTAL`；不执行全量 VACUUM；
- WAL checkpoint 不破坏并发有界读取；
- 开始门 512 MiB 的下/等于/上边界；
- 运行门 256 MiB 的下/等于/上边界；
- unknown、复用页、乘加溢出和 `SQLITE_FULL` 映射；
- repository 低空间失败后无伪 commit，并把仍为 running 的 header 留给 runner 明确标记为 failed；端到端完成后 scan 不得继续 running。

### 8.3 Scanner / App

- 工作区位于 fixture 深处时，其节点存在、带 boundary flag、direct children 为 0；
- 同名目录、不同 identity 不误排除；
- identity 缺失时精确路径 fallback；
- 根等于/位于工作区时在 `.started` 前失败；
- spool 强制启用时文件位于工作区，完成/取消/失败后删除；
- App 的两个新错误文案无路径，重新扫描仍可恢复；
- 全盘 Debug UI 抽查能看到工作区边界，数据库中不存在其数据库/WAL/spool 子节点。

### 8.4 回归与性能

- 全量 Swift tests、Release build、Xcode Debug/Release；
- Store/runner/AppModel 关键组跑 Thread Sanitizer；
- 10 万与 100 万 mixed 端到端基准继续满足既有门；
- 100 万 RSS 仍小于 250,000,000 B；排除集合不得增加每节点常驻字段；
- 连续两次同规模扫描后 `scan_count == 1`，数据库主文件不得呈近似 2 倍线性增长；
- 取消延迟与 FD 门不回归。

## 9. 验收门

Phase 5C 只有在以下条件全部满足后才能从 Proposed 改为 Accepted；2026-09-27 已全部通过：

1. Pi 完成实现、自测和报告；
2. Codex 静态确认删除目标白名单、路径隐私、单扫描保留和失败边界；
3. Codex 使用独立目录重跑全量测试、TSan、Release/Xcode 构建和 100 万门；
4. 真实 App 扫描 `/`，确认工作缓存为叶子边界且缓存不自增长；
5. 人工构造低空间 provider，确认开始门和运行门都能安全停止；
6. 文档、代码和 UI 文案一致；
7. 没有 commit、push、签名、公证或发布，除非用户另行授权。

## 10. 后续阶段

Phase 5D 再处理直接分发的签名、公证、权限引导完整流程、崩溃报告与发布检查表。AI 判断和清理执行仍需要新的产品规格及安全 ADR。
