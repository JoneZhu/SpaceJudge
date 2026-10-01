# Runbook: SpaceJudge 直接分发

2026-10-01 补充：当前产品先走开源源码＋自愿测试版，见[实验性测试包](experimental-build.md)。本 runbook 的 Developer ID 正式分发门不因此放宽；原本 local candidate 仍不可改名发布。

状态：Phase 5D-A 发布工程就绪（等待 Developer ID、notary profile 与干净 commit 后进入 5D-B）。
适用：[Phase 5D 设计](../22-phase-5d-design.md)、[ADR-0010](../adr/0010-developer-id-dmg-release.md)。

本 runbook 描述两条互相隔离的流水线：

- **5D-A 本地候选**：不需要任何发布凭据，产出明确标注不可分发的 universal2 ad-hoc DMG，用于工程验收；
- **5D-B 正式发布**：需要 Developer ID Application 与 notary Keychain profile，且必须来自干净 Git commit。

脚本位于 `scripts/release/`。所有面向使用者的入口（`local-candidate.sh`、`distribute.sh`、`verify-artifact.sh`）在启动时把 `PATH` 固定为 `/usr/bin:/bin:/usr/sbin:/sbin`，不依赖调用者的 `PATH`；`notarytool` 只通过固定的 `/usr/bin/xcrun notarytool` 调用。因此 `PATH` 前部放置的同名工具（`plutil`、`ditto`、`xcrun`、`notarytool`、`security`、`codesign` 等）不会被正式发布流程执行。测试替身只允许在 helper/self-test 范围内使用，且官方入口会拒绝所有 `SJ_*_BIN` override。所有脚本使用 macOS 系统工具，参数完整引用，不使用 `eval`，不接受明文密码，不覆盖既有产物。约定：`<repo>` 是仓库绝对路径，`<output-dir>` 是一个**尚不存在或为空**的绝对目录，`<version>`/`<build>` 例如 `0.3.0`/`3`。

## 1. 一次性人工凭据准备（仅 5D-B，需要账号持有人操作）

脚本不会创建、下载或撤销证书，也不会读写私钥。以下步骤由有权限的人手动完成：

1. 在 Apple Developer Program 中创建 **Developer ID Application** 证书（不是 Apple Distribution、Apple Development 或 Developer ID Installer）。
2. 将证书与私钥导入登录 Keychain，确认可用：

   ```sh
   security find-identity -v -p codesigning
   ```

   输出中必须能看到类型为 `Developer ID Application` 的身份；记录其 label 或 SHA-1。
3. 创建公证 Keychain profile（交互式输入，不写入脚本或 shell 历史）：

   ```sh
   xcrun notarytool store-credentials "<profile-name>" --apple-id "<account>" --team-id "<TEAMID>"
   ```

4. 授权建立一个干净的 commit/tag；正式流水线拒绝无 HEAD 或 dirty 工作树，且没有绕过开关。

## 2. 5D-A：生成并验证本地候选（无凭据）

```sh
bash <repo>/scripts/release/local-candidate.sh \
  --output-dir "<absolute-output-dir>" \
  --repo "<repo>"
```

脚本行为：

1. 在任何路径拼接前校验 version/build/bundle ID/min OS 语法与三源一致性；
2. `xcodebuild` Release、generic macOS、`ARCHS="arm64 x86_64"`、`ONLY_ACTIVE_ARCH=NO`、`CODE_SIGNING_ALLOWED=NO`；
3. 复制到任务临时区，执行 ad-hoc + Hardened Runtime 签名；
4. 校验 universal2、`codesign --verify --deep --strict`、runtime flag、空 entitlements、隐私清单与 AppIcon；
5. 生成包含 `SpaceJudge.app` 与 `Applications -> /Applications` 的 DMG，挂载并校验镜像后卸载；
6. 计算 SHA-256 并写出 manifest，`distributionReady=false`，名称含 `LOCAL-ADHOC-NOT-FOR-DISTRIBUTION`。

