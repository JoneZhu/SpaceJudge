# 开源源码与自愿测试版

2026-10-01 决策：源码使用 MIT；先提供明确标注、未公证的实验性测试包，不把免费 ad-hoc 签名宣称为 Developer ID 或生产就绪。不需要付费会员即可构建这一测试包。

## 构建与校验

在 macOS 14+、Xcode / Swift 6 环境中，从干净的 Git commit 构建；命令不会联网公证、读取发布凭据、安装应用或改变全局 CLI/MCP 配置。

```sh
bash scripts/release/local-candidate.sh --experimental \
  --output-dir "$(pwd)/output/experimental-v0.5.4"
```

脚本始终重新构建 universal App 和 CLI，先签 CLI，再签 App；将实验标记与源码 commit 写入签名覆盖的 Info.plist。DMG 根目录和 App 资源均包含测试说明，App 内附 MIT 许可证。

2026-10-03 安装引导优化：主界面不再常驻显示实验性／公证状态，状态仍保留在下载说明、包内说明和安装引导，不改变签名、权限或正式发行门禁。欢迎页及“帮助 → 安装与权限帮助”可打开离线图文引导；数据库准备失败时也能进入帮助。新实验包根目录新增 `安装与首次打开.html`，与签名覆盖的 `Contents/Resources/InstallationGuide.html` 完全相同，manifest 新增 `installationGuideSHA256`。校验器拒绝两份不同、缺失、符号链接或未绑定 hash 的引导；旧 v0.5.2 包既无引导也无该 hash 时保持兼容。源码下一版为 0.5.3 / build 8，尚未发布或替换已安装应用。

本轮验收：596 项 Swift 测试、146 项发布脚本测试、5 项引导静态契约检查通过；双架构 Release 编译通过，引导资源与源码字节一致。可运行 `node --test scripts/release/installation-guide.test.mjs` 复验离线页面及 UI 接线契约。真实欢迎页已确认无常驻发布提示，并有安装帮助入口；“帮助”菜单最终入口已在原生 UI 中确认可见并点击，没有出现应用的打开失败提示。默认浏览器中的本地文件最终显示未独立确认，HTML 已在本地浏览器预览并核查章节导航和示意图。GUI 验证发现启动时通过 AppKit 添加帮助项会被 SwiftUI 覆盖，已改为静态 `CommandGroup(replacing: .help)`；扫描菜单的动态策略不变。

随后经用户“替换一下，我感受一下”授权，已将 `/Applications/SpaceJudge.app` 更新到 0.5.3 / build 8 本地预览，并正常打开到欢迎页。更新前原 `/` 扫描处于完成态，通过原生退出菜单关闭，没有中断正在运行的扫描。旧版 0.5.2 / build 7 原包保留在用户 Application Support 下的专用安装备份目录，准确位置仅记录于忽略的本地安装日志；原路径替换失败时安装脚本会恢复旧包。新包明确标为 `local-preview`、`SpaceJudgeLocalPreview=true`、`SpaceJudgeSourceState=dirty`，不是干净源码的实验 Release。原包 CLI 按原字节保留，SHA-256 为 `704a1e1124e8e4057d2d548bffd54b93fc3a33dc3218526c33e3843fdfc3bd7a`，新旧比对、完整签名、版本、HTML 资源和 CLI help 均通过。CLI/MCP/Codex 全局配置和权限设置未修改，未删除用户文件或手动删除快照。安装后的欢迎页和帮助菜单已用原生 UI 确认；前轮两个临时预览实例已正常退出，只保留已安装实例。GitHub v0.5.2 安装资产当时仍未变更。安装证据为同一 output 目录中的 `installed-welcome.png`、`logs/install-prepare.log`、`logs/install-replace.log` 和安装前后哈希记录。需要恢复时，先退出新版，保留新版副本，再将本地日志记录的旧版原包拷回原路径并重新验证签名。

以上 2026-10-03 预览和本机替换证据保存在忽略的 `output/install-guide-20261003/`（日志、引导预览与欢迎页截图）。当时未提交 Git、推送或上传新 Release，公开 v0.5.2 原资产与 tag 不变。当时没有完成新实验 DMG 的端到端构建、真实下载、干净电脑 Gatekeeper 或 Intel 实机验收；实验构建仍要求干净源码 commit，不能把 dirty 预览冒充可发布包。签名预览在临时目录操作：文档云盘为生成目录附加 FinderInfo 导致直接签名失败，重新复制本轮生成的 App 到独立临时目录后签名完整性检查通过；未移除已下载包或已安装应用的 quarantine，也未更改系统安全设置。

