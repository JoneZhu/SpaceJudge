# Phase 5D-A Pi 交付报告：直接分发工程就绪

状态：Pi 实施与自测完成，Codex 已独立验收 5D-A；未进入 5D-B，未签名、未公证、未发布。最终结论见 [Phase 5D-A 验收基线](23-phase-5d-a-baseline.md)。
日期：2026-09-27
工作位置：`/Users/hongdazhu/Documents/ChatGPT/SpaceJudge`（`master` 工作树，无 HEAD，全部未跟踪）
任务依据：[Phase 5D-A 任务单](phase-5d-pi-task.md)、[Phase 5D 设计](22-phase-5d-design.md)、[ADR-0010](adr/0010-developer-id-dmg-release.md)
原始证据目录：`/tmp/spacejudge-phase5d-pi.bdI8JK/evidence`
原始日志目录：`/tmp/spacejudge-phase5d-pi.bdI8JK/logs`

## 1. 实现范围

只实现不依赖发布凭据的 5D-A，并实现正式分发脚本的 fail-closed 路径。没有访问 Apple Developer Portal，没有创建/下载/撤销证书，没有读取或输出 Keychain 凭据，没有运行 `notarytool submit`，没有 commit/tag/push/上传。

### 1.1 新增

- `App/SpaceJudgeApp/Assets.xcassets/AppIcon.appiconset/`：10 个 PNG（16–512 的 1x/2x）+ `Contents.json`。
- `scripts/assets/generate-app-icon.swift`：确定性 Core Graphics 图标生成器（浅色底、微信绿 treemap、无文字，每个 slot 独立按目标像素绘制，不下载、不上采样）。
- `App/SpaceJudgeApp/en.lproj/InfoPlist.strings`、`App/SpaceJudgeApp/zh-Hans.lproj/InfoPlist.strings`：五个只读用途说明的英文本地化与简体中文本地化。
- `scripts/release/lib.sh`：共享工具封装、Git/版本/身份/Mach-O/DMG/notarization/manifest helper。
- `scripts/release/local-candidate.sh`：credential-free universal2 ad-hoc hardened DMG。
- `scripts/release/distribute.sh`：正式 Developer ID + 公证 + staple + Gatekeeper 流水线（含 `--preflight-only`）。
- `scripts/release/verify-artifact.sh`：DMG 结构与签名复核。
- `scripts/release/test-release-scripts.sh`：fail-closed 自测。
- `docs/runbooks/direct-release.md`：人工凭据准备、5D-A、5D-B、验证、回滚、清理。
- `docs/phase-5d-pi-report.md`：本报告。

### 1.2 修改

- `App/SpaceJudge.xcodeproj/project.pbxproj`：Release `ENABLE_HARDENED_RUNTIME = YES`（Debug 保持 NO）；`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`；加入 `InfoPlist.strings` variant group 与 `zh-Hans` region。
- `App/SpaceJudgeApp/Info.plist`：新增 `NSDesktopFolderUsageDescription`、`NSDocumentsFolderUsageDescription`、`NSDownloadsFolderUsageDescription`、`NSRemovableVolumesUsageDescription`、`NSNetworkVolumesUsageDescription` 的英文 fallback。
- `.gitignore`：加入 `dist/`。
- `docs/05-testing-and-acceptance.md`：新增 Phase 5D-A 验收章节。
- `docs/06-implementation-and-pi.md`：更新 Phase 5D 状态。
- `docs/references.md`：新增图标、universal binary、`hdiutil`、`stapler`/`spctl` 参考。
- `README.md`：更新 5D-A 实现事实。

未改动扫描、SQLite、取消、treemap、Phase 5C 缓存语义、Debug 测试 seam、bundle ID/version/build/min OS；Sandbox 仍关闭；未新增任何 entitlement。

## 2. 自动测试与构建