脚本在成功和失败时都会回收自己用 `mktemp -d` 创建的任务临时目录（只在 `TMPDIR` 下、名称匹配任务前缀时删除）；`--keep-work` 仅用于显式保留。

产物（`<output-dir>`）：

```text
SpaceJudge-<version>-<build>-universal-LOCAL-ADHOC-NOT-FOR-DISTRIBUTION.dmg
SpaceJudge-<version>-<build>-universal-LOCAL-ADHOC-NOT-FOR-DISTRIBUTION.dmg.sha256
SpaceJudge-<version>-<build>-universal-LOCAL-ADHOC-NOT-FOR-DISTRIBUTION.json
logs/
```

该路径**不调用** Apple 服务、不运行 `notarytool submit`，产物**不可分发**，只是“源码能进入 hardened universal bundle”的工程证据。不要改名后交给用户。

验证（必须同时提供 manifest；脚本会校验 `.dmg.sha256` 的 hash 与文件名、manifest 的 sha256/version/build/bundle ID/min OS/architectures 与挂载后的 App 完全绑定）：

```sh
bash <repo>/scripts/release/verify-artifact.sh \
  --dmg "<output-dir>/SpaceJudge-<version>-<build>-universal-LOCAL-ADHOC-NOT-FOR-DISTRIBUTION.dmg" \
  --mode local \
  --manifest "<output-dir>/SpaceJudge-<version>-<build>-universal-LOCAL-ADHOC-NOT-FOR-DISTRIBUTION.json" \
  --repo "<repo>"
```

## 3. 5D-B：正式签名、公证与发布

先做无副作用的 preflight（不会构建、签名或上传）：

```sh
bash <repo>/scripts/release/distribute.sh --release --preflight-only \
  --output-dir "<absolute-output-dir>" \
  --identity "<Developer ID Application label 或 SHA-1>" \
  --keychain-profile "<profile-name>" \
  --repo "<repo>"
```

preflight 会逐项报告阻断原因：`no-git-head`、`dirty-working-tree`、`signing-identity-not-found`、`signing-identity-wrong-type:*`。只有在本地 Git 与 Developer ID 门全部通过后，preflight 才会用 `notarytool history --keychain-profile ... --output-format json` 做一次**只读**认证检查；它不 submit、不上传任何产物。当前没有 Developer ID 且仓库无 commit 的机器会在本地门就明确失败，**不会**发起任何 Apple 网络请求，这是预期行为。

正式 `distribute.sh` 与 `verify-artifact.sh` 都会拒绝所有 `SJ_*_BIN` 测试工具替换，因此不存在能让真实 `--release` 流程接受 stub 的环境开关。完整流水线在本地门通过后、开始构建前也会做同样的只读 Keychain profile 检查。

全部通过后运行正式流水线：

```sh
bash <repo>/scripts/release/distribute.sh --release \
  --output-dir "<absolute-output-dir>" \
  --identity "<Developer ID Application label 或 SHA-1>" \
  --keychain-profile "<profile-name>" \
  --repo "<repo>"
```

它会：要求干净 HEAD → 校验身份类型 → universal Release 构建 → 拒绝未知嵌套 Mach-O → Developer ID + secure timestamp + runtime 签名 App → 签名 DMG → 再次确认 HEAD/工作树未变化 → `notarytool submit --wait` → 只有 status 精确为 `Accepted` 才继续 → **必须成功下载并校验 notarization log（JSON 有效、status Accepted、无 error issue）** → `stapler staple` 与 `stapler validate` → DMG 与 App 的 Gatekeeper 评估 → 通过后才写 `distributionReady=true` 的 manifest 与 SHA-256。warning issue 不阻断，但会记入 manifest 的 `notarizationWarningCount` 供 5D-B 人工解释。

正式产物：

