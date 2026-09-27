import Foundation
import SpaceJudgeDomain

/// Public, privacy-safe volume facts used to resolve a plan.
///
/// This is deliberately separate from capacity metering: it carries only the
/// non-sensitive volume identity facts. `queryFailed` marks a query that could
/// not run at all, which must never be mistaken for a confirmed negative.
public struct VolumePlanFacts: Sendable, Equatable {
    public let isVolume: Bool?
    public let isRootFileSystem: Bool?
    public let fileSystemType: String?
    public let isLocal: Bool?
    public let queryFailed: Bool

    public init(
        isVolume: Bool?,
        isRootFileSystem: Bool?,
        fileSystemType: String?,
        isLocal: Bool? = nil,
        queryFailed: Bool = false
    ) {
        self.isVolume = isVolume
        self.isRootFileSystem = isRootFileSystem
        self.fileSystemType = fileSystemType
        self.isLocal = isLocal
        self.queryFailed = queryFailed
    }
}

/// Supplies `VolumePlanFacts` for a selection URL. Injectable so tests never
/// depend on the real machine's volume topology.
public protocol VolumePlanFactsProviding: Sendable {
    func facts(for url: URL) -> VolumePlanFacts
}

/// Production facts provider backed only by public Foundation volume keys.
public struct FoundationVolumePlanFactsProvider: VolumePlanFactsProviding {
    private static let keys: Set<URLResourceKey> = [
        .isVolumeKey,
        .volumeIsRootFileSystemKey,
        .volumeTypeNameKey,
        .volumeIsLocalKey
    ]

    public init() {}

    public func facts(for url: URL) -> VolumePlanFacts {
        do {
            let values = try url.resourceValues(forKeys: Self.keys)
            return VolumePlanFacts(
                isVolume: values.isVolume,
                isRootFileSystem: values.volumeIsRootFileSystem,
                fileSystemType: values.volumeTypeName,
                isLocal: values.volumeIsLocal,
                queryFailed: false
            )
        } catch {
            return VolumePlanFacts(
                isVolume: nil,
                isRootFileSystem: nil,
                fileSystemType: nil,
                isLocal: nil,
                queryFailed: true
            )
        }
    }
}

/// Pure plan resolution. Kept free of file-system access so every fact
/// combination is a unit test.
public enum VolumeScanPlanResolver {
    /// Chooses `visibleStartupVolumeGroup` only for the unambiguous public
    /// combination: volume root + root file system + APFS. Any unknown fact,
    /// failed query, non-APFS type, external volume or ordinary directory
    /// degrades to the conservative single-file-system plan.
    public static func resolve(
        root: ScanRoot,
        facts: VolumePlanFacts
    ) -> VolumeScanPlan {
        let evidence = VolumeScanPlanEvidence(
            isVolume: facts.isVolume,
            isRootFileSystem: facts.isRootFileSystem,
            fileSystemType: facts.fileSystemType,
            source: facts.queryFailed ? .unavailable : .foundationResourceValues
        )
        let qualifies = !facts.queryFailed
            && facts.isVolume == true
            && facts.isRootFileSystem == true
            && evidence.isAPFS
        return VolumeScanPlan(
            kind: qualifies ? .visibleStartupVolumeGroup : .selectedFileSystem,
            root: root,
            boundaryPolicy: qualifies ? .visibleStartupVolumeGroup : .stayOnRootFileSystem,
            evidence: evidence
        )
    }
}

/// Resolves how a user selection should be scanned.
///
/// The protocol is injectable so `AppModel` tests can drive every
/// `VolumeScanPlan` shape without depending on the real machine's volume
/// topology. Implementations must be synchronous and must never persist the
/// selection path.
public protocol VolumeScanPlanning: Sendable {
    /// Builds an immutable plan for one selection. This must not throw: a
    /// failed or unavailable volume query degrades to the conservative
    /// `selectedFileSystem` plan.
    func plan(for selection: DirectorySelection) -> VolumeScanPlan
}

/// Production planner backed only by public Foundation volume resource keys.
///
/// It refuses to guess: it never inspects the path, display name, capacity, a
/// fixed device number, `/usr/share/firmlinks` or `diskutil` output.
public struct FoundationVolumeScanPlanner: VolumeScanPlanning {
    private let factsProvider: any VolumePlanFactsProviding

    public init(
        factsProvider: any VolumePlanFactsProviding = FoundationVolumePlanFactsProvider()
    ) {
        self.factsProvider = factsProvider
    }

    public func plan(for selection: DirectorySelection) -> VolumeScanPlan {
        let facts = factsProvider.facts(for: selection.url)
        return VolumeScanPlanResolver.resolve(
            root: ScanRoot(
                fileSystemPath: selection.fileSystemPath,
                displayName: selection.displayName
            ),
            facts: facts
        )
    }
}