| 检查 | 命令 | 退出码 | 结果 |
| --- | --- | --- | --- |
| 全量 Swift 测试 | `arch -arm64 swift test` | 0 | 421 tests / 57 suites 通过（与 Phase 5C 基线一致，无回归） |
| Swift Release build | `arch -arm64 swift build -c release` | 0 | Build complete |
| Xcode Debug | `xcodebuild ... -configuration Debug CODE_SIGNING_ALLOWED=NO build` | 0 | BUILD SUCCEEDED，1 条 `appintentsmetadataprocessor` 提示 |
| Xcode Release | `xcodebuild ... -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build` | 0 | BUILD SUCCEEDED，1 条 `appintentsmetadataprocessor` 提示 |
| 发布脚本自测 | `bash scripts/release/test-release-scripts.sh` | 0 | 108 passed / 0 failed |
| 本地候选生成 | `bash scripts/release/local-candidate.sh --output-dir <out>` | 0 | universal2 ad-hoc hardened DMG + manifest |
| 本地候选复核 | `bash scripts/release/verify-artifact.sh --dmg <dmg> --manifest <json> --mode local` | 0 | checksum/manifest/signature/arch/layout/binding 通过 |

`xcodebuild -showBuildSettings -configuration Release` 关键值：`ENABLE_HARDENED_RUNTIME = YES`、`ENABLE_APP_SANDBOX = NO`、`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`、`PRODUCT_BUNDLE_IDENTIFIER = com.hongdazhu.SpaceJudge`、`MARKETING_VERSION = 0.3.0`、`CURRENT_PROJECT_VERSION = 3`、`MACOSX_DEPLOYMENT_TARGET = 14.0`。

AppIcon 重新生成使用 `SJ_ICON_MASTER` 输出 1024 审查图；构建日志中 AppIcon 无 “unassigned child” 或缺图警告。

## 3. 本地候选产物

| 项目 | 值 |
| --- | --- |
| DMG | `/tmp/spacejudge-phase5d-pi.bdI8JK/evidence/local-candidate/SpaceJudge-0.3.0-3-universal-LOCAL-ADHOC-NOT-FOR-DISTRIBUTION.dmg` |
| SHA-256 | `65e7060d2f2cc90317207338272226b8a45439c652e77b19fba6fe6639e54e42`（PATH 硬化后重跑；与 `.sha256` 复核一致） |
| manifest | 同名 `.json`，`kind=local-adhoc`，`distributionReady=false`，`notarizationStatus=not-submitted`，`gitState=no-head` |
| 架构 | `lipo -archs` = `x86_64 arm64` |
| 签名 | ad-hoc，`flags=0x10002(adhoc,runtime)`，`TeamIdentifier=not set` |
| entitlements | 空（无 `get-task-allow`，无任何 key） |
| bundle 资源 | `PrivacyInfo.xcprivacy`、`AppIcon.icns`、`Assets.car`、`en.lproj`、`zh-Hans.lproj` |
| DMG 根 | 仅 `SpaceJudge.app`（真实目录）与 `Applications -> /Applications` symlink，无隐藏 payload |
| 嵌套 Mach-O | 仅 `Contents/MacOS/SpaceJudge` |
| `spctl` | 预期 `rejected`（ad-hoc 不可分发） |

`codesign --verify --deep --strict` 与应用内 `codesign --verify --strict` 均通过。`verify-artifact.sh` 现在强制要求 `.dmg.sha256` 与 manifest，并验证 checksum hash/文件名、manifest sha256/version/build/bundle ID/minOS/architectures 与挂载后 App 完全绑定；错误 manifest 搭配（例如 build 改为 99）会被拒绝。完整检查记录见 `evidence/local-candidate-inspection.txt`、`logs/local-candidate-verify.log` 与 `logs/verify-negative.log`。

## 4. 真实 App smoke

由于 Release 构建按设计忽略 `SPACEJUDGE_TEST_*` Debug seam，真实 scan/cancel smoke 使用同一工程、同一源码树的 **hardened Debug arm64** 构建（`ENABLE_HARDENED_RUNTIME=YES`、`ENABLE_DEBUG_DYLIB=NO`、ad-hoc + runtime 签名）；Release universal 本地候选单独做启动冒烟。

