import Darwin
import Foundation
import SpaceJudgeDomain

/// Pure, testable spool arithmetic. Every offset/count update uses reporting
/// overflow and fails explicitly instead of wrapping or trapping.
enum SpoolArithmetic {
    static func advanced(_ value: Int, by amount: Int) throws -> Int {
        let (sum, overflow) = value.addingReportingOverflow(amount)
        guard !overflow, sum >= 0, amount >= 0 else {
            throw ScanError.spoolFailed("spool offset overflow")
        }
        return sum
    }

    static func incremented(_ value: Int) throws -> Int {
        try advanced(value, by: 1)
    }
}

/// Public naming contract for managed directory-spool files.
///
/// The snapshot workspace cleanup whitelist must recognize exactly the same
/// names the spool creates, so the pattern lives here rather than in the
/// internal `DirectorySpool` implementation.
public enum ManagedSpoolNaming {
    public static let filePrefix = "spacejudge-spool-"
    public static let fileSuffix = ".bin"

    /// Whether `name` is exactly `<prefix><UUID><suffix>`. Never matches a
    /// directory, a symlink target or a near-miss name.
    public static func isManagedFileName(_ name: String) -> Bool {
        guard name.hasPrefix(filePrefix), name.hasSuffix(fileSuffix) else {
            return false
        }
        let start = name.index(name.startIndex, offsetBy: filePrefix.count)
        let end = name.index(name.endIndex, offsetBy: -fileSuffix.count)
        guard start < end else { return false }
        return UUID(uuidString: String(name[start..<end])) != nil
    }
}

/// Task-private, length-prefixed temporary spool for directory work items that
/// do not fit in the coordinator's in-memory queue.
///
/// The spool never stores file descriptors: only `nodeID`, optional parent,
/// path bytes, optional device ID and the root marker are encoded. Any attempt
/// to spool a pre-opened descriptor is a fatal error. The backing file is
/// created lazily in the system temporary directory, closed and unlinked by
/// `dispose()` (also from `deinit`).
final class DirectorySpool {
    /// File-name shape of every managed spool file.
    static let managedFilePrefix = ManagedSpoolNaming.filePrefix
    static let managedFileSuffix = ManagedSpoolNaming.fileSuffix

    /// Whether `name` is exactly a managed spool file name.
    static func isManagedFileName(_ name: String) -> Bool {
        ManagedSpoolNaming.isManagedFileName(name)
    }

    private var descriptor: FileDescriptor?
    private var url: URL?
    private let directory: URL
    private var writeOffset: Int = 0
    private var readOffset: Int = 0
    private(set) var count: Int = 0

    var isOpen: Bool { descriptor != nil }

