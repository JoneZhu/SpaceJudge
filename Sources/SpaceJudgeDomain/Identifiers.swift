import Foundation

/// Identity for a single scan run. A new scan always gets a new `ScanID`;
/// existing snapshots are never overwritten in place.
public struct ScanID: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public static func random() -> ScanID {
        ScanID()
    }

    public var description: String { rawValue.uuidString }
}

/// Monotonically increasing node identifier inside one scan.
///
/// The identifier is allocated by the scan coordinator; it is not a path and
/// does not survive across scans.
public struct NodeID: Sendable, Equatable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: NodeID, rhs: NodeID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { String(rawValue) }
}

/// Monotonic revision used to invalidate stale incremental snapshots and
/// treemap layouts.
public struct Revision: Sendable, Equatable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var next: Revision { Revision(rawValue &+ 1) }

    public static func < (lhs: Revision, rhs: Revision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { String(rawValue) }
}

/// Identifier into the scan-local name intern table.
///
/// Node records store `parentID + name`; absolute paths are resolved lazily and
/// never stored per node.
public struct NameID: Sendable, Equatable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: NameID, rhs: NameID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { String(rawValue) }
}

/// File identity used for hard-link attribution within a single scan.
///
/// `(deviceID, fileID)` mirrors the `(st_dev, st_ino)` pair. It is meaningful
/// only for one scan against one mounted file system.
public struct FileIdentity: Sendable, Equatable, Hashable {
    public let deviceID: UInt64
    public let fileID: UInt64

    public init(deviceID: UInt64, fileID: UInt64) {
        self.deviceID = deviceID
        self.fileID = fileID
    }
}