| 场景 | 构建 | PID | 结果 | 停止 |
| --- | --- | --- | --- | --- |
| fixture 完成扫描 | hardened Debug，`open --env` | 17558 | `scans.status=2`（completed），73 nodes，UI `扫描完成` | 精确 PID SIGTERM，`still_alive=false`，无残留 |
| `/` 取消扫描 | hardened Debug，`open --env` | 17232 | 点击真实 `取消` 后 `scans.status=3`（cancelled，83448 nodes），UI `已取消` | 精确 PID SIGTERM，`still_alive=false`，无残留 |
| Release 本地候选启动 | universal ad-hoc DMG 内 App | 36692 | 在 hardened runtime 下启动，未崩溃 | 精确 PID SIGTERM，`still_alive=false`，无残留 |

取消通过 System Events 点击真实窗口按钮完成（`click button 5 of group 1 of window 1`）；取消后按钮自动禁用。所有 App 进程按精确 PID 停止，未使用 `killall`/`pkill`；复核 `pgrep -f "SpaceJudge.app/Contents/MacOS/SpaceJudge"` 无结果，无 SpaceJudge DMG 残留挂载。证据：`evidence/smoke-completed.txt`、`evidence/smoke-cancel.txt`、`evidence/smoke-release-launch.txt`。

Release 产物不响应 Debug 测试 seam：`strings` 确认 Release 主二进制中 `SPACEJUDGE_TEST_ROOT_PATH` 与 `SPACEJUDGE_TEST_DATABASE_PATH` 均不存在（Debug 对照构建存在），且传入 `SPACEJUDGE_TEST_DATABASE_PATH` 未创建对应文件。证据：`evidence/smoke-release-seam.txt`。

一次早期 Debug 尝试因 Xcode 26 debug dylib（`SpaceJudge.debug.dylib`）与 ad-hoc hardened runtime 的 library validation 冲突而 dyld abort；该次只用于 smoke 构建，未进入产品或本地候选，随后以 `ENABLE_DEBUG_DYLIB=NO` 重建并通过。此为构建 seam 冲突，不影响 Release 产物。

## 5. 正式 preflight 预期失败证据

`evidence/official-preflight.txt`：

- `security find-identity -v -p codesigning`：`developer_id_application_count=0`、`apple_distribution_count=2`、`apple_development_count=1`。
- 用不存在的 Developer ID label 运行 preflight：输出 `no-git-head`、`signing-identity-not-found`、`blockers=2`，退出码 1。
- 用现有 Apple Distribution SHA-1 运行 preflight：输出 `no-git-head`、`signing-identity-wrong-type:apple-distribution`、`blockers=2`，退出码 1。

两次 preflight 均无任何网络上传，未签名、未公证、未 staple；证明正式路径在当前机器 fail-closed，且不会用 Apple Distribution 冒充 Developer ID。

## 6. Fail-closed 自测覆盖

`test-release-scripts.sh`（108 passed / 0 failed）覆盖：相对/非空输出目录、metadata 语法（version 必须 `N.N.N`、build 正整数、bundle ID/min OS 无 `/`/`..`/控制字符）、无 HEAD、dirty tree、Apple Distribution/Development/未知身份拒绝、Developer ID 接受与父 shell Team ID、同名 label 多匹配拒绝、notary `Invalid` 拒绝 / `Accepted` 通过、notarization log 缺失/空/非 JSON/非 Accepted/含 error issue 拒绝与 warning 计数、stapler 与 `spctl` 非零退出拒绝、get-task-allow/任意 entitlement 拒绝与空 entitlements 通过、只有主 executable 的 Mach-O 白名单、未知 nested Mach-O 拒绝、精确 `arm64 x86_64`（单架构/额外架构拒绝）、三源 metadata 一致性、DMG 根多余条目/App symlink/错误 Applications 目标拒绝、checksum sidecar hash 与文件名绑定、manifest 本地/正式绑定、官方脚本拒绝 `SJ_*_BIN` override、`local-candidate.sh` 不引用 notarytool、所有脚本 `bash -n` 通过且无 `eval`、无 `rm -rf`、无明文密码参数、不通过命令替换调用 temp helper、temp helper 在父 shell 设置全局并被 cleanup 回收，以及**恶意 caller PATH 前置 `plutil`/`xcrun`/`notarytool`/`ditto`/`security`/`git` 等替身时，三个正式入口都只使用系统工具（替身零执行痕迹）**。

