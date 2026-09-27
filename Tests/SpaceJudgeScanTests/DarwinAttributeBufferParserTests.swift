import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

@Suite("Darwin attribute parser")
struct DarwinAttributeBufferParserTests {
    private let parser = DarwinAttributeBufferParser()

    private func parse(_ specs: [BulkRecordFixtures.Spec], entryCount: Int? = nil) throws -> [RawDirectoryEntry] {
        let buffer = BulkRecordFixtures.buffer(specs)
        return try parser.parse(
            bytes: buffer,
            entryCount: entryCount ?? specs.count
        )
    }

    @Test("Parses a regular file record")
    func parsesRegularFile() throws {
        let entries = try parse([
            BulkRecordFixtures.file(name: "hello.txt", totalSize: 123, allocSize: 4096, fileID: 77)
        ])
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.nameBytes == Array("hello.txt".utf8))
        #expect(entry.kind == .regularFile)
        #expect(entry.logicalBytes == 123)
        #expect(entry.allocatedBytes == 4096)
        #expect(entry.fileID == 77)
        #expect(entry.parentFileID == 1)
        #expect(entry.deviceID == 0x0100_000F)
        #expect(entry.linkCount == 1)
        #expect(entry.entryError == nil)
        #expect(entry.modifiedAt != nil)
        #expect(!entry.isMountPoint)
    }

    @Test("Parses a directory record without file attributes")
    func parsesDirectory() throws {
        let entries = try parse([BulkRecordFixtures.directory(name: "sub")])
        let entry = try #require(entries.first)
        #expect(entry.kind == .directory)
        #expect(entry.logicalBytes == nil)
        #expect(entry.allocatedBytes == nil)
        #expect(entry.linkCount == nil)
        #expect(!entry.isMountPoint)
    }

    @Test("Parses a mount point directory")
    func parsesMountPoint() throws {
        let mountPoint = BulkRecordFixtures.directory(
            name: "Volumes",
            mountStatus: DarwinAttributeBits.mountStatusMountPoint
        )
        let entries = try parse([mountPoint])
        #expect(entries.first?.isMountPoint == true)
    }

    @Test("Parses a symbolic link")
    func parsesSymlink() throws {
        let entries = try parse([BulkRecordFixtures.symlink(name: "link", targetLength: 8)])
        let entry = try #require(entries.first)
        #expect(entry.kind == .symbolicLink)
        #expect(entry.logicalBytes == 8)
        #expect(entry.allocatedBytes == 0)
    }

    @Test("Returned bitmap gaps map to unknown, not zero")
    func missingReturnedFieldsBecomeUnknown() throws {
        var spec = BulkRecordFixtures.file()
        spec.returnedCommon &= ~DarwinAttributeBits.commonDevID
        spec.returnedCommon &= ~DarwinAttributeBits.commonModTime
        spec.returnedCommon &= ~DarwinAttributeBits.commonFlags
        let entries = try parse([spec])
        let entry = try #require(entries.first)
        #expect(entry.deviceID == nil)
        #expect(entry.modifiedAt == nil)
        #expect(entry.fileID == 42)
        #expect(entry.logicalBytes == 100)
    }

    @Test("Entry-level error is reported and the record still parses")
    func entryErrorIsReported() throws {
        var spec = BulkRecordFixtures.file()
        spec.error = UInt32(EACCES)
        let entries = try parse([spec])
        let entry = try #require(entries.first)
        #expect(entry.entryError == EACCES)
    }

    @Test("Multiple records with variable name lengths")
    func multipleRecords() throws {
        let specs = [
            BulkRecordFixtures.file(name: "a"),
            BulkRecordFixtures.directory(name: "bbbbbbbbbb"),
            BulkRecordFixtures.symlink(name: "ö")
        ]
        let entries = try parse(specs)
        #expect(entries.count == 3)
        #expect(entries[0].nameBytes == Array("a".utf8))
        #expect(entries[1].nameBytes == Array("bbbbbbbbbb".utf8))
        #expect(entries[2].nameBytes == Array("ö".utf8))
    }

    @Test("A missing name terminator is rejected")
    func missingTerminatorRejected() {
        var spec = BulkRecordFixtures.file()
        spec.name = [0x66, 0x6F, 0x6F]
        spec.includeNameTerminator = false
        let buffer = BulkRecordFixtures.build(spec)
        #expect(throws: DarwinAttributeParseError.missingNameTerminator) {
            _ = try parser.parse(bytes: buffer, entryCount: 1)
        }
    }

    @Test("An interior NUL in the name is rejected")
    func interiorNulRejected() {
        var spec = BulkRecordFixtures.file()
        spec.name = [0x61, 0x00, 0x62]
        spec.includeNameTerminator = true
        let buffer = BulkRecordFixtures.build(spec)
        #expect(throws: DarwinAttributeParseError.missingNameTerminator) {
            _ = try parser.parse(bytes: buffer, entryCount: 1)
        }
    }

    @Test("A name offset pointing into the fixed fields is rejected")
    func nameOverlapsFixedFieldsRejected() {
        let buffer = BulkRecordFixtures.build(BulkRecordFixtures.file())
        var patched = buffer
        let referenceOffset = 28
        // Offset 0 makes the name data start at the attrreference itself, which
        // is inside the fixed-field region.
        patched[referenceOffset] = 0
        patched[referenceOffset + 1] = 0
        patched[referenceOffset + 2] = 0
        patched[referenceOffset + 3] = 0
        #expect(throws: DarwinAttributeParseError.nameOverlapsFixedFields) {
            _ = try parser.parse(bytes: patched, entryCount: 1)
        }
    }

    @Test("Invalid UTF-8 name is preserved as raw bytes")
    func invalidUTF8NamePreserved() throws {
        var spec = BulkRecordFixtures.file()
        spec.name = [0xFF, 0xFE, 0x41]
        let entries = try parse([spec])
        #expect(entries.first?.nameBytes == [0xFF, 0xFE, 0x41])
    }

    @Test("Record padding is tolerated")
    func paddingTolerated() throws {
        var spec = BulkRecordFixtures.file()
        spec.padToMultipleOf8 = false
        let entries = try parse([spec])
        #expect(entries.count == 1)
    }

    @Test("Data input is accepted")
    func dataInput() throws {
        let buffer = Data(BulkRecordFixtures.buffer([BulkRecordFixtures.file(name: "data.bin")]))
        let entries = try parser.parse(data: buffer, entryCount: 1)
        #expect(entries.first?.nameBytes == Array("data.bin".utf8))
    }

    @Test("Negative entry count is rejected")
    func negativeEntryCount() {
        #expect(throws: DarwinAttributeParseError.negativeEntryCount) {
            _ = try parser.parse(bytes: [], entryCount: -1)
        }
    }

    @Test("Insufficient bytes for a length field are rejected")
    func truncatedLength() {
        #expect(throws: DarwinAttributeParseError.truncatedRecord) {
            _ = try parser.parse(bytes: [0x01, 0x02], entryCount: 1)
        }
        #expect(throws: DarwinAttributeParseError.truncatedRecord) {
            _ = try parser.parse(bytes: [], entryCount: 1)
        }
    }

    @Test("Zero record length is rejected")
    func zeroLength() {
        var spec = BulkRecordFixtures.file()
        spec.recordLengthOverride = 0
        let buffer = BulkRecordFixtures.build(spec)
        #expect(throws: DarwinAttributeParseError.invalidRecordLength) {
            _ = try parser.parse(bytes: buffer, entryCount: 1)
        }
    }

    @Test("Record longer than the buffer is rejected")
    func recordOverrun() {
        var spec = BulkRecordFixtures.file()
        spec.recordLengthOverride = 100_000
        let buffer = BulkRecordFixtures.build(spec)
        #expect(throws: DarwinAttributeParseError.recordOverrun) {
            _ = try parser.parse(bytes: buffer, entryCount: 1)
        }
    }

    @Test("Missing returned-attributes bitmap is rejected")
    func missingReturnedBitmap() {
        var spec = BulkRecordFixtures.file()
        spec.returnedCommon &= ~DarwinAttributeBits.commonReturnedAttrs
        let buffer = BulkRecordFixtures.build(spec)
        #expect(throws: DarwinAttributeParseError.missingReturnedAttributes) {
            _ = try parser.parse(bytes: buffer, entryCount: 1)
        }
    }

    @Test("Missing name attribute is rejected")
    func missingName() {
        var spec = BulkRecordFixtures.file()
        spec.returnedCommon &= ~DarwinAttributeBits.commonName
        let buffer = BulkRecordFixtures.build(spec)
        #expect(throws: DarwinAttributeParseError.missingNameAttribute) {
            _ = try parser.parse(bytes: buffer, entryCount: 1)
        }
    }

    @Test("Name offset pointing past the record is rejected")
    func nameOffsetOutOfRecord() {
        let buffer = BulkRecordFixtures.build(BulkRecordFixtures.file())
        // Patch the attrreference offset (record offset 28 when error is present).
        var patched = buffer
        let errorBitPresent = (BulkRecordFixtures.request.commonattr & DarwinAttributeBits.commonError) != 0
        let referenceOffset = errorBitPresent ? 28 : 24
        patched[referenceOffset] = 0x40
        patched[referenceOffset + 1] = 0x42
        patched[referenceOffset + 2] = 0x0F
        patched[referenceOffset + 3] = 0x00
        #expect(throws: DarwinAttributeParseError.self) {
            _ = try parser.parse(bytes: patched, entryCount: 1)
        }
    }

    @Test("Name length past the record is rejected")
    func nameLengthOutOfRecord() {
        let buffer = BulkRecordFixtures.build(BulkRecordFixtures.file())
        var patched = buffer
        let referenceOffset = 28
        patched[referenceOffset + 4] = 0xFF
        patched[referenceOffset + 5] = 0xFF
        patched[referenceOffset + 6] = 0x00
        patched[referenceOffset + 7] = 0x00
        #expect(throws: DarwinAttributeParseError.nameOutOfRecord) {
            _ = try parser.parse(bytes: patched, entryCount: 1)
        }
    }

    @Test("Empty name is rejected")
    func emptyName() {
        var spec = BulkRecordFixtures.file()
        spec.name = []
        spec.includeNameTerminator = true
        let buffer = BulkRecordFixtures.build(spec)
        #expect(throws: DarwinAttributeParseError.emptyName) {
            _ = try parser.parse(bytes: buffer, entryCount: 1)
        }
    }

    @Test("Entry count beyond the buffer is rejected")
    func entryCountBeyondBuffer() {
        let buffer = BulkRecordFixtures.buffer([BulkRecordFixtures.file()])
        #expect(throws: DarwinAttributeParseError.truncatedRecord) {
            _ = try parser.parse(bytes: buffer, entryCount: 2)
        }
    }
}
