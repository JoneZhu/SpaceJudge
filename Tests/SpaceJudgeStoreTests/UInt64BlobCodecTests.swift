import Foundation
import Testing
@testable import SpaceJudgeStore

@Suite("UInt64 blob codec")
struct UInt64BlobCodecTests {
    private let boundaryValues: [UInt64] = [
        0,
        1,
        255,
        256,
        UInt64(Int64.max),
        UInt64(Int64.max) + 1,
        UInt64.max - 1,
        UInt64.max
    ]

    @Test("Round-trips every boundary value with an exact 8-byte encoding")
    func roundTrip() throws {
        for value in boundaryValues {
            let encoded = UInt64BlobCodec.encode(value)
            #expect(encoded.count == 8)
            #expect(try UInt64BlobCodec.decode(encoded) == value)
        }
    }

    @Test("Zero encodes as eight zero bytes and is distinct from NULL")
    func zeroVersusNull() throws {
        let zero = UInt64BlobCodec.encode(0)
        #expect(zero == Data(repeating: 0, count: 8))
        #expect(try UInt64BlobCodec.decode(zero) == 0)
        #expect(try UInt64BlobCodec.decodeOptional(nil) == nil)
        #expect(try UInt64BlobCodec.decodeOptional(zero) == 0)
    }

    @Test("Big-endian BLOB order equals unsigned numeric order")
    func sorting() {
        let values: [UInt64] = [
            UInt64.max,
            0,
            UInt64(Int64.max) + 1,
            1,
            UInt64(Int64.max),
            256,
            255
        ]
        let encoded = values.map { Array(UInt64BlobCodec.encode($0)) }
        let sortedByBlob = encoded.sorted { $0.lexicographicallyPrecedes($1) }
        let expected = values.sorted().map { Array(UInt64BlobCodec.encode($0)) }
        #expect(sortedByBlob == expected)
    }

    @Test("Wrong lengths fail explicitly")
    func invalidLength() {
        #expect(throws: SnapshotStoreError.invalidUInt64BlobLength(0)) {
            try UInt64BlobCodec.decode(Data())
        }
        #expect(throws: SnapshotStoreError.invalidUInt64BlobLength(7)) {
            try UInt64BlobCodec.decode(Data(repeating: 0, count: 7))
        }
        #expect(throws: SnapshotStoreError.invalidUInt64BlobLength(9)) {
            try UInt64BlobCodec.decode(Data(repeating: 0, count: 9))
        }
    }
}