## 7. 返修反馈 #1（2026-09-27）

Codex 第一轮 review 指出七类问题，全部已修复并重新自测：

1. **命令替换丢失全局状态，临时构建不清理**：`local-candidate.sh` / `verify-artifact.sh` 改为在父 shell 直接调用 `sj_make_temp_dir`（helper 不再输出，直接设置 `SJ_TEMP_DIR`），trap 能回收。旧错误版本残留的六个任务目录已按精确路径逐个确认为任务 temp 后删除（4 个 `spacejudge-localcandidate.*` 共约 1.85 GB、2 个空 `spacejudge-verify.*`），未使用宽泛 glob 或 `rm -rf`。重跑成功后 `TMPDIR` 下任务 temp 数为 0；人为制造日志目录不可写导致失败后，任务 temp 仍被回收。
2. **正式流水线丢失 Team ID**：`distribute.sh` 改为直接调用 `sj_require_developer_id`（不再命令替换），`SJ_SIGNING_TEAM_ID` 留在父 shell 并写入 release manifest；自测改为直接读取父 shell 全局而非在 subshell 里 printf。
3. **正式路径不能继承测试工具替换**：新增 `sj_forbid_tool_overrides`，`distribute.sh` 与 `verify-artifact.sh` 拒绝所有 `SJ_*_BIN`；自测改为 helper 单测用 stub、正式脚本只验证真实环境 fail-closed 与 override 拒绝。
4. **公证 log 失败仍可能 ready**：status Accepted 后必须有 submission ID，必须成功下载且 log 为有效 JSON、status Accepted、无 error issue，否则不 staple、不写 ready manifest；warning 计数写入 manifest 的 `notarizationWarningCount`。
5. **verifier 未绑定产物**：`verify-artifact.sh` 现在强制 `.dmg.sha256` 与 manifest，校验 sidecar hash/文件名、manifest 与实际 DMG SHA、以及 version/build/bundleID/minOS/architectures 与挂载后 App；local/release 各自校验 kind/ready/notarization/submission/commit/team。
6. **版本字段可逃逸 output directory**：新增 `sj_require_safe_version/build/bundle_id/min_os` 与 `sj_validate_source_metadata`，在构建前和路径拼接前拒绝 `/`、`..`、控制字符或非数字值。
7. **其余边界**：`sj_require_universal` 精确要求排序后的 `arm64 x86_64`；新增 `sj_detach_dmg_strict`（正常路径失败即中止，trap 才 best-effort）；`sj_attach_dmg` 不再 `-noverify`；正式 DMG 签名后与 staple 后都做 `codesign --verify --strict`；notarization 前再次确认 HEAD 未变化且工作树 clean；本地门通过后用 `notarytool history` 做只读认证门（当前环境不触发网络）；`logs/` 收紧为 `0700` 且文件不允许 group/other 写。

返修后回归：`arch -arm64 swift test` = 421 tests / 57 suites（exit 0）；`swift build -c release`、Xcode Debug/Release `CODE_SIGNING_ALLOWED=NO` 均成功；脚本自测 103/0；重新生成的本地候选 SHA-256 见 §3；真实官方 preflight 仍因 no HEAD + no Developer ID 失败，且 override 在本地门之前被拒绝（`evidence/official-preflight.txt`）。

## 8. 返修反馈 #2（2026-09-27，PATH 信任链）

Codex 指出正式发布信任链仍受调用者 PATH 影响：`sj_notarytool` 会先用 `command -v notarytool`，回退到未限定路径的 `xcrun`；`plutil`、`ditto`、`find`、`grep`、`sed`、`awk` 等也未限定路径。修复：

