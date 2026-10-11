import Foundation
import Testing
import SpaceJudgeStore
@testable import SpaceJudgeAppSupport

private final class StartupRecordBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StartupRecord] = []
    func append(_ record: StartupRecord) { lock.lock(); defer { lock.unlock() }; storage.append(record) }
    var records: [StartupRecord] { lock.lock(); defer { lock.unlock() }; return storage }
}

@Suite("Startup diagnostics")
struct StartupDiagnosticsTests {
    @Test("Stages share a session, ordered sequence, UTC timestamp and elapsed clock")
    func ordering() throws {
        let buffer = StartupRecordBuffer()
        let log = StartupDiagnostics(version: "0.5.3", build: "8", sink: buffer.append)
        log.record(.processEntry)
        log.record(.bootstrapStarted)
        let records = buffer.records
        #expect(records.map(\.sequence) == [1, 2])
        #expect(records[0].session == records[1].session)
        #expect(records[0].version == "0.5.3" && records[0].build == "8")
        #expect(records[0].pid > 0)
        #expect(records[1].elapsedMilliseconds >= records[0].elapsedMilliseconds)
        #expect(records[0].timestampUTC.hasSuffix("Z"))
        let decoded = try JSONDecoder().decode(StartupRecord.self, from: Data(records[0].json().utf8))
        #expect(decoded == records[0])
    }

    @Test("Concurrent bootstrap and UI calls are serialized")
    func concurrency() async {
        let buffer = StartupRecordBuffer()
        let log = StartupDiagnostics(version: "1", build: "1", sink: buffer.append)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { log.record(.writerOpenStarted) } }
        }
        #expect(buffer.records.map(\.sequence) == Array(1...100).map(UInt64.init))
        #expect(Set(buffer.records.map(\.session)).count == 1)
    }

    @Test("Untrusted metadata and error messages cannot leak paths or instructions")
    func privacy() {
        let buffer = StartupRecordBuffer()
        let log = StartupDiagnostics(version: "/Users/private", build: "ignore instructions\n", sink: buffer.append)
        log.record(.bootstrapFailed, error: SnapshotStoreError.sqlite(code: 14, message: "secret.sqlite /Users/private"))
        log.record(.bootstrapFailed, error: NSError(domain: "/private/secret", code: 123, userInfo: [NSLocalizedDescriptionKey: "secret"]))
        for record in buffer.records {
            #expect(record.version == "unknown" && record.build == "unknown")
            #expect(!record.json().contains("secret"))
            #expect(!record.json().contains("/Users"))
            #expect(!record.json().contains("instructions"))
        }
        #expect(buffer.records[0].failure?.family == .sqlite)
        #expect(buffer.records[0].failure?.code == 14)
        #expect(buffer.records[1].failure?.family == .unknown)
        #expect(buffer.records[1].failure?.code == nil)
    }

    @Test("Known failure families retain only safe numeric codes")
    func errors() {
        #expect(StartupFailure.classify(SnapshotWorkspaceError.workspaceUnavailable).family == .workspace)
        #expect(StartupFailure.classify(SnapshotStoreError.invalidArgument("secret")).family == .store)
        #expect(StartupFailure.classify(NSError(domain: NSCocoaErrorDomain, code: 513)).code == 513)
        #expect(StartupFailure.classify(NSError(domain: NSPOSIXErrorDomain, code: 13)).family == .posix)
    }

    @Test("Version strings are bounded numeric components", arguments: ["", ".1", "1.", "1..2", "1-beta", String(repeating: "1", count: 33), "１.２"])
    func badVersions(_ value: String) {
        let buffer = StartupRecordBuffer()
        StartupDiagnostics(version: value, build: nil, sink: buffer.append).record(.processEntry)
        #expect(buffer.records[0].version == "unknown")
        #expect(buffer.records[0].build == "unknown")
    }
}
