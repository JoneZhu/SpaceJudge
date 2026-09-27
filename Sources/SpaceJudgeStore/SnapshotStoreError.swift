import Foundation
import SQLite3
import SpaceJudgeDomain

/// Errors surfaced by `SpaceJudgeStore`. Every case is explicit so callers can
/// distinguish a constraint violation from an I/O failure.
public enum SnapshotStoreError: Error, Equatable, Sendable {
    /// A SQLite call returned a non-OK code.
    case sqlite(code: Int32, message: String)
    /// The on-disk `PRAGMA user_version` is not one this build understands.
    case unsupportedSchemaVersion(found: Int64)
    /// `begin` was called for an `ScanID` that already exists.
    case scanAlreadyExists(ScanID)
    /// The scan header does not exist.
    case scanNotFound(ScanID)
    /// A write/issue/finish was attempted on a scan that is not `running`.
    case scanNotRunning(scanID: ScanID, status: ScanStatus)
    /// A batch revision was not exactly one greater than the stored revision.
    case revisionNotContiguous(expected: UInt64, found: UInt64)
    /// The same `(scanID, NameID)` was used with different bytes.
    case duplicateNameID(NameID)
    /// The same raw name bytes were used with a different `NameID`.
    case nameBytesConflict(NameID)
    /// The same `(scanID, NodeID)` was inserted twice.
    case duplicateNodeID(NodeID)
    /// A `NodeRecord` carried a `ScanID` different from its batch.
    case nodeScanIDMismatch(nodeID: NodeID, expected: ScanID, found: ScanID)
    /// A complete directory aggregate was changed or rolled back.
    case completeAggregateChanged(NodeID)
    /// A `UInt64` column BLOB was not exactly eight bytes.
    case invalidUInt64BlobLength(Int)
    /// `ancestors` found a parent-pointer cycle.
    case ancestorCycle(NodeID)
    /// `ancestors` reached a node whose parent is missing.
    case missingParent(NodeID)
    /// An argument did not satisfy the store contract.
    case invalidArgument(String)
    /// A `finish` summary carried a status that cannot terminate a scan.
    case invalidTerminalStatus(ScanStatus)
    /// An enum column held an unknown raw value.
    case unknownEnumValue(column: String, value: Int64)
    /// The cache volume's usable capacity could not be established. Production
    /// refuses to start rather than treating unknown as zero.
    case storageCapacityUnavailable
    /// The effective usable space is below the required product gate.
    case insufficientStorage(requiredBytes: UInt64, availableBytes: UInt64)

    /// Whether this failure is SQLite reporting exhausted or failing storage.
    /// `SQLITE_FULL` and `SQLITE_IOERR` cannot be replaced by a pre-check, so
    /// they must still terminate the scan as a storage failure.
    public var isStorageExhaustion: Bool {
        guard case .sqlite(let code, _) = self else { return false }
        return (code & 0xFF) == Int32(SQLITE_FULL) || (code & 0xFF) == Int32(SQLITE_IOERR)
    }
}

/// Fixed 8-byte big-endian representation for all domain `UInt64` values.
///
/// SQLite `INTEGER` is signed 64-bit and cannot represent the full `UInt64`
/// range without truncation. Big-endian BLOBs round-trip every value and sort
/// lexicographically in unsigned numeric order. `nil` is stored as SQL `NULL`;
/// a real zero is eight zero bytes.
public enum UInt64BlobCodec {
    public static let byteCount = 8

    public static func encode(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    public static func decode(_ data: Data) throws -> UInt64 {
        guard data.count == byteCount else {
            throw SnapshotStoreError.invalidUInt64BlobLength(data.count)
        }
        var value: UInt64 = 0
        for byte in data {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    /// Decodes a nullable column: SQL `NULL` maps to `nil`.
    public static func decodeOptional(_ data: Data?) throws -> UInt64? {
        guard let data else { return nil }
        return try decode(data)
    }

    /// Decodes a `NOT NULL` column, failing explicitly if the value is missing.
    public static func decodeRequired(_ data: Data?) throws -> UInt64 {
        guard let data else {
            throw SnapshotStoreError.invalidArgument("expected a non-null UInt64 column")
        }
        return try decode(data)
    }

    public static func encode(_ value: UInt64?) -> Data? {
        value.map(encode)
    }
}
