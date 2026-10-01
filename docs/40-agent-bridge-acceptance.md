# Agent 桥接：开发预览与本机安装验收记录

历史验收：以下证据对应 0.5.0 build 5。当前安装为 0.5.1 build 6，入口与权限模型已改变，详见[桌面交接与最新安装验收](41-codex-desktop-handoff.md)。不将本页旧测试或隔离承诺套用于外部桌面 Codex。

日期：2026-10-01。执行者：Codex；未使用 Pi。设计与边界见 [39-agent-bridge.md](39-agent-bridge.md)。

## 结论

源码中的原生入口、固定快照导出、ACP 桥接和只读报告 MCP 已实现。用户随后明确要求安装，已切换 `/Applications/SpaceJudge.app` 为本机体验版 0.5.0（build 5），runtime 已打入 App。真实账号登录后的模型分析尚未验收，不是公开发行交付。

没有读取/复制默认 Codex auth 文件，没有把真实用户目录名称或内容发送给模型，没有执行清理。真实适配器 smoke 使用新建的私有临时 home，发送 initialize 和 session/new，**不发送 prompt**；session/new 在没有登录时被拒绝，符合本次验证边界。

## 已验证

| 项目 | 证据/结果 | 不能据此推断 |
| --- | --- | --- |
| Swift 全量回归 | 安装轮 582 tests / 79 suites 通过（开发轮 581） | 不等同于实际模型效果验证 |
| Node/MCP 回归 | 49 tests 通过（含新增 12 项） | 模拟 Agent 的答案不是 Codex 模型输出 |
| 原生构建 | Xcode Debug 及安装轮 Release arm64 构建成功；Release 本机 ad-hoc 签名通过 deep/strict | 不是通用二进制、Developer ID 签名、公证或正式发行包 |
| 真实 ACP | 适配器 2.1.0、Codex 0.159.3，协议 1；未发送 prompt | 没有已登录会话的工具清单验证 |
| 独立 home 复用 | session/new 自动生成 `.system` 与空 plugins 目录后，第二次准备成功 | 不允许额外技能/插件 |
| Node 基线 | Node 20.16.0 与 24.3.0 都完成真实 ACP 初始化及未登录拒绝路径 | 未登录验证不等于全部模型功能兼容 |
| UI 实操 | 0.5.0 安装版扫描 `AgentMCP/test/fixtures` 完成（1 文件 / 1 目录）；分析按钮、精确 B/GB、隐私提示、内置 runtime 路径、展开登录说明及尾部文本完整可见 | 未点击真实分析或触发账号登录 |
| 模拟协议闭环 | Bridge → fake ACP Agent → 真实 stdio Report MCP → scope 查询 → 流式返回；临时报告回收 | 不涵盖实际供应商/账号/模型差异 |

Swift 测试记录已积累在 [swift-regression.log](../output/agent-bridge-20261001/swift-regression.log)。临时构建目录 `/tmp/spacejudge-agent-derived/` 不是稳定分发路径。测试数量以最终日志为准。

新增覆盖：UInt64 极值与精确 GB、范围不导出父级路径、已知空目录、拒绝活动扫描和混合页面 revision、宽目录截断、native 分帧/错误/超量、严格报告 schema、断开的图和虚假完整性、范围外 ID、MCP 路径注入、符号链接和大文件、独立配置防漂移与环境隔离、权限申请全拒绝、filesystem 方法禁用、ACP 畸形/超长/崩溃/超时、非只读模式不发 prompt、启动同步失败的报告清理。

## 验收时修正的实际问题

1. Codex 会自动生成内置 `.system` 技能目录。最初把所有 skills 目录都拒绝，第二次启动将失败；已允许锁定依赖生成的内置资源和空插件目录，继续拒绝用户额外包、插件和符号链接。
2. 原生输出的结束通知与排空 stdout 可能竞态。已用独立持续读取任务和 drain group 等到 stdout/stderr 排空，再按解析器最终状态判断完成。
3. 展开登录说明时尾部文本被压缩裁剪。已增高面板并固定说明文本纵向尺寸；范围大小也增加精确 B 展示，避免小项目只显示 0.00 GB。开发轮截图接口报错；安装轮在 0.5.0 最终应用重新截图确认，全部登录说明和结果区域正常显示。
4. 创建私有报告后若适配器启动同步失败可能残留文件。已将创建/启动纳入 finally 清理，并添加回归测试。大文本 chunk 在 Unicode 字符边界拆分后传给原生面板。

首次在受限执行环境跑全量 Swift 测试卡在 macOS 的 `URL.resourceValues` / CacheDelete 可用容量系统调用。对本次测试 PID 49844 采样确认后终止这个测试进程，以正常本机权限重跑通过。没有改产品容量逻辑来绕过测试环境，也没有停止用户已安装 SpaceJudge。[采样记录](../output/agent-bridge-20261001/restricted-test-stall-sample.txt)已保留。

电脑自动化入口第一次超时，第二次初始化长时间阻塞；后续面板操作正常返回。没有把接口卡住误记成产品扫描卡住。

