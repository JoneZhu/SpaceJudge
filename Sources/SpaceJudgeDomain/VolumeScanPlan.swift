import Foundation

/// How a `ScanRequest` should traverse the selected root.
///
/// The plan is intentionally small: it records the decision and the public
/// evidence behind it, but no user path, volume UUID, BSD disk name or
/// mount-from location beyond the session-only `ScanRoot`.
public enum VolumeScanPlanKind: Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// The selected root is treated as an ordinary single file system.
    case selectedFileSystem
    /// The selected root is the unified visible startup volume group: firmlink
    /// projections are followed, real mount points are truncated.
    case visibleStartupVolumeGroup
}

/// Where the volume facts used by a plan came from. Kept explicit so a failed
/// or unavailable query is never mistaken for a confirmed negative fact.
public enum VolumePlanEvidenceSource: Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Public `URL.resourceValues` volume keys answered the query.
    case foundationResourceValues
    /// The query could not be performed or threw; every fact is unknown.
    case unavailable
}

/// Privacy-safe public volume facts behind a plan.
///
/// A `nil` value means "unknown", never a fabricated `false`. Only non-sensitive
/// volume properties are retained; the file system type is a generic name such
/// as `apfs`, not a device or mount location.
public struct VolumeScanPlanEvidence: Sendable, Equatable, Hashable, Codable {
    /// Whether the selection is a mounted volume root.
    public let isVolume: Bool?
    /// Whether the volume is the root file system of the running system.
    public let isRootFileSystem: Bool?
    /// Public file system type name (for example `apfs`), when known.
    public let fileSystemType: String?
    /// Provenance of the values above.
    public let source: VolumePlanEvidenceSource

    public init(
        isVolume: Bool?,
        isRootFileSystem: Bool?,
        fileSystemType: String?,
        source: VolumePlanEvidenceSource
    ) {
        self.isVolume = isVolume
        self.isRootFileSystem = isRootFileSystem
        self.fileSystemType = fileSystemType
        self.source = source
    }

    /// Evidence that no public fact could be established.
    public static let unknown = VolumeScanPlanEvidence(
        isVolume: nil,
        isRootFileSystem: nil,
        fileSystemType: nil,
        source: .unavailable
    )

    /// Case-insensitive APFS check. `nil` (unknown) is not APFS.
    public var isAPFS: Bool {
        fileSystemType?.caseInsensitiveCompare("apfs") == .orderedSame
    }
}

/// Immutable, `Sendable` description of how to scan one selected root.
///
/// The plan is a value type so it can be computed on the main actor, passed
/// across concurrency domains and asserted in tests without touching the file
/// system. It does not duplicate the scan tunables; `makeScanRequest` builds the
/// existing `ScanRequest`.
public struct VolumeScanPlan: Sendable, Equatable, Hashable, Codable {
    public let kind: VolumeScanPlanKind
    /// Session-only scan root. Never persisted or logged.
    public let root: ScanRoot
    /// Boundary policy that matches `kind`.
    public let boundaryPolicy: BoundaryPolicy
    /// Public volume facts behind `kind`.
    public let evidence: VolumeScanPlanEvidence

    public init(
        kind: VolumeScanPlanKind,
        root: ScanRoot,
        boundaryPolicy: BoundaryPolicy,
        evidence: VolumeScanPlanEvidence
    ) {
        self.kind = kind
        self.root = root
        self.boundaryPolicy = boundaryPolicy
        self.evidence = evidence
    }

    /// Builds the existing `ScanRequest` for this plan. Policy tunables other
    /// than the boundary policy keep their domain defaults unless supplied.
    public func makeScanRequest(
        sizeMetric: SizeMetric = .allocated,
        packagePolicy: PackagePolicy = .descend,
        symlinkPolicy: SymlinkPolicy = .doNotFollow,
        workspaceExclusions: [SnapshotWorkspaceExclusion] = []
    ) -> ScanRequest {
        ScanRequest(
            root: root,
            sizeMetric: sizeMetric,
            boundaryPolicy: boundaryPolicy,
            packagePolicy: packagePolicy,
            symlinkPolicy: symlinkPolicy,
            workspaceExclusions: workspaceExclusions
        )
    }
}
