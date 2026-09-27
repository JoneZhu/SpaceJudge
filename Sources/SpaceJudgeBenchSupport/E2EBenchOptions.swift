import Foundation

/// Deterministic fixture topology.
public enum FixtureShape: String, Sendable, Equatable, CaseIterable {
    /// A hierarchy with wide directories, several levels, empty directories and
    /// ordinary small files.
    case mixed
    /// A single root directory holding all files directly.
    case wide
}

/// Parsed `spacejudge-e2e-bench` options.
public struct E2EBenchOptions: Sendable, Equatable {
    /// Total scan nodes requested, *including* the fixture root directory.
    public var requestedNodes: Int
    public var shape: FixtureShape
    /// Files per directory for `mixed`; also the repeat period of file names.
    public var filesPerDirectory: Int
    /// Request cancellation right after the first successful SQLite commit.
    public var cancelAfterFirstCommit: Bool
    /// When set, artifacts are kept in this new directory instead of a
    /// task-owned temporary root.
    public var keepArtifactsPath: String?

    public init(
        requestedNodes: Int,
        shape: FixtureShape = .mixed,
        filesPerDirectory: Int = 8,
        cancelAfterFirstCommit: Bool = false,
        keepArtifactsPath: String? = nil
    ) {
        self.requestedNodes = requestedNodes
        self.shape = shape
        self.filesPerDirectory = filesPerDirectory
        self.cancelAfterFirstCommit = cancelAfterFirstCommit
        self.keepArtifactsPath = keepArtifactsPath
    }
}

/// Parameter errors; the executable maps these to exit code 2.
public enum E2EBenchArgumentError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingValue(option: String)
    case invalidValue(option: String, value: String)
    case unknownOption(String)
    case missingRequired(option: String)

    public var description: String {
        switch self {
        case .missingValue(let option):
            return "\(option) requires a value"
        case .invalidValue(let option, let value):
            return "\(option) has invalid value '\(value)'"
        case .unknownOption(let option):
            return "unknown option '\(option)'"
        case .missingRequired(let option):
            return "\(option) is required"
        }
    }
}

public enum E2EBenchArguments {
    public static let usage = """
    usage: spacejudge-e2e-bench --nodes N [options]

    Runs the production end-to-end pipeline against a deterministic real-directory
    fixture: DarwinBulkEnumerator -> FileSystemScanEngine -> PersistingScanRunner
    -> SQLiteSnapshotRepository -> close -> openReadOnly -> verification.

    Options:
      --nodes N                       Total scan nodes, INCLUDING the fixture root
                                      directory (required, positive).
      --shape mixed|wide              Fixture topology (default mixed).
      --files-per-directory K         Files per directory for mixed (default 8).
      --cancel-after-first-commit     Request cancel after the first committed batch.
      --keep-artifacts DIR            Keep fixture and database in this new directory.
                                      DIR must not already exist. Prints the path to stderr.
      --help, -h                      Show this help.

    Fixture files are always 1 byte: this stage measures the metadata/persistence
    pipeline, not large-file I/O. Cache state is uncontrolled.

    Only one stable JSON object is written to stdout. All errors and progress go to
    stderr. Exit codes: 0 success, 2 arguments, 3 fixture, 4 scan/store, 5 verification.
    """

    /// Whether `--help`/`-h` appears anywhere in the arguments.
    public static func helpRequested(_ arguments: [String]) -> Bool {
        arguments.contains("--help") || arguments.contains("-h")
    }

    /// Parses arguments (excluding the executable name).
    public static func parse(_ arguments: [String]) throws -> E2EBenchOptions {
        var nodes: Int?
        var shape: FixtureShape = .mixed
        var filesPerDirectory = 8
        var cancelAfterFirstCommit = false
        var keepArtifactsPath: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--nodes":
                let value = try value(for: argument, at: &index, in: arguments)
                guard let parsed = Int(value), parsed > 0 else {
                    throw E2EBenchArgumentError.invalidValue(option: argument, value: value)
                }
                nodes = parsed
            case "--shape":
                let value = try value(for: argument, at: &index, in: arguments)
                guard let parsed = FixtureShape(rawValue: value) else {
                    throw E2EBenchArgumentError.invalidValue(option: argument, value: value)
                }
                shape = parsed
            case "--files-per-directory":
                let value = try value(for: argument, at: &index, in: arguments)
                guard let parsed = Int(value), parsed > 0 else {
                    throw E2EBenchArgumentError.invalidValue(option: argument, value: value)
                }
                filesPerDirectory = parsed
            case "--keep-artifacts":
                keepArtifactsPath = try value(for: argument, at: &index, in: arguments)
            case "--cancel-after-first-commit":
                cancelAfterFirstCommit = true
            default:
                throw E2EBenchArgumentError.unknownOption(argument)
            }
            index += 1
        }

        guard let nodes else {
            throw E2EBenchArgumentError.missingRequired(option: "--nodes")
        }
        return E2EBenchOptions(
            requestedNodes: nodes,
            shape: shape,
            filesPerDirectory: filesPerDirectory,
            cancelAfterFirstCommit: cancelAfterFirstCommit,
            keepArtifactsPath: keepArtifactsPath
        )
    }

    private static func value(
        for option: String,
        at index: inout Int,
        in arguments: [String]
    ) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw E2EBenchArgumentError.missingValue(option: option)
        }
        return arguments[index]
    }
}
