import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

/// Cursor that replays an explicit script. Used to force page boundaries and
/// mid-directory failures that a real file system will not produce on demand.
private final class SequenceCursor: DirectoryCursor {
    enum Result: Sendable {
        case page([RawDirectoryEntry], isLast: Bool)
        case failure(Int32)
    }

    private var results: [Result]
    private var index = 0

    init(_ results: [Result]) {
        self.results = results
    }

    func nextPage() throws -> DirectoryEntryPage {
        guard index < results.count else {
            return DirectoryEntryPage(entries: [], isLast: true)
        }
        let result = results[index]
        index += 1
        switch result {
        case .page(let entries, let isLast):
            return DirectoryEntryPage(entries: entries, isLast: isLast)
        case .failure(let code):
            throw ScanError.enumerationFailed(errno: code)
        }
    }
}

private final class SequenceEnumerator: DirectoryEnumerator, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[SequenceCursor.Result]]

    init(_ scripts: [[SequenceCursor.Result]]) {
        self.scripts = scripts
    }

    func makeCursor(
        in directory: DirectoryHandle,
        request: EnumerationRequest
    ) throws -> any DirectoryCursor {
        lock.lock()
        let script = scripts.isEmpty ? [SequenceCursor.Result.page([], isLast: true)] : scripts.removeFirst()
        lock.unlock()
        return SequenceCursor(script)
    }
}

@Suite("Paged enumeration", .serialized)
struct PagedEnumerationTests {
    private func openDirectory(_ path: String) -> FileDescriptor {
        let raw = POSIXPath.open(Array(path.utf8), flags: O_RDONLY | O_DIRECTORY)
        return FileDescriptor(raw)
    }

    private func collect(_ cursor: any DirectoryCursor) throws -> (entries: [RawDirectoryEntry], maxPage: Int, pages: Int) {
        var cursorValue = cursor
        var entries: [RawDirectoryEntry] = []
        var maxPage = 0
        var pages = 0
        while true {
            let page = try cursorValue.nextPage()
            pages += 1
            maxPage = max(maxPage, page.entries.count)
            entries.append(contentsOf: page.entries)
            if page.isLast { break }
        }
        return (entries, maxPage, pages)
    }

    private func request(for path: String) -> ScanRequest {
        ScanRequest(root: ScanRoot(fileSystemPath: path, displayName: path))
    }

    // MARK: Page limits

    @Test("Reference page limits never exceed the configured size", arguments: [1, 7, 128])
    func referencePageLimits(limit: Int) throws {
        let fixture = try TempFixture()
        let expected = Set((0..<40).map { "file-\($0).txt" })
        for name in expected {
            try fixture.file(name, contents: "x")
        }
        let descriptor = openDirectory(fixture.url.path)
        defer { descriptor.close() }

        let cursor = try ReferenceEnumerator(pageEntryLimit: limit)
            .makeCursor(in: DirectoryHandle(fileDescriptor: descriptor.rawValue), request: EnumerationRequest())
        let result = try collect(cursor)
        let names = Set(result.entries.map { String(decoding: $0.nameBytes, as: UTF8.self) })
        #expect(names == expected)
        #expect(result.maxPage <= limit)
        #expect(result.pages >= Int(ceil(40.0 / Double(limit))))
    }

    @Test("A 10,000-entry directory is delivered in bounded pages", .timeLimit(.minutes(2)))
    func wideDirectoryPages() throws {
        let fixture = try TempFixture()
        for index in 0..<10_000 {
            try fixture.file("f\(index)", contents: "")
        }
        let descriptor = openDirectory(fixture.url.path)
        defer { descriptor.close() }
        let cursor = try ReferenceEnumerator(pageEntryLimit: 128)
            .makeCursor(in: DirectoryHandle(fileDescriptor: descriptor.rawValue), request: EnumerationRequest())
        let result = try collect(cursor)
        #expect(result.entries.count == 10_000)
        #expect(result.maxPage <= 128)
        #expect(result.pages >= 79)
        #expect(Set(result.entries.map(\.nameBytes)).count == 10_000)
    }