    /// `directory` defaults to the process temporary directory so older call
    /// sites and tests keep working. Production passes the managed workspace
    /// spool directory so one boundary covers the database and the queue.
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.temporaryDirectory
    }

    /// Internal test hook: the backing file, when the spool has been opened.
    var debugFileURL: URL? { url }

    deinit {
        dispose()
    }

    func append(_ item: DirectoryWorkItem) throws {
        guard item.preopened == nil else {
            throw ScanError.spoolFailed("refusing to spool a work item with an open descriptor")
        }
        try ensureOpen()
        guard let descriptor else {
            throw ScanError.spoolFailed("spool descriptor unavailable")
        }
        let payload = try Self.encode(item)
        guard payload.count <= Int(UInt32.max) else {
            throw ScanError.spoolFailed("work item payload too large")
        }
        var frame = [UInt8]()
        frame.reserveCapacity(payload.count + 4)
        Self.appendUInt32(&frame, UInt32(payload.count))
        frame.append(contentsOf: payload)
        try Self.writeAll(descriptor, bytes: frame, at: writeOffset)
        writeOffset = try SpoolArithmetic.advanced(writeOffset, by: frame.count)
        count = try SpoolArithmetic.incremented(count)
    }

    func pop() throws -> DirectoryWorkItem? {
        guard count > 0, let descriptor else { return nil }
        let header = try Self.readExactly(descriptor, count: 4, at: readOffset)
        let length = Self.readUInt32(header, at: 0)
        guard length <= 1 << 24 else {
            throw ScanError.spoolFailed("oversized spool record")
        }
        let payloadOffset = try SpoolArithmetic.advanced(readOffset, by: 4)
        let payload = try Self.readExactly(
            descriptor,
            count: Int(length),
            at: payloadOffset
        )
        readOffset = try SpoolArithmetic.advanced(payloadOffset, by: Int(length))
        count -= 1
        return try Self.decode(payload)
    }

    func dispose() {
        descriptor?.close()
        descriptor = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
            self.url = nil
        }
        writeOffset = 0
        readOffset = 0
        count = 0
    }

    // MARK: - File lifecycle

    private func ensureOpen() throws {
        guard descriptor == nil else { return }
        try Self.ensureDirectory(directory)
        let target = directory.appendingPathComponent(
            "\(ManagedSpoolNaming.filePrefix)\(UUID().uuidString)\(ManagedSpoolNaming.fileSuffix)"
        )
        let raw = target.path.withCString { pointer in
            Darwin.open(pointer, O_RDWR | O_CREAT | O_EXCL, 0o600)
        }
        guard raw >= 0 else {
            throw ScanError.spoolFailed(
                "cannot create spool file: \(String(cString: strerror(errno)))"
            )
        }
        descriptor = FileDescriptor(raw)
        url = target
    }

    /// Creates the spool directory with owner-only permissions when missing.
    /// An existing directory is left as-is; the workspace bootstrap owns
    /// tightening the managed workspace itself.
    private static func ensureDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ScanError.spoolFailed("spool path exists but is not a directory")
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ScanError.spoolFailed("cannot create spool directory")
        }
    }

    // MARK: - Encoding

    private static func encode(_ item: DirectoryWorkItem) throws -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(item.pathBytes.count + 32)
        appendUInt64(&bytes, item.nodeID.rawValue)
        appendUInt8(&bytes, item.parentID == nil ? 0 : 1)
        if let parentID = item.parentID {
            appendUInt64(&bytes, parentID.rawValue)
        }
        appendUInt8(&bytes, item.deviceID == nil ? 0 : 1)
        if let deviceID = item.deviceID {
            appendUInt64(&bytes, deviceID)
        }
        appendUInt8(&bytes, item.isRoot ? 1 : 0)
        appendUInt8(&bytes, item.enteredThroughFirmlink ? 1 : 0)
        guard item.pathBytes.count <= Int(UInt32.max) else {
            throw ScanError.spoolFailed("work item path too large")
        }
        appendUInt32(&bytes, UInt32(item.pathBytes.count))
        bytes.append(contentsOf: item.pathBytes)
        return bytes
    }

    private static func decode(_ payload: [UInt8]) throws -> DirectoryWorkItem {
        var cursor = 0
        func require(_ count: Int) throws {
            guard count >= 0, cursor + count <= payload.count else {
                throw ScanError.spoolFailed("truncated spool record")
            }
        }
        func readUInt8() throws -> UInt8 {
            try require(1)
            defer { cursor += 1 }
            return payload[cursor]
        }
        func readUInt64() throws -> UInt64 {
            try require(8)
            let value = Self.readUInt64(payload, at: cursor)
            cursor += 8
            return value
        }
        func readUInt32Field() throws -> UInt32 {
            try require(4)
            let value = Self.readUInt32(payload, at: cursor)
            cursor += 4
            return value
        }

        let nodeID = NodeID(try readUInt64())
        let hasParent = try readUInt8() != 0
        let parentID = hasParent ? NodeID(try readUInt64()) : nil
        let hasDevice = try readUInt8() != 0
        let deviceID = hasDevice ? try readUInt64() : nil
        let isRoot = try readUInt8() != 0
        let enteredThroughFirmlink = try readUInt8() != 0
        let pathLength = Int(try readUInt32Field())
        try require(pathLength)
        let pathBytes = Array(payload[cursor..<(cursor + pathLength)])
        cursor += pathLength
        guard cursor == payload.count else {
            throw ScanError.spoolFailed("trailing bytes in spool record")
        }
        return DirectoryWorkItem(
            nodeID: nodeID,
            parentID: parentID,
            pathBytes: pathBytes,
            deviceID: deviceID,
            isRoot: isRoot,
            enteredThroughFirmlink: enteredThroughFirmlink,
            preopened: nil
        )
    }

    // MARK: - Little-endian primitives

    private static func appendUInt8(_ bytes: inout [UInt8], _ value: UInt8) {
        bytes.append(value)
    }

    private static func appendUInt32(_ bytes: inout [UInt8], _ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func appendUInt64(_ bytes: inout [UInt8], _ value: UInt64) {
        appendUInt32(&bytes, UInt32(truncatingIfNeeded: value))
        appendUInt32(&bytes, UInt32(truncatingIfNeeded: value >> 32))
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[offset + index]) << (8 * index)
        }
        return value
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << (8 * index)
        }
        return value
    }

    // MARK: - I/O

    private static func writeAll(
        _ descriptor: FileDescriptor,
        bytes: [UInt8],
        at offset: Int
    ) throws {
        var written = 0
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while written < bytes.count {
                let result = Darwin.pwrite(
                    descriptor.rawValue,
                    base.advanced(by: written),
                    bytes.count - written,
                    off_t(offset + written)
                )
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw ScanError.spoolFailed(
                        "spool write failed: \(String(cString: strerror(errno)))"
                    )
                }
                if result == 0 {
                    throw ScanError.spoolFailed("spool write made no progress")
                }
                written += result
            }
        }
    }

    private static func readExactly(
        _ descriptor: FileDescriptor,
        count: Int,
        at offset: Int
    ) throws -> [UInt8] {
        guard count >= 0 else {
            throw ScanError.spoolFailed("negative spool read length")
        }
        var buffer = [UInt8](repeating: 0, count: count)
        var read = 0
        while read < count {
            let result = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.pread(
                    descriptor.rawValue,
                    base.advanced(by: read),
                    count - read,
                    off_t(offset + read)
                )
            }
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                throw ScanError.spoolFailed(
                    "spool read failed: \(String(cString: strerror(errno)))"
                )
            }
            if result == 0 {
                throw ScanError.spoolFailed("spool read made no progress")
            }
            read += result
        }
        return buffer
    }
}
