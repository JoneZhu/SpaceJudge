import Foundation
import SpaceJudgeScan

/// Builds synthetic `getattrlistbulk` records matching the layout produced by
/// the current SDK and verified against the kernel on this machine.
enum BulkRecordFixtures {
    static let request = DarwinAttributeBufferParser.Request.phase1

    struct Spec {
        var returnedCommon: UInt32 = request.commonattr
        var returnedDirectory: UInt32 = 0
        var returnedFile: UInt32 = request.fileattr
        var error: UInt32 = 0
        var name: [UInt8] = Array("file.txt".utf8)
        var includeNameTerminator = true
        var devID: Int32 = 0x0100_000F
        var objType: UInt32 = 1
        var modSeconds: Int64 = 1_700_000_000
        var modNanos: Int64 = 0
        var fileFlags: UInt32 = 0
        var fileID: UInt64 = 42
        var parentID: UInt64 = 1
        var mountStatus: UInt32 = 0
        var linkCount: UInt32 = 1
        var totalSize: Int64 = 100
        var allocSize: Int64 = 100
        var recordLengthOverride: UInt32?
        var padToMultipleOf8 = true
    }

    static func file(
        name: String = "file.txt",
        totalSize: Int64 = 100,
        allocSize: Int64 = 100,
        linkCount: UInt32 = 1,
        fileID: UInt64 = 42,
        objType: UInt32 = 1
    ) -> Spec {
        var spec = Spec()
        spec.name = Array(name.utf8)
        spec.objType = objType
        spec.totalSize = totalSize
        spec.allocSize = allocSize
        spec.linkCount = linkCount
        spec.fileID = fileID
        return spec
    }

    static func directory(name: String = "subdir", mountStatus: UInt32 = 0) -> Spec {
        var spec = Spec()
        spec.name = Array(name.utf8)
        spec.returnedDirectory = request.dirattr
        spec.returnedFile = 0
        spec.objType = 2
        spec.mountStatus = mountStatus
        return spec
    }

    static func symlink(name: String = "link", targetLength: Int64 = 8) -> Spec {
        var spec = Spec()
        spec.name = Array(name.utf8)
        spec.objType = 5
        spec.totalSize = targetLength
        spec.allocSize = 0
        return spec
    }

    static func build(_ spec: Spec) -> [UInt8] {
        var bytes: [UInt8] = []

        func appendU32(_ value: UInt32) {
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
            bytes.append(UInt8(truncatingIfNeeded: value >> 16))
            bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        func appendI32(_ value: Int32) { appendU32(UInt32(bitPattern: value)) }
        func appendU64(_ value: UInt64) {
            appendU32(UInt32(truncatingIfNeeded: value))
            appendU32(UInt32(truncatingIfNeeded: value >> 32))
        }
        func appendI64(_ value: Int64) { appendU64(UInt64(bitPattern: value)) }

        appendU32(0) // length placeholder
        appendU32(spec.returnedCommon)
        appendU32(0) // volume
        appendU32(spec.returnedDirectory)
        appendU32(spec.returnedFile)
        appendU32(0) // fork

        if spec.returnedCommon & DarwinAttributeBits.commonError != 0 {
            appendU32(spec.error)
        }

        let referencePosition = bytes.count
        appendU32(0)
        appendU32(0)

        let common = spec.returnedCommon
        if common & DarwinAttributeBits.commonDevID != 0 { appendI32(spec.devID) }
        if common & DarwinAttributeBits.commonObjType != 0 { appendU32(spec.objType) }
        if common & DarwinAttributeBits.commonModTime != 0 {
            appendI64(spec.modSeconds)
            appendI64(spec.modNanos)
        }
        if common & DarwinAttributeBits.commonFlags != 0 { appendU32(spec.fileFlags) }
        if common & DarwinAttributeBits.commonFileID != 0 { appendU64(spec.fileID) }
        if common & DarwinAttributeBits.commonParentID != 0 { appendU64(spec.parentID) }

        if spec.returnedDirectory & DarwinAttributeBits.dirMountStatus != 0 {
            appendU32(spec.mountStatus)
        }
        if spec.returnedFile & DarwinAttributeBits.fileLinkCount != 0 { appendU32(spec.linkCount) }
        if spec.returnedFile & DarwinAttributeBits.fileTotalSize != 0 { appendI64(spec.totalSize) }
        if spec.returnedFile & DarwinAttributeBits.fileAllocSize != 0 { appendI64(spec.allocSize) }

        let nameOffset = bytes.count
        bytes.append(contentsOf: spec.name)
        if spec.includeNameTerminator {
            bytes.append(0)
        }
        let nameLength = bytes.count - nameOffset

        let offset = Int32(nameOffset - referencePosition)
        setU32(&bytes, at: referencePosition, value: UInt32(bitPattern: offset))
        setU32(&bytes, at: referencePosition + 4, value: UInt32(nameLength))

        if spec.padToMultipleOf8 {
            while bytes.count % 8 != 0 {
                bytes.append(0)
            }
        }
        setU32(&bytes, at: 0, value: spec.recordLengthOverride ?? UInt32(bytes.count))
        return bytes
    }

    static func buffer(_ specs: [Spec]) -> [UInt8] {
        specs.flatMap { build($0) }
    }

    private static func setU32(_ bytes: inout [UInt8], at offset: Int, value: UInt32) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
