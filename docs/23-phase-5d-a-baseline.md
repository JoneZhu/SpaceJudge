# Phase 5D-A 验收基线：直接分发工程就绪

状态：Accepted

日期：2026-09-27

## 1. 结论

Phase 5D-A 已完成 Codex 设计、真实本机 Pi 实施、两轮集中返修和 Codex 独立验收。

SpaceJudge 现在具备不依赖发布凭据的 macOS 发布工程基线：Release 构建启用 Hardened Runtime，保持非 Sandbox、无 exception entitlement；产出精确包含 `arm64` 与 `x86_64` 的 universal2 App；生成只有 App 与 Applications 链接的只读 DMG；用 checksum 和 manifest 把产物字节、版本、bundle、最低系统与架构绑定。无 Developer ID 时，产物名称和 manifest 都明确标记为本地 ad-hoc、不可分发。

正式流水线已实现 Developer ID Application、Keychain notary profile、干净 Git commit、签名、公证日志、staple、Gatekeeper 与最终 manifest 的失败关闭门禁。首个干净 Git 基线现已建立；当前机器仍缺少 Developer ID Application，因此正式 preflight 只剩签名身份 blocker，不访问 Apple 公证服务，也不会产生 `distributionReady=true`。

验收结果：**5D-A 通过；5D-B 尚未开始。** 已建立本地 Git 基线；未签名、未公证、未推送、未发布。

## 2. 最终实现

### 2.1 App 发布配置

- Release target：`ENABLE_HARDENED_RUNTIME = YES`；Debug 保持原有开发行为。
- `ENABLE_APP_SANDBOX = NO`；无 `get-task-allow` 或其他 runtime exception entitlement。
- bundle ID `com.hongdazhu.SpaceJudge`，版本 `0.3.0 (3)`，最低 macOS 14.0。
- Release 主二进制精确包含 `arm64 x86_64`，且不包含 Debug 的 `SPACEJUDGE_TEST_*` seam。
- 中英文 `InfoPlist.strings` 覆盖 Desktop、Documents、Downloads、移动卷和网络卷的只读用途说明；Info.plist 保留英文 fallback。
- AppIcon 使用浅色圆角底和绿色 treemap 图形，无文字或第三方素材；16 px 和 1024 px 抽查均保持可辨认、边缘干净。

### 2.2 两级流水线

`scripts/release/` 固化为五个入口：

- `local-candidate.sh`：无凭据 universal2 Release 构建、ad-hoc runtime 签名、DMG、checksum 和 `distributionReady=false` manifest；不调用 Apple 服务。
- `distribute.sh`：显式 `--release`、干净 Git、精确 Developer ID Application、Keychain profile、签名、公证、日志、staple、Gatekeeper 和最终 manifest。
- `verify-artifact.sh`：重新挂载并绑定校验 DMG、checksum、manifest、bundle metadata、架构、签名、entitlements、资源和布局；release 模式额外验证 staple 与 Gatekeeper。
- `lib.sh`：受控工具封装、metadata/身份/公证/DMG/manifest 门禁和安全临时目录。
- `test-release-scripts.sh`：108 项失败关闭回归。

所有用户入口在执行外部工具前固定 `PATH=/usr/bin:/bin:/usr/sbin:/sbin`，清除会改变 shell 查找行为的环境变量；正式 distribute/release verify 拒绝全部 `SJ_*_BIN` 测试替身。`notarytool` 的真实路径固定经 `/usr/bin/xcrun notarytool`。

### 2.3 正式产物不会误报

正式路径只有在以下条件全部成功后才写 `distributionReady=true`：

1. Git HEAD 存在、工作树干净，且公证上传前 commit 未变化；
2. 身份唯一匹配且类型精确为 Developer ID Application，并取得 Team ID；
3. App 与 DMG 严格签名验证通过，App 带 runtime、无未批准 entitlement；
4. `notarytool submit` status 为 `Accepted`，有 submission ID；下载到的公证 log 是有效 JSON、status 为 Accepted、error issue 为 0；
5. staple、stapler validate、DMG Gatekeeper open assessment、App execute assessment 全部通过；
6. staple 后重新计算 checksum，manifest 绑定实际 DMG、App metadata、Git commit、Team ID 与公证 ID。

任一步失败都不生成正式 ready manifest。测试覆盖错误证书、dirty/no-head、错误或缺失公证日志、staple/Gatekeeper 失败、非法 metadata、额外架构、未知嵌套 Mach-O、多余 DMG 条目、错误 checksum/manifest 和恶意调用者 PATH。

## 3. Codex 审查与返修

### 第一轮：状态丢失、临时目录与 release 绑定

Codex 发现 shell 命令替换会让临时目录和 Team ID 的全局状态丢失，导致构建 scratch 泄漏或正式 manifest 无法得到 Team ID；同时正式路径仍允许测试工具覆盖，公证 log 下载失败后可能误继续，release verifier 没有强制绑定 checksum/manifest，metadata 可逃逸输出目录，并存在架构、DMG detach、pre-notary Git 复核等边界缺口。

