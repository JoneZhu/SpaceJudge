import Testing
@testable import SpaceJudgeScan

/// Default-value regressions for `ScanConfiguration`.
///
/// The event buffer default is a real product backpressure parameter: each
/// buffered event holds a full `NodeBatch`, so a large buffer is what let many
/// batches accumulate in memory during a million-node scan. These tests pin the
/// new default without changing any other tunable or the explicit-override
/// behavior.
@Suite("Scan configuration defaults")
struct ScanConfigurationDefaultsTests {
    @Test("The event buffer default is the bounded 64")
    func eventBufferDefault() {
        #expect(ScanConfiguration().eventBufferSize == 64)
    }

    @Test("The other tuning defaults are unchanged")
    func otherDefaults() {
        let configuration = ScanConfiguration()
        #expect(configuration.batchNodeLimit == 2000)
        #expect(configuration.batchTimeMilliseconds == 50)
        #expect(configuration.maximumQueuedDirectories == 65_536)
        #expect(configuration.resolvedWorkerCount >= 1)
        #expect(configuration.resolvedWorkerCount <= 4)
    }

    @Test("An explicit event buffer is honored and clamped to at least one")
    func explicitOverride() {
        #expect(ScanConfiguration(eventBufferSize: 1).eventBufferSize == 1)
        #expect(ScanConfiguration(eventBufferSize: 16).eventBufferSize == 16)
        #expect(ScanConfiguration(eventBufferSize: 0).eventBufferSize == 1)
        #expect(ScanConfiguration(eventBufferSize: 512).eventBufferSize == 512)
    }
}
