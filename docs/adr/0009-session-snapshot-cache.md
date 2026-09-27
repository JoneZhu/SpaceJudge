# ADR-0009：MVP 快照采用单会话、单扫描缓存

状态：Accepted

日期：2026-09-27

## 背景

真实启动盘扫描在百万级节点时会产生数百 MB、甚至超过 1 GB 的 SQLite 数据。当前产品没有历史扫描界面，不持久化根路径或访问书签，旧快照跨启动后的功能不完整。数据库和临时 spool 又位于被扫描的启动盘可见树内，如果没有明确排除，会把自身增长重新计入扫描。

## 备选方案

### A. 永久保留最近一次成功快照和当前扫描

能在新扫描失败时回退，但最坏同时占用两份全盘数据；旧根没有持久授权，恢复能力并不完整。

### B. 保存多次历史并设置总容量上限

可形成历史功能，但需要历史 UI、书签、逐快照配额、迁移和用户删除控制，超出当前 MVP。

### C. 单会话只保留一个扫描快照

当前结果在本会话可浏览；下一次扫描替换，下一次启动清除。缓存位于系统 Caches 目录并从扫描树中截断。

## 决策

选择 C。

1. 快照是可重建工作缓存，不是用户文档或扫描历史。
2. 当前 terminal 快照保留到下一次 begin 或下次 App 启动。
3. 新 begin 在插入 header 前级联清理旧 scan，任意时刻数据库只有一个 ScanID。
4. 下次启动只删除受管数据库三件套和严格命名的 spool 文件。
5. 数据库和 spool 共用一个受管工作区；扫描器将该目录显示为边界叶子，不递归。
6. 生产工作区使用 Foundation 返回的用户 Caches 目录；不硬编码主目录。
7. 不用普通 `VACUUM`，避免额外接近原库两倍空间；新库启用 incremental auto-vacuum，常规重扫优先复用空闲页。
8. 空间保护采用 512 MiB 开始门和 256 MiB 运行门，并把 SQLite 可复用页计入有效可用量。

## 原因

- 与当前“无历史、无书签、只读浏览”的产品边界一致。
- 避免旧成功快照与新全盘扫描同时线性占用两份空间。
- Caches 的生命周期和备份语义符合可再生成数据。
- 白名单清理和扫描边界让删除范围、隐私与自增长风险可独立测试。
- 不为每个节点增加路径或对象，保留百万节点内存余量。

## 后果

- 重启 App 后不会恢复上一次空间图；用户需要重新选择位置并扫描。
- 取消/失败结果仍能在当前会话浏览，但新扫描会替换它。
- 首次超大扫描仍可能达到运行空间门并提前失败；这是保护行为，不伪装为完成。
- 若未来需要历史或断点恢复，必须新增持久书签、配额、历史 UI 和迁移设计，并用新 ADR 推翻本决策。

## 参考

- [Apple：Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)
- [SQLite PRAGMA：auto_vacuum、incremental_vacuum、wal_checkpoint](https://www.sqlite.org/pragma.html)
- [SQLite VACUUM](https://www.sqlite.org/lang_vacuum.html)
