# Phase 0 验收基线

状态：Accepted

验收日期：2026-09-26

## 1. 交付结果

Phase 0 已建立无第三方依赖的 Swift Package：

- `SpaceJudgeDomain`：扫描标识、请求、节点、批次、进度、错误、终态、容量对账与核心协议。
- `SpaceJudgeTreemap`：平台无关几何、确定性 squarified treemap、可见性与“其他”聚合。
- `spacejudge-core-smoke`：固定内存树到稳定 JSON 的最小可执行入口。
- Domain / Treemap 测试：57 项，9 个 suite。

最低目标 macOS 14，Swift tools 6.0；未引入 Darwin 枚举、SQLite、SwiftUI 或真实磁盘访问。

## 2. Codex 独立验收

实际运行：

```sh
arch -arm64 swift test
arch -arm64 swift build -c release
arch -arm64 swift run spacejudge-core-smoke
```

结果：

- 57 tests / 9 suites 通过，退出码 0。
- Release build 通过，退出码 0，无编译 warning。
- smoke CLI 运行两次，输出逐字节一致且为有效 JSON。
- `swift package show-dependencies` 显示无外部依赖。
- `.build/` 已加入 `.gitignore`。
- 现有 HTML、README、设计文档和 Playwright 证据未被 Pi 修改。

当前 Codex 桌面 shell 运行在 Rosetta 环境，而 Swift 工具链产物是 arm64。裸 `swift test` 会在 XCTest 预检阶段报告架构不匹配；使用原生 `arch -arm64 swift test` 正常退出 0。该问题不来自包内架构配置，代码中没有硬编码目标架构。

## 3. 第一轮退回问题

Pi 首次交付能编译且 46 项测试通过，但未直接验收。Codex 发现并退回：

1. `ScanRoot` 只有展示路径，扫描器拿不到真实访问路径。
2. treemap 的 `UInt64` 权重和溢出时会得到 0，导致全部矩形退化。
3. “其他”节点只借用一个小节点的矩形，权重与面积不一致。
4. 目录重复完成会被二次归属，聚合查询还会静默钳位溢出。
5. SwiftPM `.build/` 没有忽略。

修正后新增 11 项回归测试，最终总数 57。

## 4. 冻结的核心语义

- `ScanRoot.fileSystemPath` 是本次请求的运行期访问路径，`displayName` 独立用于 UI。
- unknown size 使用 Optional，与真实 0 区分。
- hard link 按 `(deviceID, fileID)` 第一次归属，后续 attributed bytes 为 0。
- 字节聚合溢出必须显式失败；treemap 总权重只能饱和并标记 overflow，不能 wrapping。
- 目录完成后不可追加；同一目录不可重复完成；子目录不可写入已完成父级。
- treemap 先按稳定键排序；相同集合不受输入顺序影响。
- 小节点合并成“其他”后必须重新布局，最终可绘制矩形完整覆盖、互不重叠且面积与权重成比例。
- UI、FD、裸指针、SQLite 不得进入 Domain public API。

## 5. 当前已知边界

- `NodeRecord` 的 attributed <= allocated 尚未在初始化时强制；真实扫描器进入聚合前必须校验并测试。
- Phase 0 没有验证 APFS、权限、符号链接、挂载点或真实文件名编码。
- treemap 使用 Double 计算几何；极端 UInt64 权重已测试溢出行为，但真实 UI 仍需像素级裁剪与性能基准。
- 原始 Pi 会话与完整日志保存在任务临时目录，不作为项目知识库；本文件只保留可复用结论。

## 6. Phase 1 进入条件

- 不改变上述冻结语义；若必须改变，先更新 ADR。
- 先实现 ReferenceEnumerator 和二进制属性解析器，再接 `getattrlistbulk`。
- 所有真实文件系统事实通过 `NodeBatch` 进入现有协议。
- Phase 1 必须增加临时目录差分测试、截断 buffer 测试、硬链接 / 稀疏文件 / symlink / 取消 / FD 泄漏检查。
