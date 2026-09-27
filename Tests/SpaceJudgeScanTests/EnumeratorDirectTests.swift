import Darwin
import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

@Suite("Enumerator direct")
struct EnumeratorDirectTests {
    private func openDirectory(_ path: String) -> FileDescriptor {
        let raw = POSIXPath.open(Array(path.utf8), flags: O_RDONLY | O_DIRECTORY)
        return FileDescriptor(raw)
    }

    @Test("Bulk enumerator falls back to reference when the buffer is too small")
    func bulkFallback() throws {
        let fixture = try TempFixture()
        try fixture.file("a.txt", contents: "hello")
        try fixture.file("b.txt", contents: "world")
        try fixture.directory("sub")

        let descriptor = openDirectory(fixture.url.path)
        defer { descriptor.close() }
        #expect(descriptor.isValid)

        let bulk = DarwinBulkEnumerator(bufferSize: 32)
        var cursor = try bulk.makeCursor(
            in: DirectoryHandle(fileDescriptor: descriptor.rawValue),
            request: EnumerationRequest()
        )
        var collected: [RawDirectoryEntry] = []
        while true {
            let page = try cursor.nextPage()
            collected.append(contentsOf: page.entries)
            if page.isLast { break }
        }
        let entries = collected
        let names = Set(entries.map { String(decoding: $0.nameBytes, as: UTF8.self) })
        #expect(names == ["a.txt", "b.txt", "sub"])
        #expect(entries.allSatisfy { $0.usesFallback })
    }

    @Test("Bulk and reference return the same immediate names")
    func bulkMatchesReference() throws {
        let fixture = try TempFixture()
        try fixture.file("x.txt", contents: "1")
        try fixture.directory("dir")
        try fixture.symlink("link", to: "x.txt")

        let descriptor = openDirectory(fixture.url.path)
        defer { descriptor.close() }
        let handle = DirectoryHandle(fileDescriptor: descriptor.rawValue)

        let bulk = try collect(DarwinBulkEnumerator().makeCursor(in: handle, request: EnumerationRequest()))
        let reference = try collect(ReferenceEnumerator().makeCursor(in: handle, request: EnumerationRequest()))

        func canonical(_ entries: [RawDirectoryEntry]) -> [String: NodeKind] {
            var result: [String: NodeKind] = [:]
            for entry in entries {
                result[String(decoding: entry.nameBytes, as: UTF8.self)] = entry.kind
            }
            return result
        }
        #expect(canonical(bulk) == canonical(reference))
        #expect(bulk.allSatisfy { !$0.usesFallback })
    }

    @Test("Reference enumerator skips dot entries")
    func referenceSkipsDots() throws {
        let fixture = try TempFixture()
        try fixture.file("only.txt", contents: "x")
        let descriptor = openDirectory(fixture.url.path)
        defer { descriptor.close() }
        let entries = try collect(
            ReferenceEnumerator().makeCursor(
                in: DirectoryHandle(fileDescriptor: descriptor.rawValue),
                request: EnumerationRequest()
            )
        )
        #expect(entries.map { String(decoding: $0.nameBytes, as: UTF8.self) } == ["only.txt"])
    }

    private func collect(_ cursor: any DirectoryCursor) throws -> [RawDirectoryEntry] {
        var cursorValue = cursor
        var result: [RawDirectoryEntry] = []
        while true {
            let page = try cursorValue.nextPage()
            result.append(contentsOf: page.entries)
            if page.isLast { break }
        }
        return result
    }
}
