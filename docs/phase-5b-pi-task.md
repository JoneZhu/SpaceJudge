# Phase 5B Pi 实施任务单

## 目标

按照 `docs/18-phase-5b-design.md` 和 `docs/adr/0008-visible-startup-volume-group.md` 实现启动盘可见卷组扫描：公共卷事实识别计划、保留 `SF_FIRMLINK`、允许合法 projection、截断真实 mount point 与未授权设备转换，并提供非递归、路径脱敏的 `spacejudge-volume-plan` 诊断 CLI。

完成产品代码、自动化测试、普通错误修复、必要的架构/扫描/测试文档更新和简短交付报告。不要只搭接口或留 TODO。

## 工作位置

- 项目：`/Users/hongdazhu/Documents/ChatGPT/SpaceJudge`
- 当前分支：`master`
- 当前仓库文件整体尚未提交，全部视为用户/Codex 已有成果，必须保留。
- 不创建 worktree，不切分支，不 commit，不 push，不签名，不公证，不发布。

## 必须先读

1. `docs/18-phase-5b-design.md`
2. `docs/adr/0008-visible-startup-volume-group.md`
3. `docs/17-phase-5a-baseline.md`
4. `docs/03-scan-engine.md`
5. `docs/04-data-and-storage.md`
6. `docs/05-testing-and-acceptance.md`
7. `docs/06-implementation-and-pi.md`
8. `Sources/SpaceJudgeDomain/ScanModel.swift`
9. `Sources/SpaceJudgeScan/DarwinAttributeBufferParser.swift`
10. `Sources/SpaceJudgeScan/FileSystemScanEngine.swift`
11. `Sources/SpaceJudgeAppSupport/AppModel.swift`
12. `Sources/SpaceJudgeStore/SQLiteSchema.swift`

## 已定设计，不得自行改向

- 采用一个统一可见根，不实现 System/Data 双根合并。
- 只有公共 Foundation 事实明确为 `APFS + volume root + root filesystem` 时才选择 visible startup volume group；未知或错误一律降级到原有单文件系统策略。
- 不用路径 `/`、显示名、容量、固定 device ID 猜测；不读 `/usr/share/firmlinks`；不运行或解析 `diskutil`。
- `BoundaryPolicy` 新值只能末尾追加，SQLite 编码固定为 2；旧 0、1 语义不变，不升级表 schema。
- `SF_FIRMLINK` 来自 returned `ATTR_CMN_FLAGS`；mount point 优先级高于 firmlink。
- raw Data mount、VM、Preboot、Update、模拟器 runtime、外接/网络卷等真实 mount point 不得入队。
- firmlink 只授权所需转换，不能变成扫描全局的“允许任意跨设备”。
- symlink 继续不跟随；hard-link、聚合、spool、分页、取消和持久化不变量保持。
- 不把路径、卷 UUID、BSD disk 名、mount-from location 写入 DB、JSON 或日志。
- UI 继续使用 Phase 5A 的中性容量/范围文案，不显示 100% 覆盖或垃圾判断。

## 允许修改

- `Package.swift`
- `Sources/SpaceJudgeDomain`
- `Sources/SpaceJudgeScan`
- `Sources/SpaceJudgeStore` 中枚举编解码与必要接线
- `Sources/SpaceJudgeAppSupport`
- `Sources/SpaceJudgeVolumePlan` 或语义相同的新 CLI target
- `App/SpaceJudgeApp` 中生产依赖接线
- 对应 `Tests/*`
- `docs/02-system-architecture.md`
- `docs/03-scan-engine.md`
- `docs/04-data-and-storage.md`
- `docs/05-testing-and-acceptance.md`
- `docs/references.md`
- 新增 `docs/phase-5b-pi-report.md`

不要把 `docs/18-phase-5b-design.md` 或 ADR 状态改为 Accepted；这由 Codex 独立验收后完成。若设计有无法实现的矛盾，停止扩大修改并在报告中指出。

## 禁止范围

