import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

@Suite("Firmlink parser facts")
struct FirmlinkParserTests {
    private let parser = DarwinAttributeBufferParser()

    private func parse(_ specs: [BulkRecordFixtures.Spec]) throws -> [RawDirectoryEntry] {
        let buffer = BulkRecordFixtures.buffer(specs)
        return try parser.parse(bytes: buffer, entryCount: specs.count)
    }

    @Test("SF_FIRMLINK in returned flags becomes isFirmlink")
    func firmlinkFlagDetected() throws {
        var spec = BulkRecordFixtures.directory(name: "Applications")
        spec.fileFlags = UInt32(SF_FIRMLINK)
        spec.fileID = 9_999
        spec.parentID = 1
        let entries = try parse([spec])
        let entry = try #require(entries.first)
        #expect(entry.isFirmlink)
        // The FLAGS slot is consumed without disturbing FILEID/PARENTID.
        #expect(entry.fileID == 9_999)
        #expect(entry.parentFileID == 1)
        #expect(entry.kind == .directory)
    }

    @Test("A directory without SF_FIRMLINK is not a firmlink")
    func ordinaryDirectoryNotFirmlink() throws {
        var spec = BulkRecordFixtures.directory(name: "System")
        spec.fileFlags = 0
        let entries = try parse([spec])
        #expect(entries.first?.isFirmlink == false)
    }

    @Test("Other file flags do not become a firmlink")
    func unrelatedFlagsIgnored() throws {
        var spec = BulkRecordFixtures.directory(name: "System")
        // UF_HIDDEN (0x8000) and UF_IMMUTABLE (0x00000002) are unrelated.
        spec.fileFlags = 0x8000 | 0x00000002
        let entries = try parse([spec])
        #expect(entries.first?.isFirmlink == false)
    }

    @Test("A missing FLAGS attribute maps to not-a-firmlink, not a guess")
    func missingFlagsAttribute() throws {
        var spec = BulkRecordFixtures.directory(name: "System")
        spec.returnedCommon &= ~DarwinAttributeBits.commonFlags
        let entries = try parse([spec])
        #expect(entries.first?.isFirmlink == false)
    }

    @Test("Mount point and firmlink facts can be expressed together")
    func mountAndFirmlinkTogether() throws {
        var spec = BulkRecordFixtures.directory(
            name: "Both",
            mountStatus: DarwinAttributeBits.mountStatusMountPoint
        )
        spec.fileFlags = UInt32(SF_FIRMLINK)
        let entries = try parse([spec])
        let entry = try #require(entries.first)
        #expect(entry.isMountPoint)
        #expect(entry.isFirmlink)
    }

    @Test("Fallback marking preserves the firmlink fact")
    func fallbackCopyPreservesFirmlink() {
        let original = RawDirectoryEntry(
            nameBytes: Array("Applications".utf8),
            kind: .directory,
            deviceID: 1,
            fileID: 7,
            isMountPoint: false,
            isFirmlink: true
        )
        let copied = BulkCursor.markingFallback(original)
        #expect(copied.isFirmlink)
        #expect(copied.usesFallback)
        #expect(copied.fileID == 7)
        #expect(copied.nameBytes == original.nameBytes)
    }

    @Test("Parser keeps FILEID/PARENTID offsets with a firmlink flag present")
    func offsetsAfterFlagsUnchanged() throws {
        var withFlag = BulkRecordFixtures.file(name: "a", fileID: 111)
        withFlag.fileFlags = UInt32(SF_FIRMLINK)
        withFlag.parentID = 222
        var withoutFlag = BulkRecordFixtures.file(name: "a", fileID: 111)
        withoutFlag.parentID = 222
        withoutFlag.fileFlags = 0

        let flagged = try #require(try parse([withFlag]).first)
        let plain = try #require(try parse([withoutFlag]).first)
        #expect(flagged.fileID == plain.fileID)
        #expect(flagged.parentFileID == plain.parentFileID)
        #expect(flagged.allocatedBytes == plain.allocatedBytes)
        #expect(flagged.logicalBytes == plain.logicalBytes)
        #expect(flagged.isFirmlink)
        #expect(!plain.isFirmlink)
    }
}
