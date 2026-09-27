import Foundation

/// Filesystem object kinds tracked by the scan engine.
public enum NodeKind: Sendable, Equatable, Hashable, Codable, CaseIterable {
    case directory
    case regularFile
    case symbolicLink
    case socket
    case fifo
    case characterDevice
    case blockDevice
    /// A directory that is the root of another mounted file system.
    case mountPoint
    case unknown

    /// Returns `true` for kinds that can own children and may be descended into
    /// when the boundary policy allows it.
    public var isDirectoryLike: Bool {
        switch self {
        case .directory, .mountPoint:
            return true
        case .regularFile, .symbolicLink, .socket, .fifo,
             .characterDevice, .blockDevice, .unknown:
            return false
        }
    }
}

/// Bit flags describing optional node facts. Flags never change core size
/// semantics; they only annotate a node.
public struct NodeFlags: OptionSet, Sendable, Equatable, Hashable, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UInt32.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Finder-style bundle that is still a real directory on disk.
    public static let package = NodeFlags(rawValue: 1 << 0)
    /// A hard-link occurrence after the first one for the same `FileIdentity`.
    public static let duplicateHardLink = NodeFlags(rawValue: 1 << 1)
    /// The node was discovered but could not be fully read.
    public static let inaccessible = NodeFlags(rawValue: 1 << 2)
    /// A mount point boundary that was not crossed.
    public static let mountBoundary = NodeFlags(rawValue: 1 << 3)
    /// Allocated size may be smaller than logical size (sparse file).
    public static let sparse = NodeFlags(rawValue: 1 << 4)
    /// The node changed or disappeared while the scan was running.
    public static let changedDuringScan = NodeFlags(rawValue: 1 << 5)
    /// A symlink loop was detected and not followed.
    public static let symlinkLoop = NodeFlags(rawValue: 1 << 6)
    /// The allocation may be shared with an APFS clone; metering is advisory.
    public static let clonedAllocation = NodeFlags(rawValue: 1 << 7)
    /// A fallback enumerator was used because the fast path was unavailable.
    public static let fallbackEnumerator = NodeFlags(rawValue: 1 << 8)
    /// The directory is a system-published firmlink projection into the paired
    /// startup volume group member. It is not a symlink, not a mount point and
    /// not an error; it records the fact that traversal was authorized to cross
    /// into the projected data directory.
    public static let firmlinkProjection = NodeFlags(rawValue: 1 << 9)
    /// The directory is SpaceJudge's own snapshot working area. It is kept as a
    /// visible leaf node so the UI can show that its bytes were deliberately not
    /// attributed, but its children are never enumerated.
    public static let snapshotStorageBoundary = NodeFlags(rawValue: 1 << 10)
}

/// A single immutable fact record produced by the scan engine.
///
/// `logicalBytes` and `allocatedBytes` are optional so that "unknown" is never
/// confused with a genuine zero. `attributedBytes` is always known after the
/// hard-link policy has been applied and is the value used for directory
/// aggregation and the default treemap weight.
public struct NodeRecord: Sendable, Equatable, Hashable, Codable {
    public let id: NodeID
    public let scanID: ScanID
    public let parentID: NodeID?
    public let name: NameID
    public let kind: NodeKind
    public let flags: NodeFlags
    public let logicalBytes: UInt64?
    public let allocatedBytes: UInt64?
    public let attributedBytes: UInt64
    public let modifiedAt: Date?
    public let deviceID: UInt64?
    public let fileID: UInt64?

    public init(
        id: NodeID,
        scanID: ScanID,
        parentID: NodeID?,
        name: NameID,
        kind: NodeKind,
        flags: NodeFlags = [],
        logicalBytes: UInt64?,
        allocatedBytes: UInt64?,
        attributedBytes: UInt64,
        modifiedAt: Date? = nil,
        deviceID: UInt64? = nil,
        fileID: UInt64? = nil
    ) {
        self.id = id
        self.scanID = scanID
        self.parentID = parentID
        self.name = name
        self.kind = kind
        self.flags = flags
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.attributedBytes = attributedBytes
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.fileID = fileID
    }

    /// The hard-link identity of this node, when the file system reported both
    /// the device and file identifiers.
    public var fileIdentity: FileIdentity? {
        guard let deviceID, let fileID else { return nil }
        return FileIdentity(deviceID: deviceID, fileID: fileID)
    }
}

/// A scan-local name fact. `utf8` holds the raw bytes returned by the file
/// system so invalid UTF-8 can still be represented and reported.
public struct NameRecord: Sendable, Equatable, Hashable, Codable {
    public let id: NameID
    public let utf8: Data

    public init(id: NameID, utf8: Data) {
        self.id = id
        self.utf8 = utf8
    }

    public init(id: NameID, bytes: [UInt8]) {
        self.id = id
        self.utf8 = Data(bytes)
    }

    /// Raw name bytes as an array.
    public var bytes: [UInt8] { Array(utf8) }

    /// Strict UTF-8 decoding. `nil` when the raw bytes are not valid UTF-8.
    public var decodedString: String? {
        String(data: utf8, encoding: .utf8)
    }
}

/// Final (or best-effort terminal) totals for one directory subtree.
///
/// Directory facts are not immutable: they can only be finalized once all of a
/// directory's descendants are known. The scan engine therefore upserts these
/// records by `nodeID`; a record with `isComplete == true` is final and must
/// never change afterwards.
public struct DirectoryAggregateRecord: Sendable, Equatable, Hashable, Codable {
    public let nodeID: NodeID
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    public let attributedBytes: UInt64
    public let descendantFileCount: UInt64
    public let descendantDirectoryCount: UInt64
    public let inaccessibleDescendantCount: UInt64
    public let isComplete: Bool

    public init(
        nodeID: NodeID,
        logicalBytes: UInt64,
        allocatedBytes: UInt64,
        attributedBytes: UInt64,
        descendantFileCount: UInt64,
        descendantDirectoryCount: UInt64,
        inaccessibleDescendantCount: UInt64,
        isComplete: Bool
    ) {
        self.nodeID = nodeID
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.attributedBytes = attributedBytes
        self.descendantFileCount = descendantFileCount
        self.descendantDirectoryCount = descendantDirectoryCount
        self.inaccessibleDescendantCount = inaccessibleDescendantCount
        self.isComplete = isComplete
    }
}

/// A batch of node facts. Batches are the unit of progress and UI refresh;
/// individual files are never surfaced as events.
///
/// `names` carries any `NameRecord` first referenced by this batch's nodes, and
/// `directoryAggregates` carries finalized directory totals. Both default to an
/// empty array so existing call sites keep working.
public struct NodeBatch: Sendable, Equatable, Hashable, Codable {
    public let scanID: ScanID
    public let revision: Revision
    public let names: [NameRecord]
    public let nodes: [NodeRecord]
    public let directoryAggregates: [DirectoryAggregateRecord]

    public init(
        scanID: ScanID,
        revision: Revision,
        names: [NameRecord] = [],
        nodes: [NodeRecord],
        directoryAggregates: [DirectoryAggregateRecord] = []
    ) {
        self.scanID = scanID
        self.revision = revision
        self.names = names
        self.nodes = nodes
        self.directoryAggregates = directoryAggregates
    }
}
