import Foundation
import Testing
import SpaceJudgeDomain
import SpaceJudgeScan

@Suite("Enumerator differential")
struct EnumeratorDifferentialTests {
    private func request(
        for path: String,
        boundaryPolicy: BoundaryPolicy = .stayOnRootFileSystem,
        packagePolicy: PackagePolicy = .descend
    ) -> ScanRequest {
        ScanRequest(
            root: ScanRoot(fileSystemPath: path, displayName: path),
            sizeMetric: .allocated,
            boundaryPolicy: boundaryPolicy,
            packagePolicy: packagePolicy,
            symlinkPolicy: .doNotFollow
        )
    }

    private func makeFixture() throws -> TempFixture {
        let fixture = try TempFixture()
        try fixture.directory("nested/deep")
        try fixture.directory("empty")
        try fixture.file(".hidden", contents: "hidden")
        try fixture.file("文件夹/资料-📁.txt", contents: "unicode")
        try fixture.file("nested/deep/leaf.txt", contents: "leaf")
        try fixture.symlink("nested/loop", to: "loop")
        try fixture.symlink("nested/up", to: "..")
        try fixture.file("hard1", contents: "hardlink-data")
        try fixture.hardLink("hard2", to: "hard1")
        try fixture.sparseFile("sparse.bin", logicalSize: 1_048_576)
        return fixture
    }

    @Test("Reference and bulk agree on a mixed fixture")
    func mixedFixture() async throws {
        let fixture = try makeFixture()
        let path = fixture.url.path

        let referenceEngine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: ReferenceEnumerator(),
                workerCount: 1,
                batchNodeLimit: 1
            )
        )
        let bulkEngine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: DarwinBulkEnumerator(),
                workerCount: 1,
                batchNodeLimit: 1
            )
        )

        let reference = try await collectScan(engine: referenceEngine, request: request(for: path))
        let bulk = try await collectScan(engine: bulkEngine, request: request(for: path))

        #expect(reference.status == .completed)
        #expect(bulk.status == .completed)
        #expect(reference.terminalCount == 1)
        #expect(bulk.terminalCount == 1)

        let referenceRows = reference.canonicalRows()
        let bulkRows = bulk.canonicalRows()
        #expect(referenceRows.keys.sorted() == bulkRows.keys.sorted())
        for key in referenceRows.keys {
            #expect(referenceRows[key] == bulkRows[key], "row mismatch for \(key)")
        }

        #expect(reference.duplicateCounts() == bulk.duplicateCounts())
        #expect(reference.fileCount == bulk.fileCount)
        #expect(reference.directoryCount == bulk.directoryCount)
        #expect(reference.issueCount == bulk.issueCount)
        #expect(reference.rootAggregate()?.attributedBytes == bulk.rootAggregate()?.attributedBytes)
        #expect(reference.rootAggregate()?.isComplete == true)
        #expect(bulk.rootAggregate()?.isComplete == true)

        // Hard links are attributed exactly once.
        #expect(reference.duplicateCounts().values.reduce(0, +) == 1)
        // The sparse file is flagged.
        #expect(referenceRows.values.contains { $0.sparse })
        // Symlinks are never followed.
        #expect(referenceRows["nested/loop"]?.kind == .symbolicLink)
        #expect(referenceRows["nested/up"]?.kind == .symbolicLink)

        // Final directory aggregates must agree everywhere, not just at root.
        #expect(reference.canonicalAggregates() == bulk.canonicalAggregates())
        #expect(reference.rootAggregate()?.descendantFileCount == bulk.rootAggregate()?.descendantFileCount)
        #expect(reference.rootAggregate()?.descendantDirectoryCount == bulk.rootAggregate()?.descendantDirectoryCount)
        // Root descendants exclude the root itself.
        #expect(reference.rootAggregate()?.descendantDirectoryCount == reference.directoryCount - 1)
        #expect(reference.rootAggregate()?.descendantFileCount == reference.fileCount)
    }

    @Test("Multiple workers produce the same canonical result")
    func concurrentWorkersAgree() async throws {
        let fixture = try makeFixture()
        let path = fixture.url.path
        let singleEngine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: DarwinBulkEnumerator(),
                workerCount: 1,
                batchNodeLimit: 7
            )
        )
        let multiEngine = FileSystemScanEngine(
            configuration: ScanConfiguration(
                enumerator: DarwinBulkEnumerator(),
                workerCount: 4,
                batchNodeLimit: 7
            )
        )
        let single = try await collectScan(engine: singleEngine, request: request(for: path))
        let multi = try await collectScan(engine: multiEngine, request: request(for: path))
        #expect(single.status == .completed)
        #expect(multi.status == .completed)
        #expect(single.canonicalRows() == multi.canonicalRows())
        #expect(single.canonicalAggregates() == multi.canonicalAggregates())
        #expect(single.rootAggregate()?.attributedBytes == multi.rootAggregate()?.attributedBytes)
    }

    @Test("Empty directory completes with zero files")
    func emptyDirectory() async throws {
        let fixture = try TempFixture()
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(enumerator: ReferenceEnumerator(), workerCount: 1)
        )
        let collected = try await collectScan(engine: engine, request: request(for: fixture.url.path))
        #expect(collected.status == .completed)
        #expect(collected.fileCount == 0)
        #expect(collected.directoryCount == 1)
        #expect(collected.rootAggregate()?.isComplete == true)
        #expect(collected.rootAggregate()?.attributedBytes == 0)
        #expect(collected.terminalCount == 1)
    }

    @Test("treatAsLeaf stops at a package")
    func packageLeaf() async throws {
        let fixture = try TempFixture()
        try fixture.file("Sample.app/Contents/Info.plist", contents: "x")
        let engine = FileSystemScanEngine(
            configuration: ScanConfiguration(enumerator: ReferenceEnumerator(), workerCount: 1)
        )
        let collected = try await collectScan(
            engine: engine,
            request: request(for: fixture.url.path, packagePolicy: .treatAsLeaf)
        )
        #expect(collected.status == .completed)
        let rows = collected.canonicalRows()
        #expect(rows["Sample.app"] != nil)
        #expect(rows["Sample.app/Contents"] == nil)
        let packageNode = collected.nodes.values.first {
            collected.relativePath(of: $0.id) == "Sample.app"
        }
        #expect(packageNode?.flags.contains(.package) == true)
    }
}
