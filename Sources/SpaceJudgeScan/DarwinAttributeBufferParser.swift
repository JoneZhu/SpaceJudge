import Darwin
import Foundation
import SpaceJudgeDomain

/// Errors produced while parsing a `getattrlistbulk` attribute buffer.
///
/// The parser treats the buffer as untrusted binary input: every read is
/// bounds-checked and no raw pointer is ever rebound to a Swift `struct`.
public enum DarwinAttributeParseError: Error, Equatable, Sendable {
    case negativeEntryCount
    case truncatedRecord
    case invalidRecordLength
    case recordOverrun
    case missingReturnedAttributes
    case missingNameAttribute
    case invalidNameReference
    case nameOutOfRecord
    case nameOverlapsFixedFields
    case missingNameTerminator
    case emptyName
}

/// Raw `ATTR_*` bits used by the parser, converted to a single unsigned type.
public enum DarwinAttributeBits {
    static func bit(_ value: some BinaryInteger) -> UInt32 {
        UInt32(truncatingIfNeeded: value)
    }

    // Common attributes.
    public static let commonReturnedAttrs = bit(ATTR_CMN_RETURNED_ATTRS)
    public static let commonName = bit(ATTR_CMN_NAME)
    public static let commonDevID = bit(ATTR_CMN_DEVID)
    public static let commonObjType = bit(ATTR_CMN_OBJTYPE)
    public static let commonModTime = bit(ATTR_CMN_MODTIME)
    public static let commonFlags = bit(ATTR_CMN_FLAGS)
    public static let commonFileID = bit(ATTR_CMN_FILEID)
    public static let commonParentID = bit(ATTR_CMN_PARENTID)
    public static let commonError = bit(ATTR_CMN_ERROR)

    // Directory attributes.
    public static let dirMountStatus = bit(ATTR_DIR_MOUNTSTATUS)

    // File attributes.
    public static let fileLinkCount = bit(ATTR_FILE_LINKCOUNT)
    public static let fileTotalSize = bit(ATTR_FILE_TOTALSIZE)
    public static let fileAllocSize = bit(ATTR_FILE_ALLOCSIZE)

    /// `DIR_MNTSTATUS_MNTPOINT`.
    public static let mountStatusMountPoint = bit(DIR_MNTSTATUS_MNTPOINT)

    /// `SF_FIRMLINK` from `ATTR_CMN_FLAGS`.
    public static let fileFlagFirmlink = bit(SF_FIRMLINK)
}

/// Pure parser for the `getattrlistbulk` buffer layout used by this project.
///
/// The parser is deterministic and side-effect free so it can be unit- and
/// fuzz-tested with arbitrary byte inputs. It never loads a struct from a
/// potentially unaligned address; all multi-byte fields are assembled from
/// individual bytes.
public struct DarwinAttributeBufferParser: Sendable {
    /// The attribute groups requested from the kernel.
    public struct Request: Sendable, Equatable, Hashable {
        public let commonattr: UInt32
        public let dirattr: UInt32
        public let fileattr: UInt32

        public init(commonattr: UInt32, dirattr: UInt32, fileattr: UInt32) {
            self.commonattr = commonattr
            self.dirattr = dirattr
            self.fileattr = fileattr
        }

        /// The Phase 1 request described in `docs/08-phase-1-design.md`.
        public static let phase1 = Request(
            commonattr: DarwinAttributeBits.commonReturnedAttrs
                | DarwinAttributeBits.commonName
                | DarwinAttributeBits.commonError
                | DarwinAttributeBits.commonObjType
                | DarwinAttributeBits.commonDevID
                | DarwinAttributeBits.commonFileID
                | DarwinAttributeBits.commonParentID
                | DarwinAttributeBits.commonModTime
                | DarwinAttributeBits.commonFlags,
            dirattr: DarwinAttributeBits.dirMountStatus,
            fileattr: DarwinAttributeBits.fileLinkCount
                | DarwinAttributeBits.fileTotalSize
                | DarwinAttributeBits.fileAllocSize
        )
    }

    public init() {}

    public func parse(
        bytes: [UInt8],
        entryCount: Int,
        request: Request = .phase1
    ) throws -> [RawDirectoryEntry] {
        try bytes.withUnsafeBytes { raw in
            try parse(rawBuffer: raw, entryCount: entryCount, request: request)
        }
    }

    public func parse(
        data: Data,
        entryCount: Int,
        request: Request = .phase1
    ) throws -> [RawDirectoryEntry] {
        try parse(bytes: [UInt8](data), entryCount: entryCount, request: request)
    }

    public func parse(
        rawBuffer: UnsafeRawBufferPointer,
        entryCount: Int,
        request: Request = .phase1
    ) throws -> [RawDirectoryEntry] {
        guard entryCount >= 0 else {
            throw DarwinAttributeParseError.negativeEntryCount
        }
        var entries: [RawDirectoryEntry] = []
        entries.reserveCapacity(min(entryCount, 4096))
        var cursor = 0
        for _ in 0..<entryCount {
            let entry = try parseRecord(rawBuffer, recordStart: cursor, request: request)
            entries.append(entry.entry)
            cursor = entry.nextOffset
        }
        return entries
    }

