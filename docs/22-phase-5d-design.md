# Phase 5D 实施设计：Developer ID 直接分发与发布硬化

状态：5D-A Accepted；5D-B Proposed

日期：2026-09-27

## 1. 本阶段目标

Phase 5D 把已经通过功能、性能和缓存安全验收的 macOS App，收敛成一条可重复、可审计、默认失败关闭的直接分发流程：

1. Release 构建启用 Hardened Runtime，维持非 Sandbox、只读、用户主动选择目录的既有产品边界；
2. 生成 Apple Silicon + Intel 的 universal App；
3. 在没有发布凭据时也能完成本地硬化、包结构和 DMG 验证，但产物必须明显标记为不可分发；
4. 在 Developer ID Application 证书和 Keychain 公证配置具备后，生成签名、公证、staple、Gatekeeper 校验通过的 DMG；
5. 固化版本、隐私声明、权限引导、发布清单、失败恢复和证据格式；
6. 真实发布必须可证明来自一个干净、可追溯的 Git commit，不把临时工作树或未经公证的构建交给用户。

本阶段不实现自动更新、遥测、崩溃上传、Mac App Store、App Sandbox、登录项、后台服务、删除、清理建议、AI 或网络业务功能。`notarytool` 只属于构建时发布流程，App 运行时仍不联网。

## 2. 已确认前置事实

### 2.1 当前工程

- bundle identifier：`com.hongdazhu.SpaceJudge`；
- marketing version：`0.3.0`；build：`3`；
- deployment target：macOS 14；
- App Sandbox：关闭；
- Hardened Runtime：当前关闭；
- 隐私清单已声明磁盘空间和文件时间戳 required-reason API，声明不收集数据；
- 工程没有 AppIcon；
- Git 仓库当前没有可发布 commit，全部工作仍是未跟踪工作树。

### 2.2 当前机器

- Xcode 26.6、`notarytool 1.1.2`、`codesign`、`hdiutil`、`stapler` 可用；
- Keychain 中有 Apple Distribution 和 Apple Development 身份；
- **没有** `Developer ID Application` 身份。前两类证书不能用于 Gatekeeper 的站外直接分发签名；
- 因此本阶段可完整实现并验收 credential-independent 路径，但不能把真实签名、公证、发布宣称为已完成。

真实发布还需要：

1. Apple Developer Program 的 Account Holder 或获授权管理员创建并安装 `Developer ID Application` 证书与私钥；
2. 用 `notarytool store-credentials` 把公证凭据保存为一个 Keychain profile；
3. 确认首次公开版的发布主体、bundle ID、版本号和版权文案；
4. 已建立首个干净 Git 基线；正式候选仍必须来自未变化的 clean HEAD，并另行决定版本 tag。

脚本不得创建/撤销证书、读取私钥、打印密码、接受命令行明文密码，或自动修改 Apple Developer 账号。

## 3. 发布产品决策

### 3.1 分发形式

第一版使用一个签名并公证的压缩 DMG：

```text
SpaceJudge-<version>-<build>-universal.dmg
  ├── SpaceJudge.app
  └── Applications -> /Applications
```

不使用 PKG：当前 App 没有 privileged helper、daemon、system extension 或需要安装到多个系统位置的组件，拖入 Applications 更符合最小安装面。不使用 ZIP 作为主产物：ZIP 可以提交公证，但不能直接 staple；DMG 可以签名、公证、staple，并能提供清楚的拖拽安装入口。

不加入自定义安装器、Shell postinstall 或提权。DMG 初版不依赖第三方打包工具或复杂背景图；先保证签名链、布局和可重复流程可靠。

### 3.2 架构与系统版本

- 主发布产物必须同时包含 `arm64` 和 `x86_64`；
- `lipo -archs` 必须精确覆盖两者，不能仅依赖构建日志；
- 最低系统继续为 macOS 14；
- 两种架构来自同一源码、版本和构建号；不分别发布两个 DMG；
- 至少在当前 Apple Silicon Mac 做 arm64 真实启动；x86_64 通过 universal 构建、签名与静态校验，正式发布前仍需一台真实 Intel Mac 或受控 Intel 测试机做一次启动/扫描 smoke。

### 3.3 稳定身份

首次公开版之前默认冻结：

- `CFBundleIdentifier = com.hongdazhu.SpaceJudge`；
- `CFBundleName / Product Name = SpaceJudge`；
- 签名证书类型必须为 `Developer ID Application`；
- 同一发布主体与 bundle ID 用于后续更新。

