import Darwin
import Foundation
import SpaceJudgeDomain
@testable import SpaceJudgeStore

/// Temporary SQLite database path with deterministic cleanup of `-wal`/`-shm`.
final class TempDatabase {
    let path: String
    let directory: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacejudge-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.path = directory.appendingPathComponent("store.sqlite").path
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var walPath: String { path + "-wal" }
    var shmPath: String { path + "-shm" }

    func open() throws -> SQLiteSnapshotRepository {
        try SQLiteSnapshotRepository(path: path)
    }

    /// Opens with an injected capacity provider and gate policy so low-space
    /// behavior is scripted without touching a real disk.
    func open(
        capacityProvider: any StorageCapacityProviding,
        spacePolicy: StorageSpacePolicy = .standard
    ) throws -> SQLiteSnapshotRepository {
        try SQLiteSnapshotRepository(
            path: path,
            capacityProvider: capacityProvider,
            spacePolicy: spacePolicy
        )
    }
}

func sampleScanID(_ value: Int = 1) -> ScanID {
    ScanID(
        rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    )
}

func sampleMetadata(
    scanID: ScanID,
    rootNodeID: NodeID = NodeID(1),
    displayName: String = "root",
    volume: VolumeFacts? = nil
) -> ScanMetadata {
    ScanMetadata(
        scanID: scanID,
        request: ScanRequest(
            root: ScanRoot(fileSystemPath: "/private/tmp/do-not-persist", displayName: displayName),
            sizeMetric: .allocated,
            boundaryPolicy: .stayOnRootFileSystem,
            packagePolicy: .descend,
            symlinkPolicy: .doNotFollow
        ),
        startedAt: Date(timeIntervalSince1970: 1_000),
        rootNodeID: rootNodeID,
        volume: volume
    )
}

func sampleNode(
    id: UInt64,
    parent: UInt64?,
    name: UInt64,
    scanID: ScanID,
    kind: NodeKind = .regularFile,
    flags: NodeFlags = [],
    logical: UInt64? = 4096,
    allocated: UInt64? = 4096,
    attributed: UInt64 = 4096
) -> NodeRecord {
    NodeRecord(
        id: NodeID(id),
        scanID: scanID,
        parentID: parent.map(NodeID.init),
        name: NameID(name),
        kind: kind,
        flags: flags,
        logicalBytes: logical,
        allocatedBytes: allocated,
        attributedBytes: attributed,
        modifiedAt: Date(timeIntervalSince1970: 2_000),
        deviceID: 7,
        fileID: id
    )
}

func sampleName(_ id: UInt64, _ string: String) -> NameRecord {
    NameRecord(id: NameID(id), bytes: Array(string.utf8))
}

func countOpenFileDescriptors() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}
