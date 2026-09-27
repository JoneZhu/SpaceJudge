# ADR-0001：采用 Swift 原生分层实现

状态：Accepted

## 背景

产品要求 macOS 上大规模文件扫描与高帧率 treemap。HTML 原型只用于交互验证。

## 决策

使用 Swift 6；SwiftUI 管应用状态与标准界面，AppKit/Core Graphics 负责 treemap，Darwin API 负责批量扫描，SQLite3 负责快照。

## 后果

- 可以直接使用 macOS 权限、Finder、容量和批量属性 API。
- 扫描和渲染热路径可独立基准。
- 需要维护 SwiftUI / AppKit 桥接和低层 buffer parser。
- 第一版不做跨平台。
