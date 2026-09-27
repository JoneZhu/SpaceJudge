# 技术参考

核对日期：2026-09-27。

## Apple / Darwin

- `man 2 getattrlistbulk`：批量枚举目录属性；要求 `ATTR_CMN_NAME` 与 `ATTR_CMN_RETURNED_ATTRS`，条目顺序未定义；mount point 在 `ATTR_DIR_MOUNTSTATUS` 中带 `DIR_MNTSTATUS_MNTPOINT`（`0x00000001`），firmlink 在 `ATTR_CMN_FLAGS` 中带 `SF_FIRMLINK`（`0x00800000`），bulk 返回的是这两个目录项自身而非穿越后的目标属性。
- macOS SDK `usr/include/sys/stat.h`、`usr/include/sys/attr.h`：`SF_FIRMLINK`、`DIR_MNTSTATUS_MNTPOINT` 等公开常量。
- `man 2 open` / `fstat`：不使用 `O_NOFOLLOW` 以外的方式解析路径；firmlink 不是 symlink，路径遍历会透明进入投影目标。
- `man 2 getattrlist`：`ATTR_FILE_TOTALSIZE` 是所有 fork 的逻辑大小；`ATTR_FILE_ALLOCSIZE` 是所有 fork 在磁盘上的分配大小；`ATTR_CMN_FILEID` 对应 inode 身份。
- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)：用户选择目录、security-scoped access 与持久书签。
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)：沙箱文件访问能力和 user-selected file entitlement。
- [volumeAvailableCapacityForImportantUsageKey](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforimportantusagekey)：重要用途可用容量及 Required Reason API 要求。
- [Checking Volume Storage Capacity](https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity)：通过卷上的 URL 查询容量，区分重要用途和机会用途的可用空间。
- [Role of Apple File System](https://support.apple.com/en-ie/guide/security/seca6147599e/web)：APFS space sharing、clone、snapshot，以及现代 macOS System/Data volume 的职责。
- [WWDC19: What's New in Apple File Systems](https://developer.apple.com/videos/play/wwdc2019/710/)：System/Data volume group 与 firmlink 的官方说明。
- [mountedVolumeURLs](https://developer.apple.com/documentation/foundation/filemanager/mountedvolumeurls(includingresourcevaluesforkeys:options:))：列举 macOS 已挂载卷的 Foundation API；可能发生阻塞 I/O。
- [URL volume resource keys](https://developer.apple.com/documentation/foundation/urlresourcekey)：`isVolumeKey`、`volumeIsRootFileSystemKey`、`volumeTypeNameKey`、`volumeIsLocalKey` 等公共卷事实；Phase 5B planner 只用这些公共键。
- [SwiftUI Canvas](https://developer.apple.com/documentation/swiftui/canvas)：复杂 2D 绘制的性能特点，以及逐元素交互 / 可访问性的限制。
- [Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)：可再生成缓存应放在 Caches；Application Support 适合需要持续保存的支持数据。
- [SQLite PRAGMA](https://www.sqlite.org/pragma.html)：`auto_vacuum=INCREMENTAL` 必须在建表前启用；`incremental_vacuum` 回收 freelist；`wal_checkpoint(TRUNCATE)` 成功时截断 WAL。
- [SQLite VACUUM](https://www.sqlite.org/lang_vacuum.html)：普通 `VACUUM` 会重建数据库，可能需要接近原库两倍的额外空间，因此不适合作为低空间保护路径。
- [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)：站外分发 Mac App 使用 Developer ID Application；installer package 使用 Developer ID Installer，不能用 Apple Distribution / Development 代替。
- [Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)：站外公证分发需要 Hardened Runtime，App Sandbox 可选。
- [Configuring the hardened runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime)：默认保持运行时保护，仅为真实需要添加最小例外；公证要求启用 Hardened Runtime。
- [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)：自定义 Developer ID 签名使用 secure timestamp 与 runtime option，并按 executable 显式处理 entitlement。
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)：Apple 公证服务检查恶意内容和签名问题，并生成可 staple 的 ticket。
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)：使用 `notarytool`、Keychain profile、`--wait`、公证 log 与 `stapler`；ZIP 不能直接 staple，DMG 可以。
- [macOS Privacy & Security settings](https://support.apple.com/guide/mac-help/mchl211c911f/mac)：Full Disk Access 由用户在系统设置中手动管理；它允许 App 访问其他 App 数据、Time Machine 备份及部分管理设置。
- [Human Interface Guidelines: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)：macOS App 图标的形状、栅格与尺寸建议；本项目按 16–1024 每个 slot 独立绘制。
- [Building a universal macOS binary](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary)：同时包含 `arm64` 与 `x86_64` 的 universal 产物要求，以及 `lipo` 校验方式。
- [man hdiutil](x-man-page://hdiutil)：`create`/`attach`/`detach`、只读挂载与 `UDZO` 压缩镜像；本地候选的 DMG 生成与复核使用这些公开选项。
- [man stapler](x-man-page://stapler) / [man spctl](x-man-page://spctl)：`staple validate` 与 Gatekeeper `--assess` 的退出码语义；正式发布把这些非零退出视为失败关闭。
- [Desktop folder usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsdesktopfolderusagedescription)：用户通过 Open/Save panel 选择会形成明确访问意图；未由选择覆盖的首次访问可能触发系统提示，usage description 应解释用途。
- [Removable volumes usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsremovablevolumesusagedescription)：可移动卷访问的目的说明；同组还包括 Documents、Downloads 和 network volumes。

文档中的性能目标与实现取舍还需要项目自身基准验证；引用系统 API 文档不等于已经证明性能。