如果用户决定改为公司 bundle ID 或其他发布主体，必须在第一次公开分发前改，并重跑完整 Phase 5D；首次发布后不把 bundle ID 当普通版本字段修改，因为它参与系统对 App 身份、权限与更新连续性的判断。

## 4. Xcode 与 App 配置

### 4.1 Hardened Runtime

- Release target 设 `ENABLE_HARDENED_RUNTIME = YES`；
- Debug 可保持现状，避免改变现有自动化 seam；
- Release 不启用 App Sandbox，继续遵守 [ADR-0006](adr/0006-direct-distribution-session-access.md)；
- 当前功能不需要 JIT、unsigned executable memory、DYLD environment、disable library validation、debugger、Apple Events 等 Hardened Runtime exception；
- 分发签名的最终 entitlements 允许为空，不得出现 `com.apple.security.get-task-allow = true`；
- 自定义 `codesign` 流程仍显式传 `--options runtime --timestamp`，不只依赖 Xcode build setting。

### 4.2 Info.plist 与隐私

继续保留 `PrivacyInfo.xcprivacy`，并为可能经过选择范围访问的受保护位置添加简短、准确、只读的 usage description：

- Desktop；
- Documents；
- Downloads；
- removable volumes；
- network volumes。

统一语义：SpaceJudge 只读取用户选择范围内的文件名和大小等元数据来绘制空间图，不读取普通文件内容、不修改或删除文件、不上传数据。字符串需进入 `InfoPlist.strings`，至少提供简体中文和英文；Info.plist 中保留英文 fallback。

不添加与真实能力无关的相机、麦克风、联系人、Apple Events、Accessibility、Automation 或网络 entitlement / usage description。

### 4.3 AppIcon

新增完整 `AppIcon.appiconset`，并把 target 的 App Icon 名称设为 `AppIcon`。首版图标是可替换的产品资产，但必须满足发布质量：

- 视觉：柔和浅色底、微信风格绿色强调、由大小不同的圆角矩形组成的 treemap，不含文字或第三方品牌素材；
- 源图 1024×1024，导出 16、32、128、256、512 的 1x/2x PNG；
- 不把低分辨率图简单拉伸为高分辨率；
- 所有 asset catalog slot 完整，Xcode 无缺图警告；
- Codex 在 Finder/Dock 和 16/32/128/1024 尺寸做视觉抽查。

## 5. 两级发布流水线

实现目录固定为：

```text
scripts/release/
  lib.sh
  local-candidate.sh
  distribute.sh
  verify-artifact.sh
  test-release-scripts.sh
docs/runbooks/direct-release.md
```

所有脚本使用 macOS 系统工具，`bash` 严格模式，参数完整引用，不使用 `eval`。临时目录使用 `mktemp -d`，退出时只删除已验证为本次任务目录的路径。默认产物目录为仓库外的显式绝对路径；若支持仓库内 `dist/`，必须加入 `.gitignore`。

### 5.1 本地候选：无发布凭据

`local-candidate.sh` 必须：

1. 读取并校验版本、build、bundle ID、最低系统；
2. 用 `xcodebuild` Release、generic macOS destination、`ARCHS="arm64 x86_64"`、`ONLY_ACTIVE_ARCH=NO`、`CODE_SIGNING_ALLOWED=NO` 生成 app；
3. 复制到任务临时区，执行 ad-hoc 签名并启用 runtime，仅用于本地启动验证；
4. 验证主二进制是 universal2、隐私清单与 AppIcon 在 bundle 内、版本字段一致；
5. `codesign --verify --deep --strict --verbose=2`；检查签名 flag 含 runtime，且 effective entitlements 不含 `get-task-allow` 或任何未批准例外；
6. 生成包含 App 与 Applications symlink 的 DMG；挂载为只读并复核内容后卸载；
7. 产物名必须含 `LOCAL-ADHOC-NOT-FOR-DISTRIBUTION`，manifest 的 `distributionReady` 必须为 false；
8. 不调用 Apple 服务，不运行 `notarytool submit`，不把 ad-hoc 产物放进正式输出名。

这个路径验证的是“源代码可以进入 hardened universal bundle，打包逻辑正确”，不是 Gatekeeper 发布证据。

### 5.2 正式分发：凭据门

`distribute.sh` 必须显式取得：

- Developer ID Application identity label 或 SHA-1；
- `notarytool` Keychain profile 名称；
- 一个全新、绝对输出目录；
- `--release` 明确开关。

并依次完成：

