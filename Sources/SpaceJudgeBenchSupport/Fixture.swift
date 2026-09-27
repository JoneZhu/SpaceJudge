import Darwin
import Foundation

/// Deterministic, bounded-memory fixture generator.
///
/// The generator never keeps a full list of node paths in memory: `mixed`
/// walks a stack of at most `branching * maxDepth` directory frames and `wide`
/// emits files in a single streaming loop. It creates exactly
/// `options.requestedNodes` filesystem nodes including the fixture root.

/// Exact facts about a generated fixture. Counts are accumulated while the
/// fixture is created, not stored as paths.
public struct FixtureManifest: Sendable, Equatable {
    public let requestedNodes: Int
    public let actualNodes: Int
    public let directoryCount: Int
    public let fileCount: Int
    public let logicalBytes: UInt64
    public let shape: FixtureShape

    public init(
        requestedNodes: Int,
        actualNodes: Int,
        directoryCount: Int,
        fileCount: Int,
        logicalBytes: UInt64,
        shape: FixtureShape
    ) {
        self.requestedNodes = requestedNodes
        self.actualNodes = actualNodes
        self.directoryCount = directoryCount
        self.fileCount = fileCount
        self.logicalBytes = logicalBytes
        self.shape = shape
    }
}

public enum FixtureError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidNodeCount(Int)
    case invalidFilesPerDirectory(Int)
    case arithmeticOverflow
    case destinationExists(String)
    case createDirectoryFailed(String)
    case createEntryFailed(name: String, errno: Int32)
    case writeFailed(name: String, errno: Int32)
    case temporaryDirectoryFailed
    case markerFailed

    public var description: String {
        switch self {
        case .invalidNodeCount(let value):
            return "--nodes must be >= 1 (got \(value))"
        case .invalidFilesPerDirectory(let value):
            return "--files-per-directory must be >= 1 (got \(value))"
        case .arithmeticOverflow:
            return "fixture byte count overflowed UInt64"
        case .destinationExists(let path):
            return "--keep-artifacts destination already exists: \(path)"
        case .createDirectoryFailed(let name):
            return "could not create directory '\(name)'"
        case .createEntryFailed(let name, let code):
            return "could not create '\(name)': \(String(cString: strerror(code)))"
        case .writeFailed(let name, let code):
            return "could not write '\(name)': \(String(cString: strerror(code)))"
        case .temporaryDirectoryFailed:
            return "could not create a task-owned temporary directory"
        case .markerFailed:
            return "could not write or validate the artifact marker"
        }
    }
}

