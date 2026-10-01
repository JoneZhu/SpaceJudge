SpaceJudge — EXPERIMENTAL TEST BUILD / 实验性测试版

NOT NOTARIZED / 未经过 Apple 公证
This is an opt-in testing build, NOT a production release.
This package uses a free ad-hoc signature, NOT an Apple Developer ID certificate.
Signing integrity checks do not prove safety, notarization or Gatekeeper acceptance.
仅供自愿参与测试的用户，不是正式发行版。请先阅读说明，再决定是否安装。

Source / 源码：https://github.com/JoneZhu/SpaceJudge
License / 许可证：MIT（应用内 Contents/Resources/LICENSE）
Requirements / 系统：macOS 14+；包含 arm64、x86_64，Intel 实机尚未验收。

Installation / 安装：
1. Get the DMG and checksum from the same trusted project release.
   从可信项目发布页取得 DMG 和校验值；校验值不是发布者身份的独立证明。
2. Open the DMG and drag SpaceJudge.app into Applications.
   打开 DMG，将 SpaceJudge.app 拖到 Applications（应用程序）。
3. macOS may block this unnotarized test build. Only if you trust its source,
   follow Apple's per-app approval instructions; availability varies by policy.
   未公证测试包可能被系统拦截；仅在确认来源可信时，按 Apple 的单应用批准说明处理。
   受管理设备可能不允许安装，不承诺每台 Mac 都能打开。
   https://support.apple.com/102445
   Do NOT disable Gatekeeper or SIP, or remove quarantine attributes.
   不要关闭 Gatekeeper/SIP，也不要用命令移除隔离属性。

Testing / 测试：
Start with a small disposable folder. Scans read filesystem metadata, not regular
file contents, and do not delete or modify scanned files. Private snapshots are
written locally. Permission-limited results and cancelled scans are incomplete.
先用小型测试目录体验；扫描只读文件元数据、不删除，但会写入本地快照缓存。
权限受限或取消的结果不完整；图中占用不等于删除后必然可释放的容量。

Optional Codex handoff / 可选 Codex：
Requires a separately installed Codex desktop app. A reviewable draft can contain
names, optional exact paths, sizes and scan metadata; it is not automatically sent.
Codex uses its own permissions. Any cleanup needs separate explicit authorization.
Codex 功能依赖另行安装的桌面应用；草稿可能含名称、可选路径和占用信息，不会自动发送。
SpaceJudge 的只读边界不限制外部 Agent；清理需另外明确授权。

Known gaps / 已知限制：
No Developer ID signing, Apple notarization, clean-machine installation acceptance
or Intel real-machine acceptance. No exclusive APFS clone/snapshot size estimate.
GUI handoff receipt and real model advice still need manual acceptance.
没有正式签名、公证、干净电脑安装或 Intel 实机验收；Codex 接收及建议效果仍待人工确认。

Feedback / 反馈：https://github.com/JoneZhu/SpaceJudge/issues
Include macOS version, chip, steps and synthetic examples. Do not post credentials,
private scan databases, unredacted paths, personal file lists or full raw logs.
反馈请带系统版本、芯片和复现步骤；不要公开凭据、扫描数据库、个人路径或原始日志。

Uninstall / 卸载：
Quit SpaceJudge, then move the app to Trash. No background service or global CLI
configuration is installed by this DMG. Keep any previous app backup for rollback.
退出应用后将它移入废纸篓；DMG 不安装后台服务、不修改全局 CLI/MCP 配置。
