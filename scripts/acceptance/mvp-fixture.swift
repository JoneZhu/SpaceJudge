#!/usr/bin/env swift
// Independent native MVP acceptance fixture. Writes only inside a fresh,
// owner-only mktemp directory supplied by the caller; never edits user data.
import Darwin
import Foundation

struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

struct ExpectedFile: Codable {
    let relativePath: String
    let kind: String
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let attributedBytes: UInt64
}

struct ExpectedRoot: Codable {
    let rootName: String
    let fileCount: Int
    let directoryCount: Int
    let symbolicLinkCount: Int
    let attributedBytes: UInt64
    let files: [ExpectedFile]
}

struct FixtureManifest: Codable {
    let version: Int
    let generatedAt: Date
    let roots: [ExpectedRoot]
    let note: String
}

let fileManager = FileManager.default

func metadata(_ path: String) throws -> stat {
    var value = stat()
    guard lstat(path, &value) == 0 else {
        throw FixtureFailure(description: "lstat failed with errno \(errno)")
    }
    return value
}

func directory(_ url: URL) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
}

func writeFile(_ url: URL, kib: Int) throws {
    try directory(url.deletingLastPathComponent())
    guard !fileManager.fileExists(atPath: url.path),
          fileManager.createFile(atPath: url.path, contents: nil) else {
        throw FixtureFailure(description: "fixture file already exists or cannot be created")
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let payload = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 19) })
    var remaining = kib * 1024
    while remaining > 0 {
        let length = min(payload.count, remaining)
        try handle.write(contentsOf: payload.prefix(length))
        remaining -= length
    }
}

func sparseFile(_ url: URL) throws {
    try writeFile(url, kib: 0)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 8_000_000_000)
}