## 可以复跑

仓库根目录运行 `swift test --disable-sandbox`。受限工具环境需要编译缓存权限及系统容量查询权限；不要据失败环境误判产品逻辑。Xcode 构建命令：

```sh
xcodebuild -quiet -project App/SpaceJudge.xcodeproj -scheme SpaceJudge \
  -configuration Debug -derivedDataPath /tmp/spacejudge-agent-derived \
  CODE_SIGNING_ALLOWED=NO build
```

`AgentMCP` 目录运行：

```sh
npm ci --ignore-scripts
npm test
node scripts/check-acp.mjs
```

最后一条命令只做临时、未登录的 ACP 兼容性检查，不发送磁盘元数据或分析 prompt。失败会清理自身创建的临时目录。

## 正式交付前仍须通过

- 用户自行在独立目录登录 Codex，先用合成报告验证实际工具清单与分析答案，不直接拿真实用户数据做首次试验。
- 验证真实 MCP 调用、中文流式输出、取消/断网/额度不足/认证过期、模型不同 stopReason 的用户提示。
- 原生进程集成测试与退出/强杀后的孤儿进程、TTL 清理策略；本版不承诺强杀也零残留。
- Node/适配器/CLI 的 Intel 与 Apple Silicon 分发、依赖许可、安全审计、打包签名和 UI 设置体验。
- 讨论后续历史/追问能力；清理执行另立授权协议，不默认开放。

以上门槛用于正式交付；本机体验版按用户明确要求提前安装。扫描和内置运行环境可直接使用，真实模型分析仍需用户独立登录及后续验收，不宣称 Agent 端到端已经通过。

## 本机体验版安装（0.5.0 / build 5）

安装路径：`/Applications/SpaceJudge.app`。旧版 0.4.0（build 4）已退出并移动到可恢复备份，未删除应用数据、未替换 CLI、未修改全局 MCP 或默认 Codex 配置。

- 产物与 manifest：[本机体验包](../output/agent-installed-preview-20261001-r3/manifest.json)。原生 App 为 arm64；内置官方 Node 20.16.0 和锁定适配器 2.1.0 / Codex 0.159.3，helper 为 x86_64，使用本机已有 Rosetta。不是 universal2，不含公证。
- 备用只读镜像：[0.5.0 DMG](../output/agent-installed-preview-20261001-r3/SpaceJudge-0.5.0-build5-HOST-LOCAL-PREVIEW.dmg)。散装 App 在文稿 File Provider 目录被自动补写 FinderInfo，故使用无扩展属性复制后在暂存和最终 `/Applications` 路径再次通过 deep/strict 校验，不关闭系统安全保护。
- 旧版备份：[0.4.0 App](../output/agent-installed-preview-20261001-r3/backup/SpaceJudge-0.4.0-build4.app)。回滚前退出应用，将当前版本移动到另一个新备份位置；把旧版通过 `ditto --norsrc --noextattr --noqtn` 复制回 `/Applications/SpaceJudge.app`，重新校验签名后启动。不要覆盖仍在运行的应用或直接删除新版本。
- 安装版主二进制 SHA256：`78d3fcc5e7ce917a12ff958cf6eaf3ad4df1049fdbc1a05f4eb9ae52017177bd`；旧版备份与安装前一致：`effc7a672cae838a064fbef94ab570b5f94625c5349f125971892c1d9b08b7ef`。
- 新增回归验证：只有 App 同时包含桥接文件和可执行 Node 才启用内置路径发现；内置路径优先于过期开发设置。目录访问提示改为「默认不上传；主动发起 Codex 分析才发送选中范围元数据」，不再作错误的绝对不上网承诺。
- 安装轮日志：[Swift 582 项](../output/agent-installed-preview-20261001-r3/logs/swift-regression.log)、[Node/MCP 49 项](../output/agent-installed-preview-20261001-r3/logs/node-regression.log)、[最终安装路径 runtime smoke](../output/agent-installed-preview-20261001-r3/logs/installed-runtime-smoke.log)。合成报告验证三个只读 MCP 工具、空目录与 bytes/GB；ACP 协议 1 初始化通过，未登录会话被拒绝，独立 home 可复用，未发送 prompt。

打包脚本为 `scripts/release/agent-local-preview.mjs`。只安装 lockfile 固定的生产依赖，不运行 npm 生命周期脚本；保留官方 Node 和 vendor helper 的原签名与 Node JIT 权限，再签主 App。输出目录必须全新，不覆盖已有产物。Node 路径、arm64 主 App 与 x86_64 helper 组合仅用于当前机器的体验包；正式分发不能复用硬编码架构假设。

可用安装包内的 Node 在仓库根目录复验（合成报告，不登录、不发送模型请求）：

```sh
/Applications/SpaceJudge.app/Contents/Resources/AgentRuntime/bin/node \
  AgentMCP/scripts/check-packaged-runtime.mjs \
  --runtime /Applications/SpaceJudge.app/Contents/Resources/AgentRuntime
```
