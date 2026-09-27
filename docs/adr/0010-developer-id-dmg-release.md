# ADR-0010：首版使用 Developer ID 公证 DMG 直接分发

状态：Accepted

日期：2026-09-27

## 背景

ADR-0006 已冻结首版为非 Sandbox、用户主动选择、会话级访问的直接分发架构。现在需要把本地可运行的 Xcode App 转化为 Gatekeeper 可接受、身份稳定、可追溯的用户产物。

当前 App 没有 helper、daemon、system extension、登录项或需要写入系统位置的组件，因此不需要 installer package。当前机器也没有 Developer ID Application 证书，不能把 Apple Distribution、Apple Development 或 ad-hoc 签名误当成站外发布签名。

## 备选方案

### A. Mac App Store

自动承担分发和更新，但要求 App Sandbox，并会引入 bookmark、entitlement、审核与全盘扫描兼容性重新设计，不符合当前阶段。

### B. Developer ID + DMG

App 保持非 Sandbox，用户拖入 Applications；App 与 DMG 使用 Developer ID Application 签名，DMG 提交 Apple 公证并 staple。

### C. 未签名 ZIP / DMG

实现最快，但会触发 Gatekeeper 阻止或要求用户绕过安全保护，无法作为可信 MVP 分发方式。

### D. Developer ID Installer PKG

适合需要安装 daemon、helper、system extension 或多个系统位置的产品；当前产品不需要，会扩大权限和卸载复杂度。

## 决策

选择 B。

1. 首版主产物是 universal2 的签名、公证、stapled DMG；
2. App 与 DMG 都使用 Developer ID Application，App 启用 Hardened Runtime 和 secure timestamp；
3. App Sandbox 继续关闭，不添加 Hardened Runtime exception entitlement；
4. 构建时公证只通过 Keychain profile 调用 `notarytool`，不在脚本或参数中保存明文密码；
5. 正式模式必须绑定干净 Git commit，验证签名、公证、staple、Gatekeeper 后才生成 checksum 与 `distributionReady=true` manifest；
6. 无凭据机器只生成名称和 manifest 都明确标注不可分发的 ad-hoc local candidate；
7. 首版没有自动更新器，升级由用户下载新 DMG 替换 App；
8. 实际上传网站或发送用户不由构建脚本自动完成，需要独立授权。

## 原因

- 与既有只读、非 Sandbox、用户主动选择的产品边界一致；
- DMG 对单 App 安装足够简单，且可签名、公证和 staple；
- 两级流水线允许在凭据缺失时完成绝大多数工程验证，同时不会制造“看起来能发布”的假产物；
- 干净 commit、manifest 与 checksum 能把用户拿到的字节追溯到源码和 Apple 公证结果；
- 不引入 updater 或 installer，减少第一版网络、权限与供应链攻击面。

## 后果

- 用户需要手动把 App 拖入 Applications，并手动下载后续版本；
- 发布者必须维护 Apple Developer Program、Developer ID Application 私钥和 notary profile；
- Full Disk Access 仍由用户在系统设置手动决定，签名/公证不会自动获得磁盘权限；
- Developer ID、bundle ID 与发布主体在首次公开版后应保持稳定；
- Intel 兼容会增加构建时间，并要求真实 Intel smoke 作为正式发布门；
- 没有 Developer ID 时只能接受 5D-A，不能宣称 Phase 5D 或发布完成。

## 推翻条件

以下任一情况需要新 ADR：

- 改为 Mac App Store / App Sandbox；
- 引入 privileged helper、daemon、system extension 或 PKG 安装；
- 引入自动更新器；
- 分开发布 arm64 与 x86_64；
- 改变 bundle ID 或发布主体；
- 需要企业内部分发、MDM 或其他签名模式。

## 参考

- [Apple：Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Apple：Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Apple：Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple：Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