1. 确认 Git 有 HEAD、工作树干净，记录 commit SHA；
2. 确认 signing identity 实际存在且证书类型精确为 Developer ID Application；拒绝 Apple Distribution、Apple Development、ad-hoc 和模糊多匹配；
3. 从同一 commit 构建 universal Release app；
4. 检查 bundle 中所有 Mach-O；当前只允许主 executable。将来出现 helper/framework 时，脚本先失败，直到按 inside-out 顺序显式纳入签名清单，禁止用 `codesign --deep` 掩盖未知嵌套代码；
5. 用 Developer ID Application、secure timestamp、Hardened Runtime 签名 App；
6. 严格验证 signature、architectures、bundle fields、privacy manifest、entitlements 和外部 dylib 路径；
7. 创建并签名 DMG；
8. 运行 `notarytool submit <dmg> --keychain-profile <profile> --wait --output-format json`；
9. 保存 submission ID 和结果，并无论成功与否都下载/保留 notarization log；只有 status 精确为 `Accepted` 才继续；
10. staple DMG，运行 `stapler validate`；
11. 对 DMG 执行 Gatekeeper open assessment，对挂载后的 App 执行 exec assessment和 strict code-sign verify；
12. staple 后计算 SHA-256，并生成最终 release manifest 与人工检查表。

任何步骤失败都不覆盖已有正式产物、不继续上传下一份、不宣称发布成功。上传公证是外部动作，只在用户明确要求生成真实发布候选、凭据门全部通过时执行；脚本本身存在不等于获准上传。

## 6. 凭据与日志边界

- 公证只接受 Keychain profile；发布脚本没有 `--apple-id`、`--password`、API private key 内容参数；
- profile 名和 certificate label 不是秘密，但日志只记录必要标识，不输出 Keychain item 内容；
- 不调用能打印私钥、token 或密码的命令；
- `notarytool` 原始 JSON 与 log 允许保存 submission ID、status、issue 路径，但发布前检查不得包含用户目录或临时绝对路径；
- release manifest 只记录产品版本、build、bundle ID、min OS、architectures、Git commit、SHA-256、签名 Team ID、notarization submission ID/status、生成时间和工具版本；
- 日志目录权限至少 `0700`，文件至少不向 group/other 开放写权限；
- DMG 和 checksum 是可公开产物，原始构建日志默认不是。

## 7. 版本、产物与可追溯性

正式输出：

```text
SpaceJudge-0.3.0-3-universal.dmg
SpaceJudge-0.3.0-3-universal.dmg.sha256
SpaceJudge-0.3.0-3-release.json
SpaceJudge-0.3.0-3-notarization.json
SpaceJudge-0.3.0-3-notarization-log.json
```

规则：

- marketing version 与 build 同时来自构建后的 App bundle，脚本不得自行猜测；
- source Info.plist、Xcode build settings、built bundle 三者不一致时失败；
- 同一 version+build 的正式文件不覆盖；修复后递增 build；
- checksum 只在 staple 和最终验证完成后生成；
- manifest 的 `distributionReady` 只有在 Developer ID、notarization Accepted、stapler 和 Gatekeeper 全部通过后才为 true；
- 当前无 Git commit，因此真实 release gate 必须失败；不能用 `ALLOW_DIRTY=1` 绕过正式模式。

## 8. 权限与首次运行体验

### 8.1 Gatekeeper

用户从浏览器下载 DMG 后：

1. 双击 DMG；
2. 把 SpaceJudge 拖入 Applications；
3. 正常双击启动，不要求右键 Open、不指导关闭 Gatekeeper、不移除 quarantine；
4. 首次启动停在未选择状态，不自动扫描；
5. 用户主动选择目录或磁盘后才开始读取元数据。

如果 Gatekeeper 需要绕过、`xattr -d com.apple.quarantine`、关闭 SIP 或修改系统安全策略，发布验收失败。

### 8.2 Full Disk Access

- App 不私自判断、自动授予或脚本化修改 Full Disk Access；
- 只有真实 EACCES/EPERM 证据才展示“部分位置无法访问”；
- “打开隐私与安全性设置”仅导航到 Full Disk Access 页面，用户自行添加/开启 SpaceJudge；
- 引导说明授权范围较大、仅在用户要检查受保护位置时需要、可以随时关闭；
- 授权后由用户主动重新扫描；App 不监听或推断系统设置变化；
- 没有 Full Disk Access 也能扫描用户明确选择且系统允许的位置。

## 9. 发布级验证矩阵

### 9.1 自动化门

