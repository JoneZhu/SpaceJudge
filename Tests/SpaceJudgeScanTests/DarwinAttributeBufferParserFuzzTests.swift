import Foundation
import Testing
@testable import SpaceJudgeScan

/// Deterministic pseudo-random generator so the fuzz corpus is reproducible.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func int(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }
}

@Suite("Darwin parser fuzz")
struct DarwinAttributeBufferParserFuzzTests {
    private let parser = DarwinAttributeBufferParser()

    @Test("Ten thousand deterministic random buffers never crash or trap")
    func randomBuffers() {
        var generator = SplitMix64(state: 0x5EED_1234_ABCD_0001)
        let seedRecords = [
            BulkRecordFixtures.file(name: "alpha"),
            BulkRecordFixtures.directory(name: "beta"),
            BulkRecordFixtures.symlink(name: "gamma")
        ]
        let validBuffer = BulkRecordFixtures.buffer(seedRecords)

        for iteration in 0..<10_000 {
            var bytes: [UInt8]
            if iteration % 2 == 0 {
                let length = generator.int(upperBound: 512)
                bytes = (0..<length).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            } else {
                let length = generator.int(upperBound: validBuffer.count + 1)
                bytes = Array(validBuffer.prefix(length))
            }
            let entryCount = generator.int(upperBound: 5)
            // The only requirement is that arbitrary input cannot trap or read
            // out of bounds; parse failures are expected and ignored.
            _ = try? parser.parse(bytes: bytes, entryCount: entryCount)
        }
    }

    @Test("Mutating a valid record keeps the parser memory-safe")
    func mutatedValidRecords() {
        var generator = SplitMix64(state: 0xC0FF_EE00_1234_5678)
        let valid = BulkRecordFixtures.build(BulkRecordFixtures.file(name: "mutation-target"))
        for _ in 0..<2_000 {
            var bytes = valid
            let mutations = 1 + generator.int(upperBound: 6)
            for _ in 0..<mutations where !bytes.isEmpty {
                let index = generator.int(upperBound: bytes.count)
                bytes[index] = UInt8(truncatingIfNeeded: generator.next())
            }
            _ = try? parser.parse(bytes: bytes, entryCount: 1)
        }
    }
}
