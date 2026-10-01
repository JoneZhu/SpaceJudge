import Foundation
import SpaceJudgeDomain
import SQLite3

/// SQLite-backed `SnapshotRepository`.
///
/// One actor owns one write connection and a separate read-only connection.
/// Every statement is prepared, stepped, reset and finalized with explicit
/// error checks; nothing is interpolated into SQL as user data. `UInt64`
/// domain values are stored with `UInt64BlobCodec`.
public actor SQLiteSnapshotRepository: SnapshotRepository {
    private let writer: SQLiteDatabase
    private let reader: SQLiteDatabase
    private let readOnly: Bool
    private let now: @Sendable () -> Date
    private let capacityProvider: any StorageCapacityProviding
    private let spacePolicy: StorageSpacePolicy
    private let maximumRetainedScans: Int
    private var retainedRefreshScan: ScanID?

    /// Pages reclaimed per bounded `incremental_vacuum` call. Small enough that
    /// maintenance never blocks the UI while hundreds of MB are reclaimed.
    static let incrementalVacuumPageBudget = 256

    // MARK: Lifecycle

    public init(
        path: String,
        capacityProvider: (any StorageCapacityProviding)? = nil,
        spacePolicy: StorageSpacePolicy = .standard,
        maximumRetainedScans: Int = 1,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let writer = try SQLiteDatabase(
            path: path,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        )
        // incremental auto-vacuum must be selected before the first table is
        // created; it lets a later scan reuse the previous scan's freed pages
        // without a full-library `VACUUM`. Existing databases keep their mode.
        try writer.execute("PRAGMA auto_vacuum=INCREMENTAL")
        try writer.execute("PRAGMA journal_mode=WAL")
        try writer.execute("PRAGMA synchronous=NORMAL")
        try writer.execute("PRAGMA foreign_keys=ON")
        try writer.execute("PRAGMA busy_timeout=5000")
        try Self.migrate(writer)

        // Any scan still marked running belongs to a previous process.
        let markStatement = try writer.prepare(
            "UPDATE scans SET status = ?, finished_at = COALESCE(finished_at, ?) WHERE status = ?"
        )
        try markStatement.bindInt64(1, SchemaEncoding.encode(.interrupted))
        try markStatement.bindDouble(2, now().timeIntervalSince1970)
        try markStatement.bindInt64(3, SchemaEncoding.encode(.running))
        _ = try markStatement.step()
        markStatement.finalize()

        let reader = try SQLiteDatabase(path: path, flags: SQLITE_OPEN_READONLY)
        try reader.execute("PRAGMA foreign_keys=ON")
        try reader.execute("PRAGMA busy_timeout=5000")

        self.writer = writer
        self.reader = reader
        self.readOnly = false
        self.now = now
        self.capacityProvider = capacityProvider
            ?? VolumeStorageCapacityProvider(
                directoryPath: (path as NSString).deletingLastPathComponent
            )
        self.spacePolicy = spacePolicy
        self.maximumRetainedScans = max(1, min(2, maximumRetainedScans))
    }

    private init(readOnlyHandle: SQLiteDatabase, now: @escaping @Sendable () -> Date) {
        self.writer = readOnlyHandle
        self.reader = readOnlyHandle
        self.readOnly = true
        self.now = now
        self.capacityProvider = FixedStorageCapacityProvider(bytes: nil)
        self.spacePolicy = .standard
        self.maximumRetainedScans = 1
    }

    /// Opens a read-only view over an existing database. Used by tests and by
    /// readers that must not touch a snapshot.
    public static func openReadOnly(path: String) throws -> SQLiteSnapshotRepository {
        let handle = try SQLiteDatabase(path: path, flags: SQLITE_OPEN_READONLY)
        try handle.execute("PRAGMA foreign_keys=ON")
        try handle.execute("PRAGMA busy_timeout=5000")
        return SQLiteSnapshotRepository(readOnlyHandle: handle, now: { Date() })
    }

    /// Flushes and closes both connections. Called explicitly by tests and
    /// CLIs so file descriptors are released deterministically.
    public func close() {
        if !readOnly {
            performMaintenance()
        }
        writer.close()
        if reader !== writer {
            reader.close()
        }
    }

    /// Bounded end-of-scan/close maintenance: checkpoint the WAL, then reclaim
    /// at most a small page budget. A `TRUNCATE` checkpoint blocked by a live
    /// reader is allowed to degrade rather than fail a finished scan. A full
    /// `VACUUM` is deliberately never issued because it can need almost twice
    /// the database size.
    private func performMaintenance() {
        // Bound the blocking window: a TRUNCATE checkpoint blocked by a live
        // reader must degrade quickly to PASSIVE instead of stalling the
        // terminal update for the connection's full busy timeout.
        try? writer.execute("PRAGMA busy_timeout=250")
        try? writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try? writer.execute("PRAGMA wal_checkpoint(PASSIVE)")
        try? writer.execute("PRAGMA incremental_vacuum(\(Self.incrementalVacuumPageBudget))")
        try? writer.execute("PRAGMA busy_timeout=5000")
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        let current = try userVersion(database)
        switch current {
        case 0:
            try database.withTransaction {
                for statement in SQLiteSchema.createStatements {
                    try database.execute(statement)
                }
                try database.execute("PRAGMA user_version = \(SQLiteSchema.version)")
            }
        case SQLiteSchema.version:
            return
        default:
            throw SnapshotStoreError.unsupportedSchemaVersion(found: current)
        }
    }

    private static func userVersion(_ database: SQLiteDatabase) throws -> Int64 {
        let statement = try database.prepare("PRAGMA user_version")
        defer { statement.finalize() }
        guard try statement.step() else { return 0 }
        return statement.columnInt64(0)
    }

    /// Current `PRAGMA user_version`, for tests and diagnostics.
    public func schemaVersion() throws -> Int64 {
        try Self.userVersion(reader)
    }

    /// Whether the reader connection enforces foreign keys. Test hook.
    public func debugForeignKeysEnabled() throws -> Bool {
        let statement = try reader.prepare("PRAGMA foreign_keys")
        defer { statement.finalize() }
        guard try statement.step() else { return false }
        return statement.columnInt64(0) != 0
    }

    // MARK: Writes

    public func retainForRefresh(_ scanID: ScanID?) async {
        if !readOnly, maximumRetainedScans == 2 { retainedRefreshScan = scanID }
    }

    public func begin(_ metadata: ScanMetadata) async throws {
        try requireWritable()
        let scanText = metadata.scanID.rawValue.uuidString
        try writer.withTransaction {
            if try self.scanStatus(metadata.scanID) != nil {
                throw SnapshotStoreError.scanAlreadyExists(metadata.scanID)
            }
            // Single-scan retention: logically delete every previous scan first.
            // The deletion cascades to names/nodes/aggregates/issues and its
            // freed pages are counted as effective free space by the start
            // gate below. A gate failure rolls the whole transaction back, so a
            // refused begin keeps the previous snapshot intact and leaves no
            // fake `running` row.
            if self.maximumRetainedScans == 2, let retained = self.retainedRefreshScan {
                let delete = try self.writer.prepare("DELETE FROM scans WHERE id != ?")
                defer { delete.finalize() }
                try delete.bindText(1, retained.rawValue.uuidString)
                _ = try delete.step()
            } else {
                try self.writer.execute("DELETE FROM scans")
            }
            switch try self.spaceDecision(required: self.spacePolicy.startGateBytes) {
            case .unavailable:
                throw SnapshotStoreError.storageCapacityUnavailable
            case .insufficient(let required, let available):
                throw SnapshotStoreError.insufficientStorage(
                    requiredBytes: required,
                    availableBytes: available
                )
            case .proceed:
                break
            }
            let statement = try self.writer.prepare(
                """
                INSERT INTO scans (
                  id, root_display_name, root_file_system_id, root_node_id,
                  size_metric, boundary_policy, package_policy, symlink_policy,
                  started_at, finished_at, status, total_capacity, available_capacity,
                  capacity_source, last_revision, root_attributed_bytes, file_count,
                  directory_count, inaccessible_count, issue_count, schema_version
                ) VALUES (?,?,?,?,?,?,?,?,?,NULL,?,?,?,?,?,?,?,?,?,?,?)
                """
            )
            defer { statement.finalize() }
            try statement.bindText(1, scanText)
            try statement.bindText(2, metadata.request.root.displayName)
            if let fileSystemID = metadata.request.root.fileSystemID {
                try statement.bindBlob(3, UInt64BlobCodec.encode(fileSystemID))
            } else {
                try statement.bindNull(3)
            }
            try statement.bindBlob(4, UInt64BlobCodec.encode(metadata.rootNodeID.rawValue))
            try statement.bindInt64(5, SchemaEncoding.encode(metadata.request.sizeMetric))
            try statement.bindInt64(6, SchemaEncoding.encode(metadata.request.boundaryPolicy))
            try statement.bindInt64(7, SchemaEncoding.encode(metadata.request.packagePolicy))
            try statement.bindInt64(8, SchemaEncoding.encode(metadata.request.symlinkPolicy))
            try statement.bindDouble(9, metadata.startedAt.timeIntervalSince1970)
            try statement.bindInt64(10, SchemaEncoding.encode(.running))
            if let total = metadata.volume?.totalCapacityBytes {
                try statement.bindBlob(11, UInt64BlobCodec.encode(total))
            } else {
                try statement.bindNull(11)
            }
            if let available = metadata.volume?.availableCapacityBytes {
                try statement.bindBlob(12, UInt64BlobCodec.encode(available))
            } else {
                try statement.bindNull(12)
            }
            if let source = SchemaEncoding.encode(metadata.volume?.capacitySource) {
                try statement.bindInt64(13, source)
            } else {
                try statement.bindNull(13)
            }
            try statement.bindBlob(14, UInt64BlobCodec.encode(UInt64(0)))
            try statement.bindBlob(15, UInt64BlobCodec.encode(UInt64(0)))
            try statement.bindBlob(16, UInt64BlobCodec.encode(UInt64(0)))
            try statement.bindBlob(17, UInt64BlobCodec.encode(UInt64(0)))
            try statement.bindBlob(18, UInt64BlobCodec.encode(UInt64(0)))
            try statement.bindBlob(19, UInt64BlobCodec.encode(UInt64(0)))
            try statement.bindInt64(20, SQLiteSchema.version)
            _ = try statement.step()
        }
    }

    public func write(_ batch: NodeBatch) async throws {
        try requireWritable()
        // Runtime gate: checked before every committed batch so a low-space
        // stop reaches the runner promptly instead of relying on SQLITE_FULL.
        switch try spaceDecision(required: spacePolicy.runtimeGateBytes) {
        case .unavailable:
            throw SnapshotStoreError.storageCapacityUnavailable
        case .insufficient(let required, let available):
            throw SnapshotStoreError.insufficientStorage(
                requiredBytes: required,
                availableBytes: available
            )
        case .proceed:
            break
        }
        try writer.withTransaction {
            guard let status = try self.scanStatus(batch.scanID) else {
                throw SnapshotStoreError.scanNotFound(batch.scanID)
            }
            guard status == .running else {
                throw SnapshotStoreError.scanNotRunning(scanID: batch.scanID, status: status)
            }
            for node in batch.nodes where node.scanID != batch.scanID {
                throw SnapshotStoreError.nodeScanIDMismatch(
                    nodeID: node.id,
                    expected: batch.scanID,
                    found: node.scanID
                )
            }
            let stored = try self.lastRevision(batch.scanID) ?? 0
            guard stored < UInt64.max, batch.revision.rawValue == stored + 1 else {
                throw SnapshotStoreError.revisionNotContiguous(
                    expected: stored,
                    found: batch.revision.rawValue
                )
            }
            let scanText = batch.scanID.rawValue.uuidString
            try self.insertNames(batch.names, scanText: scanText)
            try self.insertNodes(batch.nodes, scanText: scanText)
            try self.upsertAggregates(batch.directoryAggregates, scanText: scanText)
            try self.updateLastRevision(batch.scanID, revision: batch.revision.rawValue)
        }
    }

    public func record(_ issue: ScanIssue) async throws {
        try requireWritable()
        try writer.withTransaction {
            guard let status = try self.scanStatus(issue.scanID) else {
                throw SnapshotStoreError.scanNotFound(issue.scanID)
            }
            guard status == .running else {
                throw SnapshotStoreError.scanNotRunning(scanID: issue.scanID, status: status)
            }
            let statement = try self.writer.prepare(
                "INSERT INTO issues (scan_id, node_id, category, errno_value, sample_name_id, count) VALUES (?,?,?,?,?,?)"
            )
            defer { statement.finalize() }
            try statement.bindText(1, issue.scanID.rawValue.uuidString)
            if let nodeID = issue.nodeID {
                try statement.bindBlob(2, UInt64BlobCodec.encode(nodeID.rawValue))
            } else {
                try statement.bindNull(2)
            }
            try statement.bindInt64(3, SchemaEncoding.encode(issue.category))
            if let errnoValue = issue.errnoValue {
                try statement.bindInt64(4, Int64(errnoValue))
            } else {
                try statement.bindNull(4)
            }
            if let sample = issue.sampleName {
                try statement.bindBlob(5, UInt64BlobCodec.encode(sample.rawValue))
            } else {
                try statement.bindNull(5)
            }
            try statement.bindBlob(6, UInt64BlobCodec.encode(issue.count))
            _ = try statement.step()

            let current = try self.issueCount(issue.scanID)
            let (sum, overflow) = current.addingReportingOverflow(issue.count)
            guard !overflow else {
                throw SnapshotStoreError.invalidArgument("issue count overflow")
            }
            try self.updateIssueCount(issue.scanID, count: sum)
        }
    }

    public func finish(_ summary: ScanSummary) async throws {
        try requireWritable()
        let terminal: ScanStatus
        switch summary.status {
        case .completed: terminal = .completed
        case .cancelled: terminal = .cancelled
        default: throw SnapshotStoreError.invalidTerminalStatus(summary.status)
        }
        try writer.withTransaction {
            guard let status = try self.scanStatus(summary.scanID) else {
                throw SnapshotStoreError.scanNotFound(summary.scanID)
            }
            guard status == .running else {
                throw SnapshotStoreError.scanNotRunning(scanID: summary.scanID, status: status)
            }
            let statement = try self.writer.prepare(
                """
                UPDATE scans SET
                  status = ?, finished_at = ?, root_attributed_bytes = ?,
                  file_count = ?, directory_count = ?, inaccessible_count = ?, issue_count = ?
                WHERE id = ?
                """
            )
            defer { statement.finalize() }
            try statement.bindInt64(1, SchemaEncoding.encode(terminal))
            try statement.bindDouble(
                2,
                (summary.finishedAt ?? self.now()).timeIntervalSince1970
            )
            try statement.bindBlob(3, UInt64BlobCodec.encode(summary.rootAttributedBytes))
            try statement.bindBlob(4, UInt64BlobCodec.encode(summary.fileCount))
            try statement.bindBlob(5, UInt64BlobCodec.encode(summary.directoryCount))
            try statement.bindBlob(6, UInt64BlobCodec.encode(summary.inaccessibleCount))
            try statement.bindBlob(7, UInt64BlobCodec.encode(summary.issueCount))
            try statement.bindText(8, summary.scanID.rawValue.uuidString)
            _ = try statement.step()
        }
        // Terminal maintenance runs outside the terminal transaction so a
        // blocked checkpoint can never turn a completed scan back into a
        // failure. Reclaims only a bounded page budget.
        performMaintenance()
    }

    public func fail(scanID: ScanID) async throws {
        try requireWritable()
        try writer.withTransaction {
            guard let status = try self.scanStatus(scanID) else {
                throw SnapshotStoreError.scanNotFound(scanID)
            }
            guard status == .running else {
                throw SnapshotStoreError.scanNotRunning(scanID: scanID, status: status)
            }
            let statement = try self.writer.prepare(
                "UPDATE scans SET status = ?, finished_at = ? WHERE id = ?"
            )
            defer { statement.finalize() }
            try statement.bindInt64(1, SchemaEncoding.encode(.failed))
            try statement.bindDouble(2, self.now().timeIntervalSince1970)
            try statement.bindText(3, scanID.rawValue.uuidString)
            _ = try statement.step()
        }
        performMaintenance()
    }

    private func requireWritable() throws {
        if readOnly {
            throw SnapshotStoreError.invalidArgument("repository is read-only")
        }
    }

    // MARK: Space gates

    /// Evaluates one space gate from the volume fact plus SQLite's reusable
    /// freelist pages. The volume number is read outside any transaction and
    /// the freelist count is cheap; `begin` calls this inside its transaction
    /// so freed pages from the deleted old scan are already counted.
    private func spaceDecision(required: UInt64) throws -> StorageSpaceMath.Decision {
        let reusable = try reusableBytes()
        // `URL.resourceValues` is a Foundation call that can create autoreleased
        // objects. The gate runs once per committed batch, so an explicit pool
        // keeps a long scan from accumulating temporary objects on a concurrency
        // worker thread.
        let available = autoreleasepool {
            capacityProvider.availableForImportantUsageBytes()
        }
        return StorageSpaceMath.decide(
            volumeAvailable: available,
            reusableBytes: reusable,
            requiredBytes: required
        )
    }

    private func reusableBytes() throws -> UInt64 {
        guard !readOnly else { return 0 }
        let pageSize = try pragmaUInt64("PRAGMA page_size")
        let freelist = try pragmaUInt64("PRAGMA freelist_count")
        return StorageSpaceMath.reusableBytes(pageSize: pageSize, freelistCount: freelist)
    }

    private func pragmaUInt64(_ sql: String) throws -> UInt64 {
        let statement = try writer.prepare(sql)
        defer { statement.finalize() }
        guard try statement.step() else { return 0 }
        let value = statement.columnInt64(0)
        return value >= 0 ? UInt64(value) : 0
    }

    // MARK: Write helpers

    private func insertNames(_ names: [NameRecord], scanText: String) throws {
        guard !names.isEmpty else { return }
        let byID = try writer.prepare("SELECT utf8 FROM names WHERE scan_id = ? AND id = ?")
        defer { byID.finalize() }
        let byBytes = try writer.prepare("SELECT id FROM names WHERE scan_id = ? AND utf8 = ?")
        defer { byBytes.finalize() }
        let insert = try writer.prepare("INSERT INTO names (scan_id, id, utf8) VALUES (?,?,?)")
        defer { insert.finalize() }

        for name in names {
            try byID.reset()
            try byID.bindText(1, scanText)
            try byID.bindBlob(2, UInt64BlobCodec.encode(name.id.rawValue))
            if try byID.step() {
                let existing = byID.columnBlob(0)
                if existing != name.utf8 {
                    throw SnapshotStoreError.duplicateNameID(name.id)
                }
                continue
            }

            try byBytes.reset()
            try byBytes.bindText(1, scanText)
            try byBytes.bindBlob(2, name.utf8)
            if try byBytes.step() {
                let existingID = try UInt64BlobCodec.decodeRequired(byBytes.columnBlob(0))
                throw SnapshotStoreError.nameBytesConflict(NameID(existingID))
            }

            try insert.reset()
            try insert.bindText(1, scanText)
            try insert.bindBlob(2, UInt64BlobCodec.encode(name.id.rawValue))
            try insert.bindBlob(3, name.utf8)
            _ = try insert.step()
        }
    }

    private func insertNodes(_ nodes: [NodeRecord], scanText: String) throws {
        guard !nodes.isEmpty else { return }
        let exists = try writer.prepare("SELECT 1 FROM nodes WHERE scan_id = ? AND id = ?")
        defer { exists.finalize() }
        let insert = try writer.prepare(
            """
            INSERT INTO nodes (
              scan_id, id, parent_id, name_id, kind, flags, logical_bytes,
              allocated_bytes, attributed_bytes, modified_at, device_id, file_id
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """
        )
        defer { insert.finalize() }

        for node in nodes {
            try exists.reset()
            try exists.bindText(1, scanText)
            try exists.bindBlob(2, UInt64BlobCodec.encode(node.id.rawValue))
            if try exists.step() {
                throw SnapshotStoreError.duplicateNodeID(node.id)
            }

            try insert.reset()
            try insert.bindText(1, scanText)
            try insert.bindBlob(2, UInt64BlobCodec.encode(node.id.rawValue))
            if let parentID = node.parentID {
                try insert.bindBlob(3, UInt64BlobCodec.encode(parentID.rawValue))
            } else {
                try insert.bindNull(3)
            }
            try insert.bindBlob(4, UInt64BlobCodec.encode(node.name.rawValue))
            try insert.bindInt64(5, SchemaEncoding.encode(node.kind))
            try insert.bindInt64(6, Int64(node.flags.rawValue))
            if let logical = node.logicalBytes {
                try insert.bindBlob(7, UInt64BlobCodec.encode(logical))
            } else {
                try insert.bindNull(7)
            }
            if let allocated = node.allocatedBytes {
                try insert.bindBlob(8, UInt64BlobCodec.encode(allocated))
            } else {
                try insert.bindNull(8)
            }
            try insert.bindBlob(9, UInt64BlobCodec.encode(node.attributedBytes))
            if let modifiedAt = node.modifiedAt {
                try insert.bindDouble(10, modifiedAt.timeIntervalSince1970)
            } else {
                try insert.bindNull(10)
            }
            if let deviceID = node.deviceID {
                try insert.bindBlob(11, UInt64BlobCodec.encode(deviceID))
            } else {
                try insert.bindNull(11)
            }
            if let fileID = node.fileID {
                try insert.bindBlob(12, UInt64BlobCodec.encode(fileID))
            } else {
                try insert.bindNull(12)
            }
            _ = try insert.step()
        }
    }

    private func upsertAggregates(
        _ aggregates: [DirectoryAggregateRecord],
        scanText: String
    ) throws {
        guard !aggregates.isEmpty else { return }
        let select = try writer.prepare(
            """
            SELECT is_complete, logical_bytes, allocated_bytes, attributed_bytes,
                   descendant_file_count, descendant_directory_count,
                   inaccessible_descendant_count
            FROM directory_aggregates WHERE scan_id = ? AND node_id = ?
            """
        )
        defer { select.finalize() }
        let insert = try writer.prepare(
            """
            INSERT INTO directory_aggregates (
              scan_id, node_id, logical_bytes, allocated_bytes, attributed_bytes,
              descendant_file_count, descendant_directory_count,
              inaccessible_descendant_count, is_complete
            ) VALUES (?,?,?,?,?,?,?,?,?)
            """
        )
        defer { insert.finalize() }
        let update = try writer.prepare(
            """
            UPDATE directory_aggregates SET
              logical_bytes = ?, allocated_bytes = ?, attributed_bytes = ?,
              descendant_file_count = ?, descendant_directory_count = ?,
              inaccessible_descendant_count = ?, is_complete = ?
            WHERE scan_id = ? AND node_id = ?
            """
        )
        defer { update.finalize() }

        for aggregate in aggregates {
            let nodeBlob = UInt64BlobCodec.encode(aggregate.nodeID.rawValue)
            try select.reset()
            try select.bindText(1, scanText)
            try select.bindBlob(2, nodeBlob)
            if try select.step() {
                let existingComplete = select.columnInt64(0) != 0
                if existingComplete {
                    let existing = ExistingAggregate(
                        logical: try UInt64BlobCodec.decodeRequired(select.columnBlob(1)),
                        allocated: try UInt64BlobCodec.decodeRequired(select.columnBlob(2)),
                        attributed: try UInt64BlobCodec.decodeRequired(select.columnBlob(3)),
                        files: try UInt64BlobCodec.decodeRequired(select.columnBlob(4)),
                        directories: try UInt64BlobCodec.decodeRequired(select.columnBlob(5)),
                        inaccessible: try UInt64BlobCodec.decodeRequired(select.columnBlob(6))
                    )
                    if !aggregate.isComplete || existing != ExistingAggregate(aggregate) {
                        throw SnapshotStoreError.completeAggregateChanged(aggregate.nodeID)
                    }
                    continue
                }
                try update.reset()
                try update.bindBlob(1, UInt64BlobCodec.encode(aggregate.logicalBytes))
                try update.bindBlob(2, UInt64BlobCodec.encode(aggregate.allocatedBytes))
                try update.bindBlob(3, UInt64BlobCodec.encode(aggregate.attributedBytes))
                try update.bindBlob(4, UInt64BlobCodec.encode(aggregate.descendantFileCount))
                try update.bindBlob(5, UInt64BlobCodec.encode(aggregate.descendantDirectoryCount))
                try update.bindBlob(6, UInt64BlobCodec.encode(aggregate.inaccessibleDescendantCount))
                try update.bindInt64(7, aggregate.isComplete ? 1 : 0)
                try update.bindText(8, scanText)
                try update.bindBlob(9, nodeBlob)
                _ = try update.step()
            } else {
                try insert.reset()
                try insert.bindText(1, scanText)
                try insert.bindBlob(2, nodeBlob)
                try insert.bindBlob(3, UInt64BlobCodec.encode(aggregate.logicalBytes))
                try insert.bindBlob(4, UInt64BlobCodec.encode(aggregate.allocatedBytes))
                try insert.bindBlob(5, UInt64BlobCodec.encode(aggregate.attributedBytes))
                try insert.bindBlob(6, UInt64BlobCodec.encode(aggregate.descendantFileCount))
                try insert.bindBlob(7, UInt64BlobCodec.encode(aggregate.descendantDirectoryCount))
                try insert.bindBlob(8, UInt64BlobCodec.encode(aggregate.inaccessibleDescendantCount))
                try insert.bindInt64(9, aggregate.isComplete ? 1 : 0)
                _ = try insert.step()
            }
        }
    }

    private struct ExistingAggregate: Equatable {
        let logical: UInt64
        let allocated: UInt64
        let attributed: UInt64
        let files: UInt64
        let directories: UInt64
        let inaccessible: UInt64

        init(
            logical: UInt64,
            allocated: UInt64,
            attributed: UInt64,
            files: UInt64,
            directories: UInt64,
            inaccessible: UInt64
        ) {
            self.logical = logical
            self.allocated = allocated
            self.attributed = attributed
            self.files = files
            self.directories = directories
            self.inaccessible = inaccessible
        }

        init(_ record: DirectoryAggregateRecord) {
            self.init(
                logical: record.logicalBytes,
                allocated: record.allocatedBytes,
                attributed: record.attributedBytes,
                files: record.descendantFileCount,
                directories: record.descendantDirectoryCount,
                inaccessible: record.inaccessibleDescendantCount
            )
        }
    }

    private func updateLastRevision(_ scanID: ScanID, revision: UInt64) throws {
        let statement = try writer.prepare("UPDATE scans SET last_revision = ? WHERE id = ?")
        defer { statement.finalize() }
        try statement.bindBlob(1, UInt64BlobCodec.encode(revision))
        try statement.bindText(2, scanID.rawValue.uuidString)
        _ = try statement.step()
    }

    private func updateIssueCount(_ scanID: ScanID, count: UInt64) throws {
        let statement = try writer.prepare("UPDATE scans SET issue_count = ? WHERE id = ?")
        defer { statement.finalize() }
        try statement.bindBlob(1, UInt64BlobCodec.encode(count))
        try statement.bindText(2, scanID.rawValue.uuidString)
        _ = try statement.step()
    }

    private func scanStatus(_ scanID: ScanID) throws -> ScanStatus? {
        let statement = try writer.prepare("SELECT status FROM scans WHERE id = ?")
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)
        guard try statement.step() else { return nil }
        return try SchemaEncoding.decodeScanStatus(statement.columnInt64(0))
    }

    private func lastRevision(_ scanID: ScanID) throws -> UInt64? {
        let statement = try writer.prepare("SELECT last_revision FROM scans WHERE id = ?")
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)
        guard try statement.step() else { return nil }
        return try UInt64BlobCodec.decodeRequired(statement.columnBlob(0))
    }

    private func issueCount(_ scanID: ScanID) throws -> UInt64 {
        let statement = try writer.prepare("SELECT issue_count FROM scans WHERE id = ?")
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)
        guard try statement.step() else {
            throw SnapshotStoreError.scanNotFound(scanID)
        }
        return try UInt64BlobCodec.decodeRequired(statement.columnBlob(0))
    }

    // MARK: Reads

    public func child(named bytes: Data, of parent: NodeID, in scanID: ScanID) async throws -> NodeRecord? {
        let statement = try reader.prepare("""
            SELECT n.id, n.parent_id, n.name_id, n.kind, n.flags, n.logical_bytes,
                   n.allocated_bytes, n.attributed_bytes, n.modified_at, n.device_id, n.file_id
            FROM nodes n JOIN names m ON m.scan_id = n.scan_id AND m.id = n.name_id
            WHERE n.scan_id = ? AND n.parent_id = ? AND m.utf8 = ? LIMIT 1
            """)
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)
        try statement.bindBlob(2, UInt64BlobCodec.encode(parent.rawValue))
        try statement.bindBlob(3, bytes)
        guard try statement.step() else { return nil }
        return try Self.nodeRecord(from: statement, scanID: scanID)
    }

    public func children(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] {
        let statement = try reader.prepare(
            """
            SELECT id, parent_id, name_id, kind, flags, logical_bytes, allocated_bytes,
                   attributed_bytes, modified_at, device_id, file_id
            FROM nodes
            WHERE scan_id = ? AND parent_id = ?
            ORDER BY attributed_bytes DESC, id ASC
            """
        )
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)
        try statement.bindBlob(2, UInt64BlobCodec.encode(nodeID.rawValue))
        var result: [NodeRecord] = []
        while try statement.step() {
            result.append(try Self.nodeRecord(from: statement, scanID: scanID))
        }
        return result
    }

    public func childPage(
        of nodeID: NodeID,
        in scanID: ScanID,
        limit: Int
    ) async throws -> SnapshotChildPage {
        guard limit >= SnapshotQueryLimits.minimumChildPageLimit,
              limit <= SnapshotQueryLimits.maximumChildPageLimit else {
            throw SnapshotQueryError.invalidChildPageLimit(limit)
        }

        // Revision, parent aggregate, count and page are read inside one
        // deferred read transaction on the read-only connection, so a caller
        // can trust that the four facts describe one snapshot. The transaction
        // is closed on every path, including prepare/step/decode failures.
        return try reader.withReadTransaction {
            let revision = try self.readerRevision(scanID) ?? Revision(0)
            let aggregate = try self.readerAggregate(nodeID, scanID: scanID)

            let countStatement = try self.reader.prepare(
                "SELECT COUNT(*) FROM nodes WHERE scan_id = ? AND parent_id = ?"
            )
            defer { countStatement.finalize() }
            try countStatement.bindText(1, scanID.rawValue.uuidString)
            try countStatement.bindBlob(2, UInt64BlobCodec.encode(nodeID.rawValue))
            let totalCount: UInt64
            if try countStatement.step() {
                let raw = countStatement.columnInt64(0)
                totalCount = raw >= 0 ? UInt64(raw) : 0
            } else {
                totalCount = 0
            }

            let statement = try self.reader.prepare(
                """
                SELECT n.id, n.parent_id, n.name_id, n.kind, n.flags, n.logical_bytes,
                       n.allocated_bytes, n.attributed_bytes, n.modified_at, n.device_id,
                       n.file_id, m.utf8,
                       COALESCE(a.attributed_bytes, n.attributed_bytes) AS effective
                FROM nodes AS n INDEXED BY nodes_by_parent
                JOIN names AS m ON m.scan_id = n.scan_id AND m.id = n.name_id
                LEFT JOIN directory_aggregates AS a
                       ON a.scan_id = n.scan_id AND a.node_id = n.id
                WHERE n.scan_id = ? AND n.parent_id = ?
                ORDER BY effective DESC, n.id ASC
                LIMIT ?
                """
            )
            defer { statement.finalize() }
            try statement.bindText(1, scanID.rawValue.uuidString)
            try statement.bindBlob(2, UInt64BlobCodec.encode(nodeID.rawValue))
            try statement.bindInt64(3, Int64(limit))

            var items: [SnapshotChildItem] = []
            while try statement.step() {
                let node = try Self.nodeRecord(from: statement, scanID: scanID)
                guard let utf8 = statement.columnBlob(11) else {
                    throw SnapshotStoreError.invalidArgument("child node is missing its name row")
                }
                // Directories carry their subtree weight in directory_aggregates;
                // the immutable node row keeps attributed_bytes == 0. Files have no
                // aggregate and fall back to the node value via COALESCE.
                let effective = try UInt64BlobCodec.decodeRequired(statement.columnBlob(12))
                items.append(
                    SnapshotChildItem(
                        node: node,
                        name: NameRecord(id: node.name, utf8: utf8),
                        effectiveAttributedBytes: effective
                    )
                )
            }

            return SnapshotChildPage(
                items: items,
                totalCount: totalCount,
                snapshotRevision: revision,
                parentAggregate: aggregate
            )
        }
    }

    /// Same-snapshot scan revision read from the read-only connection.
    private func readerRevision(_ scanID: ScanID) throws -> Revision? {
        let statement = try reader.prepare("SELECT last_revision FROM scans WHERE id = ?")
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)
        guard try statement.step() else { return nil }
        return Revision(try UInt64BlobCodec.decodeRequired(statement.columnBlob(0)))
    }

    /// Same-snapshot parent aggregate read from the read-only connection.
    private func readerAggregate(
        _ nodeID: NodeID,
        scanID: ScanID
    ) throws -> DirectoryAggregateRecord? {
        let statement = try reader.prepare(
            """
            SELECT logical_bytes, allocated_bytes, attributed_bytes,
                   descendant_file_count, descendant_directory_count,
                   inaccessible_descendant_count, is_complete
            FROM directory_aggregates WHERE scan_id = ? AND node_id = ?
            """
        )
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)
        try statement.bindBlob(2, UInt64BlobCodec.encode(nodeID.rawValue))
        guard try statement.step() else { return nil }
        return DirectoryAggregateRecord(
            nodeID: nodeID,
            logicalBytes: try UInt64BlobCodec.decodeRequired(statement.columnBlob(0)),
            allocatedBytes: try UInt64BlobCodec.decodeRequired(statement.columnBlob(1)),
            attributedBytes: try UInt64BlobCodec.decodeRequired(statement.columnBlob(2)),
            descendantFileCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(3)),
            descendantDirectoryCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(4)),
            inaccessibleDescendantCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(5)),
            isComplete: statement.columnInt64(6) != 0
        )
    }

    public func name(id: NameID, in scanID: ScanID) async throws -> NameRecord? {
        let statement = try reader.prepare("SELECT utf8 FROM names WHERE scan_id = ? AND id = ?")
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)
        try statement.bindBlob(2, UInt64BlobCodec.encode(id.rawValue))
        guard try statement.step() else { return nil }
        guard let utf8 = statement.columnBlob(0) else { return nil }
        return NameRecord(id: id, utf8: utf8)
    }

    public func aggregate(
        of nodeID: NodeID,
        in scanID: ScanID
    ) async throws -> DirectoryAggregateRecord? {
        let statement = try reader.prepare(
            """
            SELECT logical_bytes, allocated_bytes, attributed_bytes,
                   descendant_file_count, descendant_directory_count,
                   inaccessible_descendant_count, is_complete
            FROM directory_aggregates WHERE scan_id = ? AND node_id = ?
            """
        )
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)
        try statement.bindBlob(2, UInt64BlobCodec.encode(nodeID.rawValue))
        guard try statement.step() else { return nil }
        return DirectoryAggregateRecord(
            nodeID: nodeID,
            logicalBytes: try UInt64BlobCodec.decodeRequired(statement.columnBlob(0)),
            allocatedBytes: try UInt64BlobCodec.decodeRequired(statement.columnBlob(1)),
            attributedBytes: try UInt64BlobCodec.decodeRequired(statement.columnBlob(2)),
            descendantFileCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(3)),
            descendantDirectoryCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(4)),
            inaccessibleDescendantCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(5)),
            isComplete: statement.columnInt64(6) != 0
        )
    }

    public func ancestors(of nodeID: NodeID, in scanID: ScanID) async throws -> [NodeRecord] {
        let statement = try reader.prepare(
            """
            SELECT id, parent_id, name_id, kind, flags, logical_bytes, allocated_bytes,
                   attributed_bytes, modified_at, device_id, file_id
            FROM nodes WHERE scan_id = ? AND id = ?
            """
        )
        defer { statement.finalize() }

        var chain: [NodeRecord] = []
        var visited: Set<UInt64> = []
        var current: NodeID? = nodeID
        while let identifier = current {
            if !visited.insert(identifier.rawValue).inserted {
                throw SnapshotStoreError.ancestorCycle(identifier)
            }
            try statement.reset()
            try statement.bindText(1, scanID.rawValue.uuidString)
            try statement.bindBlob(2, UInt64BlobCodec.encode(identifier.rawValue))
            guard try statement.step() else {
                throw SnapshotStoreError.missingParent(identifier)
            }
            let record = try Self.nodeRecord(from: statement, scanID: scanID)
            chain.append(record)
            current = record.parentID
        }
        return chain.reversed()
    }

    public func scanState(_ scanID: ScanID) async throws -> ScanSnapshotState? {
        let statement = try reader.prepare(
            """
            SELECT status, root_node_id, root_display_name, last_revision, started_at,
                   finished_at, file_count, directory_count, inaccessible_count,
                   issue_count, root_attributed_bytes
            FROM scans WHERE id = ?
            """
        )
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)
        guard try statement.step() else { return nil }
        return ScanSnapshotState(
            scanID: scanID,
            status: try SchemaEncoding.decodeScanStatus(statement.columnInt64(0)),
            rootNodeID: NodeID(try UInt64BlobCodec.decodeRequired(statement.columnBlob(1))),
            rootDisplayName: statement.columnText(2) ?? "",
            lastRevision: Revision(try UInt64BlobCodec.decodeRequired(statement.columnBlob(3))),
            startedAt: Date(timeIntervalSince1970: statement.columnDouble(4)),
            finishedAt: statement.columnIsNull(5)
                ? nil
                : Date(timeIntervalSince1970: statement.columnDouble(5)),
            fileCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(6)),
            directoryCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(7)),
            inaccessibleCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(8)),
            issueCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(9)),
            rootAttributedBytes: try UInt64BlobCodec.decodeRequired(statement.columnBlob(10))
        )
    }

    public func scanSummary(_ scanID: ScanID) async throws -> ScanSnapshotSummary? {
        let statement = try reader.prepare(
            """
            SELECT status, root_display_name, root_node_id, size_metric, boundary_policy,
                   package_policy, symlink_policy, started_at, finished_at, last_revision,
                   root_attributed_bytes, file_count, directory_count, inaccessible_count,
                   issue_count, total_capacity, available_capacity, capacity_source
            FROM scans WHERE id = ?
            """
        )
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)
        guard try statement.step() else { return nil }
        let total = try UInt64BlobCodec.decodeOptional(statement.columnBlob(15))
        let available = try UInt64BlobCodec.decodeOptional(statement.columnBlob(16))
        let sourceValue = statement.columnIsNull(17) ? nil : statement.columnInt64(17)
        let volume: VolumeFacts?
        if total == nil, available == nil, sourceValue == nil {
            volume = nil
        } else {
            volume = VolumeFacts(
                totalCapacityBytes: total,
                availableCapacityBytes: available,
                capacitySource: try SchemaEncoding.decodeCapacitySource(sourceValue)
            )
        }
        return ScanSnapshotSummary(
            scanID: scanID,
            status: try SchemaEncoding.decodeScanStatus(statement.columnInt64(0)),
            rootDisplayName: statement.columnText(1) ?? "",
            rootNodeID: NodeID(try UInt64BlobCodec.decodeRequired(statement.columnBlob(2))),
            sizeMetric: try SchemaEncoding.decodeSizeMetric(statement.columnInt64(3)),
            boundaryPolicy: try SchemaEncoding.decodeBoundaryPolicy(statement.columnInt64(4)),
            packagePolicy: try SchemaEncoding.decodePackagePolicy(statement.columnInt64(5)),
            symlinkPolicy: try SchemaEncoding.decodeSymlinkPolicy(statement.columnInt64(6)),
            startedAt: Date(timeIntervalSince1970: statement.columnDouble(7)),
            finishedAt: statement.columnIsNull(8)
                ? nil
                : Date(timeIntervalSince1970: statement.columnDouble(8)),
            lastRevision: Revision(try UInt64BlobCodec.decodeRequired(statement.columnBlob(9))),
            rootAttributedBytes: try UInt64BlobCodec.decodeRequired(statement.columnBlob(10)),
            fileCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(11)),
            directoryCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(12)),
            inaccessibleCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(13)),
            issueCount: try UInt64BlobCodec.decodeRequired(statement.columnBlob(14)),
            volume: volume
        )
    }

    public func issueSummary(_ scanID: ScanID) async throws -> [IssueAggregateSummary] {
        let statement = try reader.prepare(
            "SELECT category, errno_value, sample_name_id, count FROM issues WHERE scan_id = ?"
        )
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)

        struct Key: Hashable {
            let category: Int64
            let errno: Int32?
            let sample: UInt64?
        }
        var buckets: [Key: UInt64] = [:]
        while try statement.step() {
            let categoryValue = statement.columnInt64(0)
            let errnoValue = statement.columnIsNull(1) ? nil : Int32(truncatingIfNeeded: statement.columnInt64(1))
            let sampleValue = try UInt64BlobCodec.decodeOptional(statement.columnBlob(2))
            let count = try UInt64BlobCodec.decodeRequired(statement.columnBlob(3))
            let key = Key(category: categoryValue, errno: errnoValue, sample: sampleValue)
            let (sum, overflow) = (buckets[key] ?? 0).addingReportingOverflow(count)
            guard !overflow else {
                throw SnapshotStoreError.invalidArgument("issue aggregate overflow")
            }
            buckets[key] = sum
        }

        var result: [IssueAggregateSummary] = []
        for (key, count) in buckets {
            result.append(
                IssueAggregateSummary(
                    category: try SchemaEncoding.decodeIssueCategory(key.category),
                    errnoValue: key.errno,
                    sampleNameID: key.sample.map(NameID.init),
                    count: count
                )
            )
        }
        result.sort {
            if $0.category != $1.category {
                return SchemaEncoding.encode($0.category) < SchemaEncoding.encode($1.category)
            }
            if $0.errnoValue != $1.errnoValue {
                return ($0.errnoValue ?? -1) < ($1.errnoValue ?? -1)
            }
            return ($0.sampleNameID?.rawValue ?? 0) < ($1.sampleNameID?.rawValue ?? 0)
        }
        return result
    }

    public func statistics(_ scanID: ScanID) async throws -> SnapshotStatistics {
        return SnapshotStatistics(
            nodeCount: try count("nodes", scanID: scanID),
            nameCount: try count("names", scanID: scanID),
            aggregateCount: try count("directory_aggregates", scanID: scanID),
            issueCount: try count("issues", scanID: scanID)
        )
    }

    private func count(_ table: String, scanID: ScanID) throws -> UInt64 {
        // Table names are fixed literals, never user input.
        let statement = try reader.prepare("SELECT COUNT(*) FROM \(table) WHERE scan_id = ?")
        defer { statement.finalize() }
        try statement.bindText(1, scanID.rawValue.uuidString)
        guard try statement.step() else { return 0 }
        return UInt64(statement.columnInt64(0))
    }

    private static func nodeRecord(
        from statement: SQLiteStatement,
        scanID: ScanID
    ) throws -> NodeRecord {
        NodeRecord(
            id: NodeID(try UInt64BlobCodec.decodeRequired(statement.columnBlob(0))),
            scanID: scanID,
            parentID: try UInt64BlobCodec.decodeOptional(statement.columnBlob(1)).map(NodeID.init),
            name: NameID(try UInt64BlobCodec.decodeRequired(statement.columnBlob(2))),
            kind: try SchemaEncoding.decodeNodeKind(statement.columnInt64(3)),
            flags: NodeFlags(rawValue: UInt32(truncatingIfNeeded: statement.columnInt64(4))),
            logicalBytes: try UInt64BlobCodec.decodeOptional(statement.columnBlob(5)),
            allocatedBytes: try UInt64BlobCodec.decodeOptional(statement.columnBlob(6)),
            attributedBytes: try UInt64BlobCodec.decodeRequired(statement.columnBlob(7)),
            modifiedAt: statement.columnIsNull(8)
                ? nil
                : Date(timeIntervalSince1970: statement.columnDouble(8)),
            deviceID: try UInt64BlobCodec.decodeOptional(statement.columnBlob(9)),
            fileID: try UInt64BlobCodec.decodeOptional(statement.columnBlob(10))
        )
    }
}