Pi 统一改为父 shell 直接调用有状态 helper，清理了六个精确确认的任务临时目录；正式入口拒绝工具替身；公证结果与 log 双重校验；verifier 强制绑定 sidecar 和 manifest；补齐 metadata、精确架构、严格 detach、两次 DMG 签名校验、上传前 Git 复核和日志权限。

### 第二轮：调用者 PATH 信任链

Codex 进一步发现，虽然 `SJ_*_BIN` 已被拒绝，少数未限定路径的系统命令仍可能被调用者 PATH 中的同名程序替换。Pi 将三个用户入口在任何外部命令前固定到系统 PATH，`notarytool` 固定经 `/usr/bin/xcrun`，并增加 16 类恶意替身的回归。正式 preflight、local candidate 与 verifier 都没有执行替身标记。

两轮之后没有剩余阻断级或高优先级问题。

## 4. Codex 独立自动验收

Codex 使用全新的 `/tmp/spacejudge-phase5d-acceptance.tOWggj`，不复用 Pi 的构建产物：

| 检查 | 结果 |
| --- | --- |
| `scripts/release/test-release-scripts.sh` | 108 passed / 0 failed |
| `arch -arm64 swift test` | 421 tests / 57 suites，通过 |
| Xcode Debug unsigned build | `BUILD SUCCEEDED` |
| 全新 local candidate 构建 | 通过，SHA-256 `b2542d48159835c415c930ebc636f09ff26514e38062879008d6c3feb2b92947` |
| `verify-artifact --mode local` | 通过，`arm64 x86_64` |
| manifest build 改为 99 | 正确拒绝，exit 1 |
| 建立基线前：无 HEAD + 无 Developer ID 正式 preflight | 正确拒绝，exit 1、2 个 blocker、未访问公证服务 |
| 建立干净 HEAD 后重新 preflight | 正确拒绝，exit 1，仅 `signing-identity-not-found`、未访问公证服务 |
| 临时目录、DMG 挂载、App 进程 | 验收结束后均无残留 |

全新候选的签名 flags 为 `adhoc,runtime`，Team ID 未设置，effective entitlements 为空；bundle 中存在 Privacy Manifest、AppIcon、英文和简体中文资源。DMG 根只有真实目录 `SpaceJudge.app` 与 `Applications -> /Applications`。

## 5. Codex 真实 Release App 验收

Codex 从全新候选 DMG 挂载并启动真实 universal Release App：

- 首次窗口显示“未选择位置”，没有自动扫描；总容量、已用和剩余保持占位值；
- 通过系统选择器主动选择一个小目录后，生产 snapshot 以 `status = 2 (completed)` 收口，根名为 `Axure`，记录 2 个目录、0 个文件；
- 进程采样显示主线程空闲在 AppKit event loop，不是阻塞或死循环；physical footprint 68.8 MB，peak 77.2 MB；
- Release binary 不含 `SPACEJUDGE_TEST_ROOT_PATH` 或 `SPACEJUDGE_TEST_DATABASE_PATH`；
- 进程按精确 PID 终止，DMG 严格卸载，无残留进程或挂载。

扫描完成后的辅助功能抓取出现测试驱动超时，因此本轮没有把该次 Release 完成态截图作为证据；数据库终态、进程采样和静态检查均正常。Pi 已另行完成 hardened Debug 的真实完成、`/` 取消和 UI 终态检查，且 Release 候选已完成启动冒烟。此限制不替代 5D-B 的签名、公证和双架构实机矩阵。

## 6. 已知限制与 5D-B 门

- 当前候选是 ad-hoc、本地验证产物，Gatekeeper 预期拒绝；不能交给用户分发。
- 当前 Keychain 没有 Developer ID Application；Git 基线已经就绪，但仍不能真实签名或公证。
- 本机为 Apple Silicon；x86_64 只完成 universal 构建和静态验证，真实 Intel 启动仍待 5D-B。
- 5D-B 还需验证 Developer ID App/DMG 签名、secure timestamp、公证 Accepted log、staple、Gatekeeper、浏览器 quarantine、断网打开、覆盖安装，以及 Apple Silicon / Intel 实机安装与扫描。
- 首版仍无自动更新、遥测、崩溃上传、删除、清理建议、AI 或运行时网络业务。
- 初始 Git commit 已获授权并建立；安装证书、配置 notary profile、提交 Apple 公证和公开分发仍需要明确授权，5D-A 不扩大这些权限。

## 7. 文档与阶段状态

- [Phase 5D 实施设计](22-phase-5d-design.md)：5D-A Accepted；5D-B Proposed。
- [ADR-0010](adr/0010-developer-id-dmg-release.md)：Accepted。
- [直接分发 runbook](runbooks/direct-release.md)：当前操作基线。
- Pi 原始交付：[Phase 5D Pi 交付报告](phase-5d-pi-report.md)。
- Pi 会话：`/tmp/spacejudge-phase5d-pi.bdI8JK/sessions/2026-09-27T07-25-33-361Z_01a0e1c1-3f30-71ac-828f-23e28ab8ff19.jsonl`。
- Codex 验收证据：`/tmp/spacejudge-phase5d-acceptance.tOWggj`；大型 DerivedData 已回收，保留日志与本地候选。
- 已建立本地初始 Git 基线；未 tag、未 push、未签名、未公证、未发布。