    @Test("Bulk delivers multiple buffer pages")
    func bulkMultiplePages() throws {
        let fixture = try TempFixture()
        for index in 0..<600 {
            try fixture.file("entry-\(index)-padding-padding-padding", contents: "x")
        }
        let descriptor = openDirectory(fixture.url.path)
        defer { descriptor.close() }
        let cursor = try DarwinBulkEnumerator(bufferSize: 4096)
            .makeCursor(in: DirectoryHandle(fileDescriptor: descriptor.rawValue), request: EnumerationRequest())
        let result = try collect(cursor)
        #expect(result.entries.count == 600)
        #expect(result.pages > 1)
        #expect(result.entries.allSatisfy { !$0.usesFallback })
    }

    @Test("Bulk falls back before publishing any bulk page without duplicates")
    func bulkEarlyFallback() throws {
        let fixture = try TempFixture()
        for index in 0..<8 {
            try fixture.file("a\(index).txt", contents: "x")
        }
        let descriptor = openDirectory(fixture.url.path)
        defer { descriptor.close() }

        let enumerator = DarwinBulkEnumerator(
            bufferSize: 64,
            parser: DarwinAttributeBufferParser(),
            fallback: ReferenceEnumerator(),
            bulkRead: { _, _, _, _, _ in
                errno = ERANGE
                return -1
            },
            parsePage: { _, _, _ in [] }
        )
        let cursor = try enumerator.makeCursor(
            in: DirectoryHandle(fileDescriptor: descriptor.rawValue),
            request: EnumerationRequest()
        )
        let result = try collect(cursor)
        #expect(result.entries.count == 8)
        #expect(result.entries.allSatisfy { $0.usesFallback })
        #expect(Set(result.entries.map(\.nameBytes)).count == 8)
    }

