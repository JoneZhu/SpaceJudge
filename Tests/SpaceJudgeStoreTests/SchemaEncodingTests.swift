import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeStore

@Suite("Schema v1 enum and flag encoding", .serialized)
struct SchemaEncodingTests {
    @Test("Boundary policy keeps 0 and 1 and appends 2")
    func boundaryPolicyEncoding() throws {
        #expect(SchemaEncoding.encode(BoundaryPolicy.selectedTree) == 0)
        #expect(SchemaEncoding.encode(BoundaryPolicy.stayOnRootFileSystem) == 1)
        #expect(SchemaEncoding.encode(BoundaryPolicy.visibleStartupVolumeGroup) == 2)

        #expect(try SchemaEncoding.decodeBoundaryPolicy(0) == .selectedTree)
        #expect(try SchemaEncoding.decodeBoundaryPolicy(1) == .stayOnRootFileSystem)
        #expect(try SchemaEncoding.decodeBoundaryPolicy(2) == .visibleStartupVolumeGroup)
    }

    @Test("Unknown boundary policy values still fail")
    func unknownBoundaryPolicyFails() {
        #expect(throws: SnapshotStoreError.unknownEnumValue(column: "boundary_policy", value: 3)) {
            _ = try SchemaEncoding.decodeBoundaryPolicy(3)
        }
        #expect(throws: (any Error).self) {
            _ = try SchemaEncoding.decodeBoundaryPolicy(-1)
        }
    }

    @Test("The firmlink projection flag survives a SQLite round-trip")
    func firmlinkFlagRoundTrip() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        try await repository.begin(sampleMetadata(scanID: scanID))
        let flags: NodeFlags = [.firmlinkProjection, .mountBoundary]
        try await repository.write(
            NodeBatch(
                scanID: scanID,
                revision: Revision(1),
                names: [sampleName(1, "root"), sampleName(2, "Applications")],
                nodes: [
                    sampleNode(
                        id: 1, parent: nil, name: 1, scanID: scanID,
                        kind: .directory, logical: nil, allocated: nil, attributed: 0
                    ),
                    sampleNode(
                        id: 2, parent: 1, name: 2, scanID: scanID,
                        kind: .directory, flags: flags,
                        logical: nil, allocated: nil, attributed: 0
                    )
                ]
            )
        )
        let children = try await repository.children(of: NodeID(1), in: scanID)
        let child = try #require(children.first { $0.id == NodeID(2) })
        #expect(child.flags.contains(.firmlinkProjection))
        #expect(child.flags.contains(.mountBoundary))
        await repository.close()
    }

    @Test("A visible volume-group boundary policy persists in the scan header")
    func visiblePolicyPersists() async throws {
        let database = try TempDatabase()
        let repository = try database.open()
        let scanID = sampleScanID()
        let metadata = ScanMetadata(
            scanID: scanID,
            request: ScanRequest(
                root: ScanRoot(fileSystemPath: "/private/tmp/do-not-persist", displayName: "disk"),
                boundaryPolicy: .visibleStartupVolumeGroup
            ),
            startedAt: Date(timeIntervalSince1970: 1_000),
            rootNodeID: NodeID(1)
        )
        try await repository.begin(metadata)
        let summary = try #require(try await repository.scanSummary(scanID))
        #expect(summary.boundaryPolicy == .visibleStartupVolumeGroup)
        await repository.close()
    }
}