1. 新增 `sj_lock_system_path`，并在 `local-candidate.sh`、`distribute.sh`、`verify-artifact.sh` 计算 `SCRIPT_DIR` 之前内联执行 `PATH="/usr/bin:/bin:/usr/sbin:/sbin"; export PATH`，同时 `unset CDPATH BASH_ENV ENV`，不依赖调用者 PATH。
2. `sj_notarytool` 的正式路径固定为 `/usr/bin/xcrun notarytool`；`SJ_NOTARYTOOL_BIN` 只保留给 helper/self-test，官方入口继续拒绝。
3. 新增回归测试（self-test 第 16 节）：构造前置恶意替身 `plutil/xcrun/notarytool/ditto/security/git/hdiutil/codesign/shasum/dirname/basename/sed/awk/grep/find/mktemp`（替身先记录再委托真实工具），分别运行 `distribute.sh --preflight-only`、`local-candidate.sh`、`verify-artifact.sh`，断言真实门禁失败/正常行为且替身标记为空（零执行痕迹）；另用恶意 PATH 对真实 local candidate 跑 `verify-artifact --mode local`（exit 0，标记为空）。测试不访问 Apple 服务、不要求证书。
4. runbook 说明正式脚本忽略调用者 PATH 中的同名工具。

验证：自测 108/0（exit 0）；`arch -arm64 swift test` = 421 tests / 57 suites（exit 0）；`swift build -c release` 与 Xcode Debug/Release 均 exit 0；重新生成 local candidate（SHA 见 §3），正常与恶意 PATH 下 `verify-artifact --mode local` 均通过；恶意 PATH 下 official preflight 仍因 `no-git-head` + `signing-identity-not-found` 失败且替身零执行（`evidence/path-hardening-preflight.txt`、`logs/verify-malicious-path.log`）。

## 9. 已知限制

- 产物是 ad-hoc、非公证、非 Gatekeeper 接受的本地候选；**不可分发**，名称和 manifest 已明确标注。
- 本机为 Apple Silicon；`x86_64` 仅通过 universal 构建、`lipo` 与签名静态校验，尚无真实 Intel 启动证据。
- 正式签名、公证 log、staple、Gatekeeper、浏览器 quarantine、离线 open、覆盖安装与 Intel/Apple Silicon 实机矩阵仍属于 5D-B，必须等 Developer ID Application、Keychain notary profile 与干净 commit。
- 本地候选 DMG 未提交公证，因此 `spctl` 预期拒绝；这不是缺陷。
- 图标为可替换首版资产，由仓库内脚本生成；Codex 仍需在 Finder/Dock 与 16/32/128/1024 做视觉抽查。
- 无 App Sandbox、无 bookmark、无 updater、无网络/遥测/崩溃上传/删除/AI，与既有产品边界一致。

## 10. Git 状态

仓库仍无 commit（`git rev-parse HEAD` 失败），全部文件未跟踪；未 commit、tag、push、签名或发布。正式发布脚本因此在设计上拒绝继续，符合 5D-A 验收门 7。

## 11. 证据与日志

- 本地候选：`/tmp/spacejudge-phase5d-pi.bdI8JK/evidence/local-candidate/`（DMG、`.sha256`、`.json`、`logs/`）。
- 结构检查：`evidence/local-candidate-inspection.txt`、`logs/local-candidate-verify.log`、`logs/verify-negative.log`。
- 兜底与临时区：`logs/local-candidate-failure-cleanup.log`（构造失败路径验证 temp 回收）、`evidence/feedback1-fixes.txt`（残留清理与临时区计数）。
- 真实 App：`evidence/smoke-completed.txt`、`evidence/smoke-cancel.txt`、`evidence/smoke-release-launch.txt`、`evidence/smoke-release-seam.txt`。
- 正式 preflight：`evidence/official-preflight.txt`。
- 图标审查图：`evidence/AppIcon-1024-master.png`。
- PATH 硬化：`evidence/path-hardening-preflight.txt`、`logs/verify-malicious-path.log`、`logs/script-selftest.log`。
- 构建/测试日志：`logs/swift-test.log`、`logs/swift-build-release.log`、`logs/xcode-Debug.log`、`logs/xcode-Release.log`、`logs/smoke-xcodebuild-Debug.log`、`logs/script-selftest.log`、`logs/local-candidate-final.log`、`logs/icon-generate.log`。