- 删除、废纸篓、清理建议、AI、内容分析、网络、遥测。
- FSEvents、snapshot/clone reclaimable 估算、Full Disk Access 自动化。
- App Sandbox、书签持久化、签名、公证、更新、发布。
- 修改 Phase 4 treemap 面积、裁剪、交互和查询上限。
- 升级 SQLite 表 schema 或持久化绝对路径。
- 管理不属于本任务的进程；禁止 `killall`、`pkill` 或宽泛进程终止。
- 读取凭据或输出任何密钥。

## 实现要求

完整执行 `docs/18-phase-5b-design.md` 第 4–9 节。特别注意：

1. parser 当前已经消费 FLAGS 槽位但未保留事实，修改不得打乱 FILEID/PARENTID offset。
2. 把边界决策抽成纯、可穷举测试的策略，不能继续把所有条件堆在 coordinator 内。
3. 如果 firmlink 打开后 device identity 改变，授权必须局限在该 projection；用工作项状态或打开后的目录事实解决，并写合成测试。
4. planner 使用可注入 facts provider，单元测试不依赖真实机器卷拓扑。
5. AppModel 的生产默认应拿到真实 planner；现有测试构造器尽量保持源兼容或统一补测试依赖。
6. CLI 只枚举 root immediate children，stdout 只有一个 JSON，禁止条目名和完整路径。
7. 每节点热路径不得新增 String、URL、路径或 plan 对象。
8. 所有新增 public 类型有清楚注释；Swift 6 严格并发无警告。

## 必须测试

按设计第 9 节补齐 Domain/Store、parser、boundary matrix、synthetic volume group、planner/AppModel 和 CLI smoke。现有所有测试必须通过。

使用新的任务专属 scratch/DerivedData，不复用 Phase 5A 构建目录。至少运行并记录退出码：

```sh
arch -arm64 swift test --scratch-path <fresh>
arch -arm64 swift build -c release --scratch-path <fresh>
arch -arm64 swift test --sanitize=thread --scratch-path <fresh> \
  --filter 'AppModelTests|ScanEngineTests|PersistingScanRunnerTests'

<release-bin>/spacejudge-volume-plan --root /
<release-bin>/spacejudge-volume-plan --root <fresh-empty-directory>
<release-bin>/spacejudge-e2e-bench --nodes 100000 --shape mixed
<release-bin>/spacejudge-e2e-bench --nodes 1000000 --shape mixed
<release-bin>/spacejudge-e2e-bench --nodes 100000 --shape mixed --cancel-after-first-commit

xcodebuild -project App/SpaceJudge.xcodeproj -scheme SpaceJudge \
  -configuration Debug -derivedDataPath <fresh> CODE_SIGNING_ALLOWED=NO build
xcodebuild -project App/SpaceJudge.xcodeproj -scheme SpaceJudge \
  -configuration Release -derivedDataPath <fresh> CODE_SIGNING_ALLOWED=NO build
```

真实 `/` 只允许运行非递归 volume-plan probe，或显式短时取消且不落大型持久化结果的 smoke。不要完整扫描系统盘作为自测门。

性能期望：10 万 mixed 相对 Phase 5A 总耗时回归不超过 10%；100 万 mixed 峰值 RSS < 250 MB；取消和 FD 门保持。若机器噪声导致超出，报告原始数字与分析，不改测试规模或口径。

## 临时产物与进程

- 临时目录必须由本任务单独创建并保留 marker/确切路径；清理前核对目标，不能使用宽泛递归删除。
- 测试结束后确认没有本任务 App、CLI、测试、xcodebuild 子进程残留。
- 不启动长期服务；如果为 UI smoke 启动 App，报告 PID、启动目录和精确停止方式，并在交付前停止。

## 交付

新增 `docs/phase-5b-pi-report.md`，格式：

- 状态：完成 / 部分完成 / 阻塞
- 已实现：核心行为与关键文件
- 验证：每条命令、实际退出码、测试数量、关键 JSON/性能数字
- 证据：原始日志或产物的绝对路径
- 限制：未验证项和风险
- 服务：是否仍有进程；应为无
- Git：修改范围；明确未 commit/push/publish

完成整个阶段并修复普通错误后统一报告。必要信息缺失、范围冲突，或同一错误经一次有依据修复仍无进展时，停止重试并清楚报告。