    @Test("Bulk does not rewind after publishing a page on parse failure")
    func bulkDoesNotRewindAfterPublishedPage() throws {
        let fixture = try TempFixture()
        try fixture.file("real.txt", contents: "x")
        let descriptor = openDirectory(fixture.url.path)
        defer { descriptor.close() }

        let entry = RawDirectoryEntry(
            nameBytes: Array("synthetic".utf8),
            kind: .regularFile,
            logicalBytes: 1,
            allocatedBytes: 4096,
            deviceID: 1,
            fileID: 1,
            linkCount: 1
        )
        let callCount = LockedCounter()
        let enumerator = DarwinBulkEnumerator(
            bufferSize: 64,
            parser: DarwinAttributeBufferParser(),
            fallback: ReferenceEnumerator(),
            bulkRead: { _, _, _, _, _ in 1 },
            parsePage: { _, _, _ in
                if callCount.increment() == 1 {
                    return [entry]
                }
                throw DarwinAttributeParseError.truncatedRecord
            }
        )
        var cursor = try enumerator.makeCursor(
            in: DirectoryHandle(fileDescriptor: descriptor.rawValue),
            request: EnumerationRequest()
        )
        let first = try cursor.nextPage()
        #expect(first.entries == [entry])
        #expect(!first.isLast)
        #expect(first.entries.allSatisfy { !$0.usesFallback })

        do {
            _ = try cursor.nextPage()
            Issue.record("expected an explicit parse failure, not a fallback")
        } catch let error as ScanError {
            if case .parseFailed = error {
                // expected: no silent rewind, no duplicate facts
            } else {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    // MARK: Engine integration

    @Test("Reference and bulk agree with small page limits")
    func enginePageLimitDifferential() async throws {
        let fixture = try TempFixture()
        try fixture.directory("nested/deep")
        for index in 0..<150 {
            try fixture.file("nested/f\(index)", contents: "x")
        }
        try fixture.file("nested/deep/leaf", contents: "y")
        let path = fixture.url.path

        let reference = try await collectScan(
            engine: FileSystemScanEngine(
                configuration: ScanConfiguration(
                    enumerator: ReferenceEnumerator(pageEntryLimit: 7),
                    workerCount: 1,
                    batchNodeLimit: 13
                )
            ),
            request: request(for: path)
        )
        let bulk = try await collectScan(
            engine: FileSystemScanEngine(
                configuration: ScanConfiguration(
                    enumerator: DarwinBulkEnumerator(bufferSize: 4096),
                    workerCount: 2,
                    batchNodeLimit: 13
                )
            ),
            request: request(for: path)
        )
        #expect(reference.status == .completed)
        #expect(bulk.status == .completed)
        #expect(reference.canonicalRows() == bulk.canonicalRows())
        #expect(reference.canonicalAggregates() == bulk.canonicalAggregates())
        #expect(reference.rootAggregate()?.attributedBytes == bulk.rootAggregate()?.attributedBytes)
    }

    @Test("A failure after a partial page does not duplicate facts")
    func partialThenFailureNoDuplicates() async throws {
        let fixture = try TempFixture()
        try fixture.directory("keep")
        let first = RawDirectoryEntry(
            nameBytes: Array("a".utf8), kind: .regularFile,
            logicalBytes: 1, allocatedBytes: 4096, deviceID: 1, fileID: 1, linkCount: 1
        )
        let second = RawDirectoryEntry(
            nameBytes: Array("b".utf8), kind: .regularFile,
            logicalBytes: 1, allocatedBytes: 4096, deviceID: 1, fileID: 2, linkCount: 1
        )
        let third = RawDirectoryEntry(
            nameBytes: Array("c".utf8), kind: .regularFile,
            logicalBytes: 1, allocatedBytes: 4096, deviceID: 1, fileID: 3, linkCount: 1
        )
        let enumerator = SequenceEnumerator([
            [
                .page([first, second], isLast: false),
                .page([third], isLast: false),
                .failure(EIO)
            ]
        ])
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(enumerator: enumerator, workerCount: 1, batchNodeLimit: 1)
        )
        let collected = try await collectScan(engine: engine, request: request(for: fixture.url.path))
        #expect(collected.status == .completed)
        #expect(collected.terminalCount == 1)
        let paths = collected.canonicalRows().keys.sorted()
        #expect(paths == ["", "a", "b", "c"])
        #expect(collected.rootAggregate()?.isComplete == false)
        #expect(collected.summary?.inaccessibleCount == 1)
    }

    @Test("Cancel between pages publishes only the cancelled terminal")
    func cancelBetweenPages() async throws {
        let fixture = try TempFixture()
        for index in 0..<5000 {
            try fixture.file("f\(index)", contents: "x")
        }
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(pageEntryLimit: 17),
                workerCount: 1,
                batchNodeLimit: 10,
                eventBufferSize: 4
            )
        )
        let collected = try await collectScan(
            engine: engine,
            request: request(for: fixture.url.path),
            cancelAfterFirstBatch: true
        )
        #expect(collected.status == .cancelled)
        #expect(collected.terminalCount == 1)
        #expect(collected.batchesAfterTerminal == 0)
    }

    @Test("Dropped cursors return duplicated descriptors to baseline")
    func cursorDescriptorCleanup() throws {
        let fixture = try TempFixture()
        for index in 0..<16 {
            try fixture.file("f\(index)", contents: "x")
        }
        let baseline = settledFileDescriptorCount()
        for _ in 0..<50 {
            let descriptor = openDirectory(fixture.url.path)
            let cursor = try ReferenceEnumerator(pageEntryLimit: 4)
                .makeCursor(in: DirectoryHandle(fileDescriptor: descriptor.rawValue), request: EnumerationRequest())
            var cursorValue = cursor
            _ = try cursorValue.nextPage()
            descriptor.close()
            // Cursor dropped here; its duplicate descriptor must be closed.
        }
        let after = settledFileDescriptorCount()
        #expect(after <= baseline + 4, "baseline=\(baseline) after=\(after)")
    }
}

/// Small thread-safe counter used by injected test seams.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