    // MARK: - Record parsing

    private struct RecordResult {
        let entry: RawDirectoryEntry
        let nextOffset: Int
    }

    private func parseRecord(
        _ buffer: UnsafeRawBufferPointer,
        recordStart: Int,
        request: Request
    ) throws -> RecordResult {
        guard let length = readUInt32(buffer, at: recordStart) else {
            throw DarwinAttributeParseError.truncatedRecord
        }
        guard length >= 24 else {
            throw DarwinAttributeParseError.invalidRecordLength
        }
        let recordEnd = recordStart + Int(length)
        guard recordEnd <= buffer.count, recordEnd > recordStart else {
            throw DarwinAttributeParseError.recordOverrun
        }

        guard let returnedCommon = readUInt32(buffer, at: recordStart + 4),
              let returnedVolume = readUInt32(buffer, at: recordStart + 8),
              let returnedDirectory = readUInt32(buffer, at: recordStart + 12),
              let returnedFile = readUInt32(buffer, at: recordStart + 16),
              let returnedFork = readUInt32(buffer, at: recordStart + 20) else {
            throw DarwinAttributeParseError.truncatedRecord
        }
        _ = returnedVolume
        _ = returnedFork

        guard (returnedCommon & DarwinAttributeBits.commonReturnedAttrs) != 0 else {
            throw DarwinAttributeParseError.missingReturnedAttributes
        }
        guard (returnedCommon & DarwinAttributeBits.commonName) != 0 else {
            throw DarwinAttributeParseError.missingNameAttribute
        }

        var cursor = recordStart + 24
        let opened = request.commonattr & returnedCommon

        // ATTR_CMN_ERROR is packed immediately after ATTR_CMN_RETURNED_ATTRS.
        var entryError: Int32?
        if (opened & DarwinAttributeBits.commonError) != 0 {
            guard let value = readUInt32(buffer, at: cursor) else {
                throw DarwinAttributeParseError.truncatedRecord
            }
            cursor += 4
            if value != 0 {
                entryError = Int32(bitPattern: value)
            }
        }

        var nameReferencePosition = -1
        var nameReferenceOffset: Int32 = 0
        var nameReferenceLength: UInt32 = 0

        var kind: NodeKind = .unknown
        var deviceID: UInt64?
        var fileID: UInt64?
        var parentFileID: UInt64?
        var modifiedAt: Date?
        var isFirmlink = false

        // Common attributes, in ascending bit order (NAME, DEVID, OBJTYPE,
        // MODTIME, FLAGS, FILEID, PARENTID). The FLAGS slot is consumed whether
        // or not it is a firmlink, so the FILEID/PARENTID offsets are unchanged
        // from Phase 5A.
        for (bit, size) in Self.commonOrder {
            guard (opened & bit) != 0 else { continue }
            guard cursor + size <= recordEnd else {
                throw DarwinAttributeParseError.recordOverrun
            }
            switch bit {
            case DarwinAttributeBits.commonName:
                guard let offset = readInt32(buffer, at: cursor),
                      let nameLength = readUInt32(buffer, at: cursor + 4) else {
                    throw DarwinAttributeParseError.truncatedRecord
                }
                nameReferencePosition = cursor
                nameReferenceOffset = offset
                nameReferenceLength = nameLength
            case DarwinAttributeBits.commonDevID:
                if let value = readInt32(buffer, at: cursor) {
                    deviceID = deviceIdentifier(value)
                }
            case DarwinAttributeBits.commonObjType:
                if let value = readUInt32(buffer, at: cursor) {
                    kind = NodeKindMapper.kind(forObjType: value)
                }
            case DarwinAttributeBits.commonModTime:
                if let seconds = readInt64(buffer, at: cursor),
                   let nanoseconds = readInt64(buffer, at: cursor + 8) {
                    modifiedAt = Date(
                        timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000
                    )
                }
            case DarwinAttributeBits.commonFlags:
                if let value = readUInt32(buffer, at: cursor) {
                    isFirmlink = (value & DarwinAttributeBits.fileFlagFirmlink) != 0
                }
            case DarwinAttributeBits.commonFileID:
                fileID = readUInt64(buffer, at: cursor)
            case DarwinAttributeBits.commonParentID:
                parentFileID = readUInt64(buffer, at: cursor)
            default:
                break
            }
            cursor += size
        }

        var isMountPoint = false
        // Directory attributes (ATTR_DIR_MOUNTSTATUS).
        if (request.dirattr & DarwinAttributeBits.dirMountStatus) != 0,
           (returnedDirectory & DarwinAttributeBits.dirMountStatus) != 0 {
            guard cursor + 4 <= recordEnd else {
                throw DarwinAttributeParseError.recordOverrun
            }
            if let value = readUInt32(buffer, at: cursor) {
                isMountPoint = (value & DarwinAttributeBits.mountStatusMountPoint) != 0
            }
            cursor += 4
        }

        var linkCount: UInt64?
        var logicalBytes: UInt64?
        var allocatedBytes: UInt64?
        // File attributes in ascending bit order (LINKCOUNT, TOTALSIZE,
        // ALLOCSIZE).
        for (bit, size) in Self.fileOrder {
            guard (request.fileattr & bit) != 0,
                  (returnedFile & bit) != 0 else { continue }
            guard cursor + size <= recordEnd else {
                throw DarwinAttributeParseError.recordOverrun
            }
            switch bit {
            case DarwinAttributeBits.fileLinkCount:
                if let value = readUInt32(buffer, at: cursor) {
                    linkCount = UInt64(value)
                }
            case DarwinAttributeBits.fileTotalSize:
                if let value = readInt64(buffer, at: cursor) {
                    logicalBytes = nonNegativeUInt64(value)
                }
            case DarwinAttributeBits.fileAllocSize:
                if let value = readInt64(buffer, at: cursor) {
                    allocatedBytes = nonNegativeUInt64(value)
                }
            default:
                break
            }
            cursor += size
        }

        // Resolve the variable-length name. `attr_dataoffset` is relative to the
        // reference structure itself; the name data must sit after every fixed
        // field of this record and stay inside the record.
        let fixedFieldsEnd = cursor
        guard nameReferencePosition >= 0 else {
            throw DarwinAttributeParseError.missingNameAttribute
        }
        guard nameReferenceOffset >= 0 else {
            throw DarwinAttributeParseError.invalidNameReference
        }
        guard nameReferenceLength >= 1 else {
            throw DarwinAttributeParseError.missingNameTerminator
        }
        let nameStart = nameReferencePosition + Int(nameReferenceOffset)
        let nameLength = Int(nameReferenceLength)
        guard nameStart >= recordStart, nameLength >= 0 else {
            throw DarwinAttributeParseError.invalidNameReference
        }
        guard nameStart >= fixedFieldsEnd else {
            throw DarwinAttributeParseError.nameOverlapsFixedFields
        }
        let nameEnd = nameStart + nameLength
        guard nameEnd <= recordEnd, nameEnd >= nameStart else {
            throw DarwinAttributeParseError.nameOutOfRecord
        }
        // The attribute length must include the terminating NUL and no interior
        // NUL may appear before it.
        guard buffer[nameEnd - 1] == 0 else {
            throw DarwinAttributeParseError.missingNameTerminator
        }
        let contentEnd = nameEnd - 1
        for index in nameStart..<contentEnd where buffer[index] == 0 {
            throw DarwinAttributeParseError.missingNameTerminator
        }
        var nameBytes = [UInt8]()
        nameBytes.reserveCapacity(max(0, contentEnd - nameStart))
        for index in nameStart..<contentEnd {
            nameBytes.append(buffer[index])
        }
        guard !nameBytes.isEmpty else {
            throw DarwinAttributeParseError.emptyName
        }

        let entry = RawDirectoryEntry(
            nameBytes: nameBytes,
            kind: kind,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            deviceID: deviceID,
            fileID: fileID,
            parentFileID: parentFileID,
            linkCount: linkCount,
            modifiedAt: modifiedAt,
            entryError: entryError,
            isMountPoint: isMountPoint,
            isFirmlink: isFirmlink,
            usesFallback: false
        )
        return RecordResult(entry: entry, nextOffset: recordEnd)
    }

