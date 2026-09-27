# ADR-0006：首版采用直接分发与会话级目录授权

状态：Accepted

日期：2026-09-26

## 背景

SpaceJudge 的核心用途是读取用户明确选择的目录或磁盘，递归枚举元数据并展示空间占用。首版不删除、不移动、不读取普通文件内容，也不以上架 Mac App Store 为目标。全盘扫描还会遇到 TCC、POSIX ACL、SIP 和“完全磁盘访问权限”，这些限制不能靠 App Sandbox 或关闭 App Sandbox 自动绕过。

## 决策

Phase 3 的原生 App：

1. 采用直接签名/公证分发的架构，App Sandbox 暂不启用。
2. 首次启动不自动扫描；用户必须通过 `NSOpenPanel` 主动选择一个目录或卷。
3. 只保留当前进程内的选择 URL。对 open-panel URL 调用 `startAccessingSecurityScopedResource()`；仅在返回 true 时配对调用 `stopAccessingSecurityScopedResource()`。
4. 本阶段不持久化 security-scoped bookmark，不把 root path 或 bookmark 写入 SQLite。重新启动后重新选择位置。
5. 不尝试用私有 API判断 Full Disk Access。根级 `EACCES` / `EPERM` 或大量 permission issue 只形成“访问受限”状态，并提供明确说明和打开系统设置的入口。
6. App 与 scanner 都保持只读；没有文件写入、删除、废纸篓或修复权限。

## 原因

- 首版优先验证真实扫描、容量、取消和快照接线，避免同时引入 App Sandbox bookmark 生命周期与签名迁移风险。
- 用户选择仍然明确表达扫描意图；不在启动时偷偷遍历磁盘。
- session-only URL 避免把高权限 bookmark 长期保存到数据库或诊断材料。
- App Sandbox 是未来 Mac App Store 或更强隔离方案的一部分，应与 bookmark 存储、迁移和恢复测试一起单独设计。

## 后果

- 本地 Xcode/直接分发构建可以扫描普通可读位置；受 TCC 保护的位置仍可能需要 Full Disk Access。
- 每次重启都要重新选择扫描根目录。
- 未来启用 App Sandbox 时，需要新的 ADR、read-only user-selected entitlement、app-scoped bookmark 存储和 stale-bookmark 迁移测试。
- `PrivacyInfo.xcprivacy` 仍随 App bundle 提供，声明磁盘容量展示和用户授权目录元数据读取的理由；数据不出设备。

## 替代方案

- 立即启用 App Sandbox：安全边界更强，但会同时扩大 bookmark、entitlement、恢复和全盘授权的实施范围，暂缓。
- 永久关闭 Sandbox 并记住裸路径：恢复简单，但路径不是授权，且会在数据库/偏好中留下个人路径，拒绝。
- 启动即扫描 `/`：违背用户主动授权与最小惊扰原则，拒绝。
