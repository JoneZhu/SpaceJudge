# Phase 5D-A Pi 实施任务单：直接分发工程就绪

## 目标

完整实现 [Phase 5D 设计](22-phase-5d-design.md) 中不依赖发布凭据的 5D-A，并实现正式分发脚本的 fail-closed 路径。最终交付一个 universal2、Hardened Runtime、ad-hoc 签名、明确标记不可分发的本地 DMG，用于 Codex 独立验收；不得尝试真实公证或对外发布。

## 工作位置与分工

- 工作位置：`/Users/hongdazhu/Documents/ChatGPT/SpaceJudge`
- 分支：当前 `master` 工作树；仓库尚无 commit，所有现有文件都属于用户成果。
- Pi 负责代码、资源、脚本、自动测试、普通修复与交付报告。
- Codex 已完成设计，负责独立 code review、复测、真实 App/DMG 验收、反馈与最终文档状态。
- 不 commit、tag、push、签名公证、上传或发布。

## 必须先读

1. `docs/22-phase-5d-design.md`
2. `docs/adr/0010-developer-id-dmg-release.md`
3. `docs/21-phase-5c-baseline.md`
4. `docs/adr/0006-direct-distribution-session-access.md`
5. `docs/05-testing-and-acceptance.md`
6. `App/SpaceJudge.xcodeproj/project.pbxproj`
7. `App/SpaceJudgeApp/Info.plist`
8. `App/SpaceJudgeApp/PrivacyInfo.xcprivacy`

## 已确认事实

- Xcode 26.6、notarytool 1.1.2、hdiutil/codesign/stapler 可用。
- 当前没有 Developer ID Application identity；Apple Distribution 与 Apple Development 不合格。
- 当前没有 Git HEAD，正式发布模式必须因此失败。
- bundle ID `com.hongdazhu.SpaceJudge`，version `0.3.0`，build `3`，minimum macOS `14.0`。
- Release Hardened Runtime 当前为 NO，App Sandbox 为 NO。
- 当前没有 AppIcon。

## 必须实现

### 1. Xcode / bundle

- 仅 Release 启用 Hardened Runtime；Sandbox 继续关闭。
- 不新增 runtime exception entitlement；distribution effective entitlements 不得有 get-task-allow。
- 添加 Desktop/Documents/Downloads/removable/network volume usage descriptions，至少 en + zh-Hans，本地化准确表达只读元数据、不读内容、不删除、不上传。
- 添加完整 AppIcon asset；视觉遵守 Phase 5D 设计，保留可编辑源资产或可重复生成脚本，不从互联网下载图标。
- Debug 与 Release、现有测试 seam、bundle ID、版本和最低系统保持兼容。

### 2. 发布脚本

创建：

- `scripts/release/lib.sh`
- `scripts/release/local-candidate.sh`
- `scripts/release/distribute.sh`
- `scripts/release/verify-artifact.sh`
- `scripts/release/test-release-scripts.sh`

遵守设计第 5–7 节。所有脚本严格引用参数、不使用 eval、不打印秘密、不使用 `rm -rf`、不覆盖既有产物、不接受明文密码。正式路径只接受 Developer ID Application 和 Keychain profile，并要求 `--release`、Git HEAD、clean tree、全新输出目录。

本地候选必须真实完成 universal2 Release、ad-hoc runtime 签名、strict verify、DMG 生成/挂载/检查、manifest/checksum，并命名为 `LOCAL-ADHOC-NOT-FOR-DISTRIBUTION`。它不得调用 notarytool submit。

正式脚本实现到可审查状态，但本轮只运行无副作用的 check/preflight，必须在当前环境因“无 Developer ID”和/或“无 Git HEAD”而明确失败；不得尝试换用现有其他证书。

### 3. 验证与文档

- 脚本 self-test 覆盖失败关闭：错误证书类型、无 Git HEAD/dirty tree、已有输出、notary non-Accepted、staple/spctl 失败、未知 nested Mach-O、版本不一致。
- 真实运行 `local-candidate.sh`，检查 `lipo -archs`、runtime flag、entitlements、PrivacyInfo、AppIcon、DMG 根内容、Applications symlink、manifest false。
- 启动 local candidate 中的 App，选一个任务临时 fixture，完成/取消一次扫描并退出；记录精确 PID 并停止。
- 全量 Swift tests、Release build、Xcode Debug/Release；必要的 hardened local smoke。
- 更新 `docs/05-testing-and-acceptance.md`、`docs/06-implementation-and-pi.md`、`docs/references.md` 和根 README 的“实现事实”，但不要把 Phase 5D 或 ADR-0010 改为 Accepted。
- 新增 `docs/runbooks/direct-release.md`，清楚区分一次性人工凭据准备、5D-A 本地候选、5D-B 正式发布、验证、回滚和清理。
- 交付 `docs/phase-5d-pi-report.md`，含实际命令、退出码、产物/日志路径、已知限制和所有任务进程状态。

## 禁止范围

- 不访问 Apple Developer Portal，不创建/下载/撤销证书。
- 不读取 Keychain 密码、私钥、token 或 API key，不运行会输出它们的命令。
- 不执行 `notarytool submit`，不 staple 假票据，不伪造 Accepted JSON。
- 不用 Apple Distribution、Apple Development 或 ad-hoc 产物声称可发布。
- 不添加 App Sandbox、bookmark 持久化、updater、网络、遥测、崩溃上传、删除、AI。
- 不改变扫描、SQLite、treemap 和 Phase 5C 缓存语义。
- 不管理不属于本任务的进程；禁止 killall、pkill 和宽泛终止。
- 不 commit、tag、push、上传网站、发送第三方或发布。

## 验收门

1. `arch -arm64 swift test` 全绿，数量不得少于 Phase 5C 的 421 tests / 57 suites。
2. Xcode Debug/Release `CODE_SIGNING_ALLOWED=NO` 成功；Release bundle build setting 显示 Hardened Runtime YES。
3. local DMG 包含 universal2 App、完整图标/隐私资源，strict codesign 通过，runtime flag 存在，manifest 为不可分发。
4. 正式 preflight 在当前机器明确拒绝，没有任何网络上传。
5. local hardened App 真实启动、fixture scan/cancel/quit 通过，无残留进程。
6. 脚本和 runbook 不含凭据或机器用户名/个人路径；报告中的任务临时路径允许存在。
7. 未 commit、签名公证或发布。

## 交付节奏

完成整个 5D-A、自测和普通修复后统一报告。若 universal build、Hardened Runtime 或系统工具行为与设计冲突，先保留证据并停止扩大范围；不要自行降低验收门。