    // MARK: - Field ordering

    private static let commonOrder: [(UInt32, Int)] = [
        (DarwinAttributeBits.commonName, 8),
        (DarwinAttributeBits.commonDevID, 4),
        (DarwinAttributeBits.commonObjType, 4),
        (DarwinAttributeBits.commonModTime, 16),
        (DarwinAttributeBits.commonFlags, 4),
        (DarwinAttributeBits.commonFileID, 8),
        (DarwinAttributeBits.commonParentID, 8)
    ]

    private static let fileOrder: [(UInt32, Int)] = [
        (DarwinAttributeBits.fileLinkCount, 4),
        (DarwinAttributeBits.fileTotalSize, 8),
        (DarwinAttributeBits.fileAllocSize, 8)
    ]

    // MARK: - Bounds-checked little-endian readers

    private func readUInt32(_ buffer: UnsafeRawBufferPointer, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= buffer.count - 4 else { return nil }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(buffer[offset + index]) << (8 * index)
        }
        return value
    }

    private func readInt32(_ buffer: UnsafeRawBufferPointer, at offset: Int) -> Int32? {
        readUInt32(buffer, at: offset).map { Int32(bitPattern: $0) }
    }

    private func readUInt64(_ buffer: UnsafeRawBufferPointer, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= buffer.count - 8 else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(buffer[offset + index]) << (8 * index)
        }
        return value
    }

    private func readInt64(_ buffer: UnsafeRawBufferPointer, at offset: Int) -> Int64? {
        readUInt64(buffer, at: offset).map { Int64(bitPattern: $0) }
    }
}
