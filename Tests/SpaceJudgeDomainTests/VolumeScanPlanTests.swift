import Foundation
import Testing
import SpaceJudgeDomain

@Suite("Volume scan plan")
struct VolumeScanPlanTests {
    // MARK: BoundaryPolicy

    @Test("Boundary policy keeps its frozen order and round-trips through Codable")
    func boundaryPolicyRoundTrip() throws {
        #expect(BoundaryPolicy.allCases == [
            .selectedTree,
            .stayOnRootFileSystem,
            .visibleStartupVolumeGroup
        ])
        for policy in BoundaryPolicy.allCases {
            let data = try JSONEncoder().encode(policy)
            let decoded = try JSONDecoder().decode(BoundaryPolicy.self, from: data)
            #expect(decoded == policy)
        }
    }

    // MARK: NodeFlags

    @Test("The firmlink projection flag is a new, non-colliding bit")
    func firmlinkProjectionFlag() {
        let allExisting: [NodeFlags] = [
            .package, .duplicateHardLink, .inaccessible, .mountBoundary,
            .sparse, .changedDuringScan, .symlinkLoop, .clonedAllocation,
            .fallbackEnumerator
        ]
        #expect(NodeFlags.firmlinkProjection.rawValue == (1 << 9))
        for flag in allExisting {
            #expect(NodeFlags.firmlinkProjection.rawValue != flag.rawValue)
        }
        let combined: NodeFlags = [.firmlinkProjection, .mountBoundary]
        #expect(combined.contains(.firmlinkProjection))
        #expect(combined.contains(.mountBoundary))
        #expect(!NodeFlags.firmlinkProjection.contains(.mountBoundary))
    }

    // MARK: Evidence

    @Test("Evidence distinguishes unknown from a confirmed false")
    func evidenceUnknownVersusFalse() {
        let unknown = VolumeScanPlanEvidence.unknown
        #expect(unknown.isVolume == nil)
        #expect(unknown.isRootFileSystem == nil)
        #expect(unknown.fileSystemType == nil)
        #expect(unknown.source == .unavailable)
        #expect(!unknown.isAPFS)

        let confirmedFalse = VolumeScanPlanEvidence(
            isVolume: false,
            isRootFileSystem: false,
            fileSystemType: "hfs",
            source: .foundationResourceValues
        )
        #expect(confirmedFalse.isVolume == false)
        #expect(confirmedFalse.isRootFileSystem == false)
        #expect(!confirmedFalse.isAPFS)
        #expect(confirmedFalse != unknown)

        let confirmedTrue = VolumeScanPlanEvidence(
            isVolume: true,
            isRootFileSystem: true,
            fileSystemType: "APFS",
            source: .foundationResourceValues
        )
        #expect(confirmedTrue.isAPFS)
    }

    @Test("Evidence round-trips through Codable without inventing a false value")
    func evidenceCodable() throws {
        let evidence = VolumeScanPlanEvidence.unknown
        let data = try JSONEncoder().encode(evidence)
        let decoded = try JSONDecoder().decode(VolumeScanPlanEvidence.self, from: data)
        #expect(decoded == evidence)
        #expect(decoded.isVolume == nil)
        #expect(decoded.source == .unavailable)

        // An unknown fact is never serialized as a confirmed false.
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"isVolume\":false"))
        #expect(!json.contains("\"isRootFileSystem\":false"))
    }

    // MARK: Plan

    @Test("A visible startup plan maps to the visible boundary policy")
    func visiblePlanRequest() {
        let root = ScanRoot(fileSystemPath: "/", displayName: "Macintosh HD")
        let plan = VolumeScanPlan(
            kind: .visibleStartupVolumeGroup,
            root: root,
            boundaryPolicy: .visibleStartupVolumeGroup,
            evidence: VolumeScanPlanEvidence(
                isVolume: true,
                isRootFileSystem: true,
                fileSystemType: "apfs",
                source: .foundationResourceValues
            )
        )
        let request = plan.makeScanRequest()
        #expect(request.root == root)
        #expect(request.boundaryPolicy == .visibleStartupVolumeGroup)
        #expect(request.sizeMetric == .allocated)
        #expect(request.packagePolicy == .descend)
        #expect(request.symlinkPolicy == .doNotFollow)
    }

    @Test("A fallback plan maps to the Phase 5A boundary policy")
    func fallbackPlanRequest() {
        let root = ScanRoot(fileSystemPath: "/tmp/example", displayName: "example")
        let plan = VolumeScanPlan(
            kind: .selectedFileSystem,
            root: root,
            boundaryPolicy: .stayOnRootFileSystem,
            evidence: .unknown
        )
        let request = plan.makeScanRequest()
        #expect(request.boundaryPolicy == .stayOnRootFileSystem)
    }

    @Test("A plan round-trips through Codable")
    func planCodable() throws {
        let plan = VolumeScanPlan(
            kind: .visibleStartupVolumeGroup,
            root: ScanRoot(fileSystemPath: "/", displayName: "disk"),
            boundaryPolicy: .visibleStartupVolumeGroup,
            evidence: VolumeScanPlanEvidence(
                isVolume: true,
                isRootFileSystem: true,
                fileSystemType: "apfs",
                source: .foundationResourceValues
            )
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(VolumeScanPlan.self, from: data)
        #expect(decoded == plan)
        #expect(decoded.kind == .visibleStartupVolumeGroup)
    }
}