/// Deterministic PRNG so the same parameters produce the same topology.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public struct FixtureGenerator: Sendable {
    private static let seed: UInt64 = 0x5EED_1234_ABCD_0001
    private static let branching = 4
    private static let maximumDepth = 32
    /// Fixed, minimal payload: this stage measures metadata and persistence,
    /// not large-file I/O. Keeping it constant removes any caller-controlled
    /// allocation or multiplication overflow.
    public static let fileBytes = 1

    public init() {}

    /// Creates the fixture rooted at `root` (which must not exist yet) and
    /// returns its manifest.
    public func generate(options: E2EBenchOptions, at root: String) throws -> FixtureManifest {
        guard options.requestedNodes >= 1 else {
            throw FixtureError.invalidNodeCount(options.requestedNodes)
        }
        guard options.filesPerDirectory >= 1 else {
            throw FixtureError.invalidFilesPerDirectory(options.filesPerDirectory)
        }
        if FileManager.default.fileExists(atPath: root) {
            throw FixtureError.destinationExists(root)
        }
        guard mkdir(root, 0o755) == 0 else {
            throw FixtureError.createEntryFailed(name: "fixture", errno: errno)
        }

        switch options.shape {
        case .wide:
            return try generateWide(options: options, root: root)
        case .mixed:
            return try generateMixed(options: options, root: root)
        }
    }

    // MARK: Wide

    private func generateWide(options: E2EBenchOptions, root: String) throws -> FixtureManifest {
        let fileCount = options.requestedNodes - 1
        let buffer = Self.fileBuffer
        for index in 0..<fileCount {
            try createFile(
                at: root + "/file\(index)",
                name: "file\(index)",
                bytes: Self.fileBytes,
                buffer: buffer
            )
        }
        return FixtureManifest(
            requestedNodes: options.requestedNodes,
            actualNodes: options.requestedNodes,
            directoryCount: 1,
            fileCount: fileCount,
            logicalBytes: try logicalBytes(fileCount: fileCount),
            shape: .wide
        )
    }

    // MARK: Mixed

    private struct Frame {
        let path: String
        let depth: Int
    }

    private func generateMixed(options: E2EBenchOptions, root: String) throws -> FixtureManifest {
        let requested = options.requestedNodes
        let filesPerDirectory = options.filesPerDirectory
        let fileBytes = Self.fileBytes
        let buffer = Self.fileBuffer

        var rng = SplitMix64(seed: Self.seed)
        var directoryCount = 1
        var fileCount = 0
        var remaining = requested - 1
        var nameCounter = 0
        var stack: [Frame] = [Frame(path: root, depth: 0)]

        while remaining > 0, let frame = stack.popLast() {
            let draw = rng.next()

            // File quota: the root becomes deliberately wide; deeper
            // directories are ordinary small ones, sometimes empty.
            let quota: Int
            if frame.depth == 0 {
                quota = min(remaining, max(16, remaining / 8))
            } else {
                quota = Int(draw % UInt64(filesPerDirectory + 1))
            }
            let files = min(quota, remaining)
            if files > 0 {
                let unique = frame.depth == 0
                for index in 0..<files {
                    let name = unique ? "rf\(index)" : "file\(index)"
                    try createFile(
                        at: frame.path + "/" + name,
                        name: name,
                        bytes: fileBytes,
                        buffer: buffer
                    )
                }
                fileCount += files
                remaining -= files
            }

            guard remaining > 0, frame.depth < Self.maximumDepth else { continue }

            // Subdirectory quota: never let the root leave the tree when there
            // is budget to keep it multi-level.
            let childQuota: Int
            if frame.depth < 2 {
                childQuota = 2 + Int(rng.next() % UInt64(Self.branching))
            } else {
                childQuota = Int(rng.next() % UInt64(Self.branching + 1))
            }
            let children = min(childQuota, remaining)
            for _ in 0..<children {
                nameCounter += 1
                let name = "dir\(nameCounter)"
                let path = frame.path + "/" + name
                guard mkdir(path, 0o755) == 0 else {
                    throw FixtureError.createEntryFailed(name: name, errno: errno)
                }
                directoryCount += 1
                remaining -= 1
                stack.append(Frame(path: path, depth: frame.depth + 1))
            }
        }

        // Defensive: if the stack drained before the budget, finish with direct
        // root files rather than losing nodes.
        if remaining > 0 {
            let base = fileCount
            for offset in 0..<remaining {
                let name = "rf\(base + offset)"
                try createFile(
                    at: root + "/" + name,
                    name: name,
                    bytes: fileBytes,
                    buffer: buffer
                )
            }
            fileCount += remaining
            remaining = 0
        }

        return FixtureManifest(
            requestedNodes: requested,
            actualNodes: directoryCount + fileCount,
            directoryCount: directoryCount,
            fileCount: fileCount,
            logicalBytes: try logicalBytes(fileCount: fileCount),
            shape: .mixed
        )
    }

    /// Checked multiplication of the manifest byte total.
    private func logicalBytes(fileCount: Int) throws -> UInt64 {
        let (value, overflow) = UInt64(fileCount).multipliedReportingOverflow(
            by: UInt64(Self.fileBytes)
        )
        guard !overflow else { throw FixtureError.arithmeticOverflow }
        return value
    }

    private static let fileBuffer = [UInt8](repeating: 0x61, count: 1)

    // MARK: Primitives

    private func createFile(
        at path: String,
        name: String,
        bytes: Int,
        buffer: [UInt8]
    ) throws {
        let descriptor = path.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
        guard descriptor >= 0 else {
            throw FixtureError.createEntryFailed(name: name, errno: errno)
        }
        defer { close(descriptor) }
        guard bytes > 0 else { return }
        try buffer.withUnsafeBytes { raw in
            var written = 0
            while written < bytes {
                let result = write(descriptor, raw.baseAddress!.advanced(by: written), bytes - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw FixtureError.writeFailed(name: name, errno: errno)
                }
                written += result
            }
        }
    }
}

