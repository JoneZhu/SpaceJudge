# 开源源码与自愿测试版

2026-10-01 决策：源码使用 MIT；先提供明确标注、未公证的实验性测试包，不把免费 ad-hoc 签名宣称为 Developer ID 或生产就绪。不需要付费会员即可构建这一测试包。

## 构建与校验

在 macOS 14+、Xcode / Swift 6 环境中，从干净的 Git commit 构建；命令不会联网公证、读取发布凭据、安装应用或改变全局 CLI/MCP 配置。

```sh
bash scripts/release/local-candidate.sh --experimental \
  --output-dir "$(pwd)/output/experimental-0.5.2-test1"
```

脚本始终重新构建 universal App 和 CLI，先签 CLI，再签 App；将实验标记与源码 commit 写入签名覆盖的 Info.plist。应用底部显示“实验性测试版 · 未经过 Apple 公证”。DMG 根目录和 App 资源均包含测试说明，App 内附 MIT 许可证。

产物命名为 `SpaceJudge-0.5.2-7-universal-EXPERIMENTAL-ADHOC-NOT-NOTARIZED.dmg`，附 `.sha256` 和 `.json` 清单。
校验（在上述构建使用的同一源码版本运行）：

```sh
bash scripts/release/verify-artifact.sh --mode experimental \
  --dmg "$(pwd)/output/experimental-0.5.2-test1/SpaceJudge-0.5.2-7-universal-EXPERIMENTAL-ADHOC-NOT-NOTARIZED.dmg" \
  --manifest "$(pwd)/output/experimental-0.5.2-test1/SpaceJudge-0.5.2-7-universal-EXPERIMENTAL-ADHOC-NOT-NOTARIZED.json"
```

清单的 `kind=experimental-adhoc`、`audience=opt-in-testers`、`distributionReady=false`、`notarizationStatus=not-submitted` 不可省略；源码须 clean、commit 要与 App 标记一致，CLI 和测试说明的 hash 须匹配。校验通过证明包内一致性与签名完整性，不证明恶意代码不存在，也不证明下载后 Gatekeeper 会放行。校验值不是可信来源以外的独立身份验证。

原本不带 `--experimental` 的 local candidate 仍为 `LOCAL-ADHOC-NOT-FOR-DISTRIBUTION`，仅本机验收，不能改名后当测试发行。`distribute.sh` 正式签名、公证门不变。测试包不能通过 `verify-artifact.sh --mode release`。

## 测试者安装

1. 从可信项目发布入口取得 DMG、清单、校验值，确认文件名含 EXPERIMENTAL / NOT-NOTARIZED。
2. 打开 DMG，阅读 `TESTING-README.txt`，拖 SpaceJudge.app 到“应用程序”。覆盖已有版本前先保留旧应用副本，退出旧版。
3. 未公证包可能被 macOS 拦截。仅在确认来源可信时，按 [Apple 单应用批准说明](https://support.apple.com/102445) 在系统设置“隐私与安全”中处理。选项受系统版本和组织管理策略影响，不承诺每台电脑都能打开。
4. 不提供关闭 Gatekeeper/SIP、移除 quarantine 或绕过企业策略的命令；拒绝安装时可选择源码自编译。
5. 先扫描小型合成目录，验证选择、扫描中出图、取消、导航和刷新。确认权限受限与未完成提示。

最低 macOS 14；App/CLI 包含 Apple Silicon、Intel 两种架构，但 Intel 和干净电脑安装尚未实机验收。外部 Codex 功能需要用户自己安装桌面 Codex。草稿内容与外部 Agent 权限仍由用户确认；不自动清理。

## 上传约定

按用户选择，版本 tag 使用 `v0.5.2`，不加 `test.1`；版本号、测试状态和公证状态是不同概念。每次发布须获得明确授权，仍标记 **Pre-release**，并绑定构建清单中的精确 commit；标题和说明首行写“v0.5.2 · 测试版 / 未公证”。仅上传 DMG、`.sha256`、清单和同版测试说明，不上传 `logs/`、扫描数据库、个人路径、备份或整个 output 文件夹。不创建正式稳定版/latest 宣传。

本地输出目录中的 `test1` 只是构建工作目录名，不是对外版本号，也不影响应用本身的 0.5.2。重建时不要覆盖已分享的同版本资产或移动已发布的 tag；如有代码变更，应使用新的版本。

2026-10-01 经用户明确授权，已发布 [v0.5.2 测试版](https://github.com/JoneZhu/SpaceJudge/releases/tag/v0.5.2)。tag 和安装包均对应 `310a694e1233e5406adf81374e476afe33c4ab5f`；README 等后续文档维护在 main，不移动 tag。先上传草稿，再下载四个附件逐项比对 SHA-256，之后公开为 Pre-release、`latest=false`；另从无认证公开地址下载 DMG，校验值与本地包一致。详细说明保存于[版本记录](../releases/v0.5.2.md)。这次发布不替换本机已安装应用。

代码 SSH 推送权限不等于 Release API 上传权限。发布通过用户在 GitHub 网页批准的 GitHub CLI 授权完成，凭据存于系统 keyring，不写入仓库；本地发布工具与独立配置放在被忽略的 `output/release-tools/`。后续发布仍需检查授权账号和仓库权限，不在聊天、日志或提交中输出 Token。

若有测试反馈，只提交系统版本、芯片、复现步骤和合成示例；截图/日志须先脱敏。

正式对外推广时仍需要 Developer ID + 公证，以及真实下载来源下的 Gatekeeper、Intel/Apple Silicon 安装验收，见[正式发布流程](direct-release.md)。
