import Foundation
import SpaceJudgeDomain

/// Stable integer encodings for domain enums stored in SQLite. The raw values
/// are frozen in schema v1; adding a case must append, never renumber.
enum SchemaEncoding {
    static func encode(_ value: SizeMetric) -> Int64 {
        switch value {
        case .allocated: return 0
        case .logical: return 1
        }
    }

    static func decodeSizeMetric(_ value: Int64) throws -> SizeMetric {
        switch value {
        case 0: return .allocated
        case 1: return .logical
        default: throw SnapshotStoreError.unknownEnumValue(column: "size_metric", value: value)
        }
    }

    static func encode(_ value: BoundaryPolicy) -> Int64 {
        switch value {
        case .selectedTree: return 0
        case .stayOnRootFileSystem: return 1
        case .visibleStartupVolumeGroup: return 2
        }
    }

    static func decodeBoundaryPolicy(_ value: Int64) throws -> BoundaryPolicy {
        switch value {
        case 0: return .selectedTree
        case 1: return .stayOnRootFileSystem
        case 2: return .visibleStartupVolumeGroup
        default: throw SnapshotStoreError.unknownEnumValue(column: "boundary_policy", value: value)
        }
    }

    static func encode(_ value: PackagePolicy) -> Int64 {
        switch value {
        case .descend: return 0
        case .treatAsLeaf: return 1
        }
    }

    static func decodePackagePolicy(_ value: Int64) throws -> PackagePolicy {
        switch value {
        case 0: return .descend
        case 1: return .treatAsLeaf
        default: throw SnapshotStoreError.unknownEnumValue(column: "package_policy", value: value)
        }
    }

    static func encode(_ value: SymlinkPolicy) -> Int64 {
        switch value {
        case .doNotFollow: return 0
        }
    }

    static func decodeSymlinkPolicy(_ value: Int64) throws -> SymlinkPolicy {
        switch value {
        case 0: return .doNotFollow
        default: throw SnapshotStoreError.unknownEnumValue(column: "symlink_policy", value: value)
        }
    }

    static func encode(_ value: ScanStatus) -> Int64 {
        switch value {
        case .running: return 0
        case .cancelling: return 1
        case .completed: return 2
        case .cancelled: return 3
        case .failed: return 4
        case .interrupted: return 5
        }
    }

    static func decodeScanStatus(_ value: Int64) throws -> ScanStatus {
        switch value {
        case 0: return .running
        case 1: return .cancelling
        case 2: return .completed
        case 3: return .cancelled
        case 4: return .failed
        case 5: return .interrupted
        default: throw SnapshotStoreError.unknownEnumValue(column: "status", value: value)
        }
    }

    static func encode(_ value: NodeKind) -> Int64 {
        switch value {
        case .directory: return 0
        case .regularFile: return 1
        case .symbolicLink: return 2
        case .socket: return 3
        case .fifo: return 4
        case .characterDevice: return 5
        case .blockDevice: return 6
        case .mountPoint: return 7
        case .unknown: return 8
        }
    }

    static func decodeNodeKind(_ value: Int64) throws -> NodeKind {
        switch value {
        case 0: return .directory
        case 1: return .regularFile
        case 2: return .symbolicLink
        case 3: return .socket
        case 4: return .fifo
        case 5: return .characterDevice
        case 6: return .blockDevice
        case 7: return .mountPoint
        case 8: return .unknown
        default: throw SnapshotStoreError.unknownEnumValue(column: "kind", value: value)
        }
    }

    static func encode(_ value: ScanIssueCategory) -> Int64 {
        switch value {
        case .permissionDenied: return 0
        case .notFound: return 1
        case .io: return 2
        case .nameEncoding: return 3
        case .mountBoundary: return 4
        case .changedDuringScan: return 5
        case .resourceLimit: return 6
        case .unsupported: return 7
        }
    }

    static func decodeIssueCategory(_ value: Int64) throws -> ScanIssueCategory {
        switch value {
        case 0: return .permissionDenied
        case 1: return .notFound
        case 2: return .io
        case 3: return .nameEncoding
        case 4: return .mountBoundary
        case 5: return .changedDuringScan
        case 6: return .resourceLimit
        case 7: return .unsupported
        default: throw SnapshotStoreError.unknownEnumValue(column: "category", value: value)
        }
    }