```text
SpaceJudge-<version>-<build>-universal.dmg
SpaceJudge-<version>-<build>-universal.dmg.sha256
SpaceJudge-<version>-<build>-universal-release.json
SpaceJudge-<version>-<build>-universal-notarization.json
SpaceJudge-<version>-<build>-universal-notarization-log.json
logs/
```

同一 version+build 的正式产物不覆盖；修复后递增 build。上传公证是外部动作，脚本存在不等于获得上传授权。

验证（同样必须提供 manifest，并校验 SHA-256 与 manifest 绑定）：

```sh
bash <repo>/scripts/release/verify-artifact.sh \
  --dmg "<output-dir>/SpaceJudge-<version>-<build>-universal.dmg" \
  --mode release \
  --manifest "<output-dir>/SpaceJudge-<version>-<build>-universal-release.json" \
  --repo "<repo>"
```

## 4. 发布后人工检查

1. 在干净标准用户上从浏览器下载 DMG，双击打开，把 App 拖入 Applications；
2. 正常双击启动，**不需要**右键 Open，不执行 `xattr -d com.apple.quarantine`，不关闭 SIP；
3. 首次启动停在未选择状态，不自动扫描；
4. 主动选择一个小目录，确认容量与空间图，随后取消并退出；
5. 断网打开已 staple 的 DMG 仍能通过 Gatekeeper；
6. 在 Apple Silicon 与 Intel 各做一次安装/启动/选择/取消/退出；
7. 覆盖安装上一 build，确认缓存可安全重建且首次启动仍不自动扫描。

## 5. 回滚

- 公开版本有严重问题时，先撤下下载入口并保留 DMG、SHA-256、manifest、notarization 与对应 commit 作为证据；不自动远程停用用户 App。
- 回滚必须使用当时原始 DMG 与 checksum，不能用相同版本号重新打包。
- 公证或 Gatekeeper 失败时废弃该 build number，修正后递增 build 重跑；不要复用同名不同字节文件。
- 证书或 ticket 撤销属于高影响账号操作，必须单独确认。

## 6. 清理

- 脚本在退出时只删除自己用 `mktemp -d` 创建、且名称匹配任务前缀的临时目录；不会删除 `<output-dir>` 或用户目录。
- 输出目录下的 `logs/` 权限收紧为 `0700`，日志文件不允许 group/other 写入。
- 如需删除本地候选，手动删除该候选专用的 `<output-dir>` 即可；正式产物应长期保留。
- 不要手动删除 `~/Library/Caches/SpaceJudge` 以外的 App 工作缓存；若要清理该缓存，先退出 App。

## 7. 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| preflight 报 `no-git-head` | 正式发布必须来自已提交的 HEAD；建立 commit 后重跑。 |
| preflight 报 `dirty-working-tree` | 提交或丢弃改动；没有 `ALLOW_DIRTY` 之类的绕过开关。 |
| preflight 报 `signing-identity-wrong-type:apple-distribution` | 使用了发布用 Apple Distribution 证书；必须安装 Developer ID Application。 |
| 构建报 bundle 含未知嵌套 Mach-O | 出现了 helper/framework；先在脚本的签名清单里显式按 inside-out 顺序纳入，不要用 `codesign --deep` 掩盖。 |
| DMG 根出现额外文件 | `sj_check_dmg_layout` 会失败；清理 staging，只保留 App 与 Applications symlink。 |
| notary status 不是 `Accepted` | 脚本保留 submission 与 log，修正问题后递增 build。 |
| `stapler validate` 或 `spctl` 失败 | 视为发布失败，不生成 `distributionReady=true` manifest。 |
| notarization log 下载失败、为空或含 error issue | 视为发布失败，不 staple、不生成 ready manifest；warning 会记录数量。 |
| 出现 `refusing test tool override` | 说明环境中设置了 `SJ_*_BIN`；正式路径拒绝这些测试 seam，清除后重试。 |
| 脚本自测失败 | 运行 `bash <repo>/scripts/release/test-release-scripts.sh` 查看 fail-closed 覆盖项。 |