当前构建产物命名为 `SpaceJudge-0.5.4-10-universal-EXPERIMENTAL-ADHOC-NOT-NOTARIZED.dmg`，附 `.sha256` 和 `.json` 清单。
校验（在上述构建使用的同一源码版本运行）：

```sh
bash scripts/release/verify-artifact.sh --mode experimental \
  --dmg "$(pwd)/output/experimental-v0.5.4/SpaceJudge-0.5.4-10-universal-EXPERIMENTAL-ADHOC-NOT-NOTARIZED.dmg" \
  --manifest "$(pwd)/output/experimental-v0.5.4/SpaceJudge-0.5.4-10-universal-EXPERIMENTAL-ADHOC-NOT-NOTARIZED.json"
```

清单的 `kind=experimental-adhoc`、`audience=opt-in-testers`、`distributionReady=false`、`notarizationStatus=not-submitted` 不可省略；源码须 clean、commit 要与 App 标记一致，CLI 和测试说明的 hash 须匹配。校验通过证明包内一致性与签名完整性，不证明恶意代码不存在，也不证明下载后 Gatekeeper 会放行。校验值不是可信来源以外的独立身份验证。

原本不带 `--experimental` 的 local candidate 仍为 `LOCAL-ADHOC-NOT-FOR-DISTRIBUTION`，仅本机验收，不能改名后当测试发行。`distribute.sh` 正式签名、公证门不变。测试包不能通过 `verify-artifact.sh --mode release`。

## 测试者安装