- 全量 Swift tests 与 Phase 5C 性能门不回归；
- Xcode Debug unsigned build；
- Xcode Release universal unsigned build；
- local candidate 脚本真实跑通；
- `bash -n` 与脚本自测通过；自测用 stub 验证错误类型证书、notary rejected、staple 失败、Gatekeeper 失败、已有输出、非法版本和未知嵌套 Mach-O 都 fail-closed；
- bundle 内 `PrivacyInfo.xcprivacy`、AppIcon、Info.plist、两个 architecture 存在；
- ad-hoc local candidate 能在 hardened runtime 下启动、选 fixture、扫描、取消、退出，无 crash/残留进程；
- Release 环境变量不能触发 Debug 测试入口。

### 9.2 凭据就绪后的正式门

- Developer ID App 与 DMG 签名链有效并带 timestamp/runtime；
- effective entitlements 不含 get-task-allow 和未批准 exception；
- notarization status Accepted，完整 log 无未解释 warning；
- stapler validate、DMG Gatekeeper、App Gatekeeper 全部 accepted；
- 浏览器真实下载产生 quarantine 后，在干净标准用户上无需绕过即可安装启动；
- 断网状态下打开已 staple 的 DMG 仍通过 Gatekeeper；
- 真实 Apple Silicon 与 Intel 各完成：安装、启动、选择小目录、看到容量、取消、退出；
- 权限受限路径显示诚实提示，设置入口正确；不给 Full Disk Access 时不崩溃、不虚报完整；
- 覆盖安装上一 build 后，缓存可安全重建，首次启动仍不自动扫描。

### 9.3 视觉与可访问性

- DMG 根只有 App、Applications symlink 和必要隐藏元数据；
- Finder 中 App 名称、图标和版本正确；
- 16/32 px 图标仍可辨认，1024 px 无锯齿或意外透明边；
- 深浅色下 App 本体不回归；
- 权限错误和发布构建中的状态行可由 VoiceOver 访问。

## 10. 发布和回滚

- Phase 5D 验收成功只代表“候选产物可发布”；实际上传到网站、发送给用户或替换公开下载链接仍需用户明确指令；
- 首版不内置 updater，升级方式是下载新 DMG 并替换 Applications 中旧 App；
- 每个公开 build 保留 DMG、SHA-256、release manifest、notarization response/log、对应 Git commit/tag；
- 若公证或 Gatekeeper 失败，废弃该 build number，不重新发布同名不同字节文件；
- 若已公开版本有严重问题，先撤下下载入口并保留证据；不自动远程停用用户 App；证书或 ticket 撤销属于高影响账号操作，必须单独确认；
- 回滚到上一版本也必须使用当时原始 DMG 和 checksum，不能重新打包成相同版本号。

## 11. Pi 实施边界

Pi 本阶段负责：

- Xcode Release hardening、usage descriptions、AppIcon；
- credential-independent 脚本、正式脚本的 fail-closed 实现、脚本测试；
- 本地 universal hardened candidate、DMG、manifest；
- runbook、测试文档和自测报告。

Pi 不得：

- 创建/下载/撤销证书或访问 Apple Developer Portal；
- 读取或输出 Keychain 凭据；
- 用现有 Apple Distribution/Development 身份冒充 Developer ID；
- 运行真实 `notarytool submit`；
- commit、tag、push、上传网站或把产物发送给第三方；
- 绕过 Git、签名、公证、staple、Gatekeeper 任一正式门；
- 增加 updater、网络、遥测、删除、AI 或改变扫描语义。

## 12. Phase 5D 完成定义

Phase 5D 分两次结论：

### 5D-A：Release engineering ready

在无 Developer ID 的当前机器上，只要 Pi 实施完成，Codex 独立复核源代码、脚本 fail-closed、universal local candidate、Hardened Runtime 真实 App smoke、DMG 内容和文档，即可标记 5D-A Accepted。

### 5D-B：Distribution verified

只有在用户提供/安装 Developer ID Application、配置 Keychain notary profile 并明确授权生成真实发布候选后，Codex 才执行并验收正式签名、公证、staple、Gatekeeper、浏览器 quarantine、离线和 Intel/Apple Silicon 矩阵。全部通过后 Phase 5D 才整体 Accepted。

在 5D-B 前，任何本地产物都必须标记为不可分发，项目状态只能是“发布工程已就绪”，不能写成“已经发布”。

## 13. 官方依据

- [Apple：Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Apple：Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)
- [Apple：Configuring the hardened runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime)
- [Apple：Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Apple：Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple：Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Apple：Change Privacy & Security settings on Mac](https://support.apple.com/guide/mac-help/mchl211c911f/mac)