func expected(_ root: URL) throws -> ExpectedRoot {
    // Carry relative components explicitly: Foundation may expose /tmp paths
    // as /private/tmp while enumerating, so string prefix lengths are unsafe.
    var stack: [(url: URL, relative: String)] = [(root, "")]
    var directories = 0
    var files: [ExpectedFile] = []
    var symlinks = 0
    var seenIdentities = Set<String>()
    var total: UInt64 = 0
    while let current = stack.popLast() {
        directories += 1
        let entries = try fileManager.contentsOfDirectory(at: current.url,
            includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in entries {
            let relative = current.relative.isEmpty ? url.lastPathComponent
                : current.relative + "/" + url.lastPathComponent
            let info = try metadata(url.path)
            let type = info.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFDIR) {
                stack.append((url, relative))
                continue
            }
            let allocated = UInt64(max(0, info.st_blocks)) * 512
            let logical = UInt64(max(0, info.st_size))
            let kind: String
            let attributed: UInt64
            if type == mode_t(S_IFLNK) {
                symlinks += 1
                kind = "symbolicLink"
                attributed = allocated
            } else if type == mode_t(S_IFREG) {
                kind = "regularFile"
                let identity = "\(info.st_dev):\(info.st_ino)"
                attributed = seenIdentities.insert(identity).inserted ? allocated : 0
            } else {
                throw FixtureFailure(description: "unexpected fixture file kind")
            }
            total += attributed
            files.append(ExpectedFile(relativePath: relative, kind: kind,
                logicalBytes: logical, allocatedBytes: allocated, attributedBytes: attributed))
        }
    }
    return ExpectedRoot(rootName: root.lastPathComponent, fileCount: files.count,
        directoryCount: directories, symbolicLinkCount: symlinks,
        attributedBytes: total, files: files.sorted { $0.relativePath < $1.relativePath })
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 1, arguments[0].hasPrefix("/") else {
        throw FixtureFailure(description: "usage: mvp-fixture.swift NEW_PRIVATE_MKTEMP_DIRECTORY")
    }
    let parent = URL(fileURLWithPath: arguments[0], isDirectory: true).resolvingSymlinksInPath()
    guard ["/tmp", "/private/tmp"].contains(parent.deletingLastPathComponent().path),
          parent.lastPathComponent.hasPrefix("spacejudge-mvp-acceptance.") else {
        throw FixtureFailure(description: "requires a dedicated mktemp directory under /tmp")
    }
    let parentInfo = try metadata(parent.path)
    guard parentInfo.st_uid == geteuid(),
          parentInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          parentInfo.st_mode & 0o077 == 0,
          try fileManager.contentsOfDirectory(atPath: parent.path).isEmpty else {
        throw FixtureFailure(description: "parent must be owned, private and empty")
    }

    let mixed = parent.appendingPathComponent("空间图验收", isDirectory: true)
    let empty = parent.appendingPathComponent("空目录", isDirectory: true)
    let zero = parent.appendingPathComponent("零分配空间", isDirectory: true)
    let outside = parent.appendingPathComponent("不应被符号链接扫描", isDirectory: true)
    for root in [mixed, empty, zero, outside] { try directory(root) }
    let definitions: [(String, Int)] = [
        ("资源库/Developer/DerivedData/编译缓存.bin", 8192),
        ("资源库/Developer/Archives/归档样例.bin", 4096),
        ("资源库/Containers/示例应用/缓存.bin", 6144),
        ("资源库/Caches/缓存样例.bin", 2048),
        ("影片/球场拍摄素材/周六全场原片.mov", 12288),
        ("影片/屏幕录制/产品演示.mov", 4096),
        ("影片/导出视频/验收视频.mp4", 2048),
        ("下载示例不是用户Downloads/压缩包/演示.zip", 4096),
        ("下载示例不是用户Downloads/安装包/演示.dmg", 2048),
        ("项目/示例工程/build/产物.bin", 5120),
        ("项目/示例工程/src/源文件样例.swift", 64),
        ("照片/示例图库.photoslibrary/原片.bin", 6144),
        ("文稿/文档示例.pdf", 1024),
        (".隐藏文件.bin", 32),
        ("很长的名称用于验证布局与换行且不能遮挡旁边的目录与容量数据.bin", 256)
    ]
    for (name, kib) in definitions {
        try writeFile(mixed.appendingPathComponent(name), kib: kib)
    }
    try writeFile(mixed.appendingPathComponent("资源库/空文件"), kib: 0)
    try directory(mixed.appendingPathComponent("资源库/空子目录"))
    let original = mixed.appendingPathComponent("文稿/文档示例.pdf")
    let linked = mixed.appendingPathComponent("文稿/同一文件的硬链接.pdf")
    guard link(original.path, linked.path) == 0 else {
        throw FixtureFailure(description: "hard link creation failed")
    }
    try writeFile(outside.appendingPathComponent("不能进入地图的文件.bin"), kib: 7168)
    guard symlink(outside.path, mixed.appendingPathComponent("外部目录符号链接").path) == 0,
          symlink(mixed.path, mixed.appendingPathComponent("循环符号链接").path) == 0 else {
        throw FixtureFailure(description: "symbolic link creation failed")
    }
    try writeFile(zero.appendingPathComponent("空文件.txt"), kib: 0)
    try sparseFile(zero.appendingPathComponent("逻辑8GB但没有已分配空间.img"))
    try directory(zero.appendingPathComponent("空子目录"))

    let roots = try [mixed, empty, zero].map(expected)
    let manifest = FixtureManifest(version: 1, generatedAt: Date(), roots: roots,
        note: "POSIX lstat st_blocks * 512, regular-file hard links attributed once. Directory metadata blocks excluded. The hard-link owner may differ with enumeration order; total must match. All names and payloads are synthetic.")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(manifest)
    try data.write(to: parent.appendingPathComponent("expected.json"), options: .withoutOverwriting)
    print(String(decoding: data, as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data(("fixture error: \(error)\n").utf8))
    exit(1)
}