1. 从可信项目发布入口取得 DMG、清单、校验值，确认文件名含 EXPERIMENTAL / NOT-NOTARIZED。
2. 打开 DMG，先看 `安装与首次打开.html`（旧包只有 `TESTING-README.txt`），拖 SpaceJudge.app 到“应用程序”。覆盖已有版本前先保留旧应用副本，退出旧版。
3. 未公证包可能被 macOS 拦截。仅在确认来源可信时，按 [Apple 单应用批准说明](https://support.apple.com/102445) 在系统设置“隐私与安全”中处理。选项受系统版本和组织管理策略影响，不承诺每台电脑都能打开。
4. 不提供关闭 Gatekeeper/SIP、移除 quarantine 或绕过企业策略的命令；拒绝安装时可选择源码自编译。
5. 先扫描小型合成目录，验证选择、扫描中出图、取消、导航和刷新。确认权限受限与未完成提示。

最低 macOS 14；App/CLI 包含 Apple Silicon、Intel 两种架构，但 Intel 和干净电脑安装尚未实机验收。外部 Codex 功能需要用户自己安装桌面 Codex。草稿内容与外部 Agent 权限仍由用户确认；不自动清理。

## 上传约定

按用户选择，版本 tag 使用 `v0.5.3` 这类纯版本号，不加 `test.1`；版本号、测试状态和公证状态是不同概念。每次发布须获得明确授权，仍标记 **Pre-release**，并绑定构建清单中的精确 commit；标题和说明首行写“v0.5.3 · 测试版 / 未公证”。仅上传 DMG、`.sha256`、清单和同版测试说明，不上传 `logs/`、扫描数据库、个人路径、备份或整个 output 文件夹。不创建正式稳定版/latest 宣传。

本地输出目录中的 `test1` 只是构建工作目录名，不是对外版本号，也不影响应用本身的 0.5.2。重建时不要覆盖已分享的同版本资产或移动已发布的 tag；如有代码变更，应使用新的版本。

2026-10-01 经用户明确授权，已发布 [v0.5.2 测试版](https://github.com/JoneZhu/SpaceJudge/releases/tag/v0.5.2)。tag 和安装包均对应 `310a694e1233e5406adf81374e476afe33c4ab5f`；README 等后续文档维护在 main，不移动 tag。先上传草稿，再下载四个附件逐项比对 SHA-256，之后公开为 Pre-release、`latest=false`；另从无认证公开地址下载 DMG，校验值与本地包一致。详细说明保存于[版本记录](../releases/v0.5.2.md)。这次发布不替换本机已安装应用。

2026-10-05（北京时间）经用户“发布上去吧”授权，已发布 [v0.5.3 测试版](https://github.com/JoneZhu/SpaceJudge/releases/tag/v0.5.3)。从干净 commit `682bd11baa336fd577d1e54557fddbe337b352a6` 重建 universal App 与 CLI，tag 固定绑定此 commit。596 项 Swift 测试、146 项发布脚本检查、5 项引导检查通过；独立 experimental 包校验与实际 DMG 中 CLI 合成目录扫描、状态、子项、热点、问题及容量查询通过，合成文件哈希未变。四个附件先上传草稿，通过附件 API 下载逐项字节比对后公开为 Pre-release、`latest=false`；再通过无需登录的公开地址下载 DMG，SHA-256 为 `2ca26eddd6d8e6826537a1e5277ab8fc7f4b4179f604749f7982cd2d8b4278fe`，与本地包一致。仅上传 DMG、校验文件、manifest 与测试说明；图文引导随 DMG 提供。公开 v0.5.2 的 tag 和资产不变，本机已安装 App 与全局工具配置不变。尚未完成干净电脑 Gatekeeper、Intel 实机和完整外部 Codex 建议流程验收。产物及私有证据在忽略的 `output/experimental-v0.5.3-20261004/`、`output/v053-draft-download/` 和 `output/v053-public-download.dmg`；文件夹沿用构建开始时的日期。版本说明见 [v0.5.3 记录](../releases/v0.5.3.md)，main 后续文档提交不移动 tag。

代码 SSH 推送权限不等于 Release API 上传权限。发布通过用户在 GitHub 网页批准的 GitHub CLI 授权完成，凭据存于系统 keyring，不写入仓库；本地发布工具与独立配置放在被忽略的 `output/release-tools/`。后续发布仍需检查授权账号和仓库权限，不在聊天、日志或提交中输出 Token。

2026-10-12（北京时间）经用户确认“代码＋v0.5.4 测试版 DMG”，已发布 [v0.5.4](https://github.com/JoneZhu/SpaceJudge/releases/tag/v0.5.4)。0.5.4 / build 10 从干净 commit `86f3d3ac0467020722a7d94a6a3d7646fe254a44` 重建正常身份的 App 和 CLI，未启用独立诊断编译条件。604 项 Swift、146 项发布脚本、16 项采集工具测试（111 个断言）、5 项安装引导检查通过；独立 experimental 验证及实际 DMG 内 CLI 合成目录的扫描／查询通过，合成文件未改动。四个附件上传草稿后，通过认证资产 API 下载逐项比对，再公开为 Pre-release、`latest=false`，之后匿名下载 DMG 核对 SHA256 `df22effecd5586da0135c084133c84eb0979c8f747c8cace5bf3963ace55d59e`。两个旧版本的资产元数据前后相同，tag 不移动。

公开前正常身份的本地候选人工安装及批准成功，具体证据见[启动诊断](startup-diagnostics.md)；这是不同字节的候选，不当作新公开包的首次安装验收，也不宣布永久修复。按用户要求，本机 App、自身缓存和偏好设置已移至可恢复备份，自身 TCC 重置，旧镜像退出；此轮公开包没有自动安装或启动，系统安全批准历史与原始证据保留。完整发布记录见 [v0.5.4](../releases/v0.5.4.md)。私密构建、测试、草稿下载、匿名下载、清理与诊断证据均在被忽略的 output 独立目录；本机路径、扫描库和日志不随附件上传。

若有测试反馈，只提交系统版本、芯片、复现步骤和合成示例；截图/日志须先脱敏。

2026-10-12 发布后的撤回决策：按维护者要求删除 v0.5.4 之前的所有 GitHub 版本，经盘点实际为 v0.5.2、v0.5.3。两份 Release、八个附件和远端标签已删除，v0.5.4 的安装附件与 tag 不变；删除前完整元数据及附件均保存本机私密备份，哈希与 GitHub digest 一致。上文旧版本“已公开”“保留”指历史时刻，不表示当前仍可下载。旧版本文档保留为历史记录；不要把本地备份或保留的旧标签再次整体上传。源码提交历史没有重写。本版真实 GitHub 包后续本机授权启动成功，其他 Mac／Intel 与永久修复仍未验证。

正式对外推广时仍需要 Developer ID + 公证，以及真实下载来源下的 Gatekeeper、Intel/Apple Silicon 安装验收，见[正式发布流程](direct-release.md)。