    static func encode(_ value: CapacitySource?) -> Int64? {
        switch value {
        case .importantUsage: return 0
        case .standardAvailable: return 1
        case .unavailable, .none: return 2
        }
    }

    static func decodeCapacitySource(_ value: Int64?) throws -> CapacitySource {
        switch value {
        case 0: return .importantUsage
        case 1: return .standardAvailable
        case 2, .none: return .unavailable
        default: throw SnapshotStoreError.unknownEnumValue(column: "capacity_source", value: value ?? -1)
        }
    }
}

/// Schema v1 DDL. Parents may be published after their children, so the
/// self-referential `nodes.parent_id` foreign key is intentionally absent;
/// completeness is validated by a post-scan query instead. Names are
/// scan-local (`(scan_id, id)`) and raw name bytes are unique per scan.
enum SQLiteSchema {
    static let version: Int64 = 1

    static let createStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS scans (
          id TEXT PRIMARY KEY,
          root_display_name TEXT NOT NULL,
          root_file_system_id BLOB,
          root_node_id BLOB NOT NULL,
          size_metric INTEGER NOT NULL,
          boundary_policy INTEGER NOT NULL,
          package_policy INTEGER NOT NULL,
          symlink_policy INTEGER NOT NULL,
          started_at REAL NOT NULL,
          finished_at REAL,
          status INTEGER NOT NULL,
          total_capacity BLOB,
          available_capacity BLOB,
          capacity_source INTEGER,
          last_revision BLOB NOT NULL,
          root_attributed_bytes BLOB NOT NULL,
          file_count BLOB NOT NULL,
          directory_count BLOB NOT NULL,
          inaccessible_count BLOB NOT NULL,
          issue_count BLOB NOT NULL,
          schema_version INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS names (
          scan_id TEXT NOT NULL,
          id BLOB NOT NULL,
          utf8 BLOB NOT NULL,
          PRIMARY KEY (scan_id, id),
          UNIQUE (scan_id, utf8),
          FOREIGN KEY (scan_id) REFERENCES scans(id) ON DELETE CASCADE
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS nodes (
          scan_id TEXT NOT NULL,
          id BLOB NOT NULL,
          parent_id BLOB,
          name_id BLOB NOT NULL,
          kind INTEGER NOT NULL,
          flags INTEGER NOT NULL,
          logical_bytes BLOB,
          allocated_bytes BLOB,
          attributed_bytes BLOB NOT NULL,
          modified_at REAL,
          device_id BLOB,
          file_id BLOB,
          PRIMARY KEY (scan_id, id),
          FOREIGN KEY (scan_id) REFERENCES scans(id) ON DELETE CASCADE,
          FOREIGN KEY (scan_id, name_id) REFERENCES names(scan_id, id)
        ) WITHOUT ROWID
        """,
        """
        CREATE INDEX IF NOT EXISTS nodes_by_parent
        ON nodes(scan_id, parent_id, attributed_bytes DESC, id ASC)
        """,
        """
        CREATE TABLE IF NOT EXISTS directory_aggregates (
          scan_id TEXT NOT NULL,
          node_id BLOB NOT NULL,
          logical_bytes BLOB NOT NULL,
          allocated_bytes BLOB NOT NULL,
          attributed_bytes BLOB NOT NULL,
          descendant_file_count BLOB NOT NULL,
          descendant_directory_count BLOB NOT NULL,
          inaccessible_descendant_count BLOB NOT NULL,
          is_complete INTEGER NOT NULL,
          PRIMARY KEY (scan_id, node_id),
          FOREIGN KEY (scan_id, node_id) REFERENCES nodes(scan_id, id) ON DELETE CASCADE
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS issues (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          scan_id TEXT NOT NULL,
          node_id BLOB,
          category INTEGER NOT NULL,
          errno_value INTEGER,
          sample_name_id BLOB,
          count BLOB NOT NULL,
          FOREIGN KEY (scan_id) REFERENCES scans(id) ON DELETE CASCADE
        )
        """
    ]
}