// MARK: - Artifact root

/// A task-owned directory holding the fixture and the database as siblings.
///
/// Temporary roots are created with `mkdtemp`, carry a random marker file and
/// are only removed when the marker still matches and the path is under the
/// recorded temporary base. Kept artifacts are never removed.
public struct ArtifactRoot: Sendable, Equatable {
    public static let markerFileName = ".spacejudge-e2e-marker"

    public let rootPath: String
    public let fixturePath: String
    public let databasePath: String
    public let isTemporary: Bool
    public let marker: String
    private let temporaryBase: String?

    private init(
        rootPath: String,
        isTemporary: Bool,
        marker: String,
        temporaryBase: String?
    ) {
        self.rootPath = rootPath
        self.fixturePath = rootPath + "/fixture"
        self.databasePath = rootPath + "/spacejudge.sqlite"
        self.isTemporary = isTemporary
        self.marker = marker
        self.temporaryBase = temporaryBase
    }

    public var markerPath: String { rootPath + "/" + Self.markerFileName }

    /// Prepares a fresh artifact root.
    ///
    /// - `keepArtifactsAt == nil`: creates a `mkdtemp` root under `/tmp`.
    /// - otherwise: creates exactly that new directory and refuses to overwrite.
    public static func prepare(
        keepArtifactsAt: String?,
        temporaryBase: String = NSTemporaryDirectory()
    ) throws -> ArtifactRoot {
        let marker = UUID().uuidString
        if let keepArtifactsAt, !keepArtifactsAt.isEmpty {
            let path = URL(fileURLWithPath: keepArtifactsAt).standardized.path
            guard !FileManager.default.fileExists(atPath: path) else {
                throw FixtureError.destinationExists(path)
            }
            do {
                try FileManager.default.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: false
                )
            } catch {
                throw FixtureError.createDirectoryFailed(keepArtifactsAt)
            }
            let root = ArtifactRoot(
                rootPath: path,
                isTemporary: false,
                marker: marker,
                temporaryBase: nil
            )
            try writeMarker(root)
            return root
        }

        var base = temporaryBase
        if !base.hasSuffix("/") { base += "/" }
        var template = Array((base + "spacejudge-e2e-XXXXXX").utf8CString)
        let created: UnsafeMutablePointer<CChar>? = template.withUnsafeMutableBufferPointer {
            mkdtemp($0.baseAddress)
        }
        guard let created else {
            throw FixtureError.temporaryDirectoryFailed
        }
        let rootPath = String(cString: created)
        let root = ArtifactRoot(
            rootPath: rootPath,
            isTemporary: true,
            marker: marker,
            temporaryBase: base
        )
        try writeMarker(root)
        return root
    }

    private static func writeMarker(_ root: ArtifactRoot) throws {
        let contents = root.marker + "\n"
        guard FileManager.default.createFile(
            atPath: root.markerPath,
            contents: Data(contents.utf8)
        ) else {
            throw FixtureError.markerFailed
        }
    }

    /// Removes a temporary root only when it is provably tool-owned.
    ///
    /// - Returns: `true` when the directory was removed.
    @discardableResult
    public func cleanup() -> Bool {
        guard isTemporary, let temporaryBase, rootPath.hasPrefix(temporaryBase) else {
            return false
        }
        guard let data = FileManager.default.contents(atPath: markerPath),
              let text = String(data: data, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines) == marker else {
            return false
        }
        do {
            try FileManager.default.removeItem(atPath: rootPath)
        } catch {
            return false
        }
        return !FileManager.default.fileExists(atPath: rootPath)
    }
}
