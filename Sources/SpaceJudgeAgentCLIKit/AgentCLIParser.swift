import Foundation

/// Captured outcome of one non-streaming CLI invocation, kept separate from
/// the process so every command can be unit tested in-process.
public struct AgentCLIResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Exactly one NDJSON line followed by a newline, or empty output.
    public static func output(_ line: String) -> AgentCLIResult {
        AgentCLIResult(exitCode: 0, stdout: line + "\n")
    }

    /// A path-free process error on stdout with the matching exit code.
    public static func failure(_ error: AgentCLIError) -> AgentCLIResult {
        AgentCLIResult(exitCode: error.code.exitCode, stdout: error.jsonLine() + "\n")
    }
}

/// Parsed command line. Values are kept as raw strings and validated by the
/// command that understands them; no argument value is ever echoed back.
public enum AgentCLICommand: Sendable, Equatable {
    case help
    case volume(root: String)
    case scan(root: String, database: String, workspace: String)
    case status(database: String, scanID: String)
    case children(database: String, scanID: String, nodeID: String, limit: String)
    case hotspots(
        database: String,
        scanID: String,
        nodeID: String,
        limit: String,
        minBytes: String
    )
    case issues(database: String, scanID: String)
}

/// Strict argument parser for `spacejudge-agent-cli`.
public enum AgentCLIParser {
    public static let usage = """
    usage: spacejudge-agent-cli <command> [options]

    Commands:
      volume  --root ABSOLUTE_PATH
              Print the volume capacity facts for one authorized root as JSON.
      scan    --root ABSOLUTE_PATH --database NEW_ABSOLUTE_DB --workspace OWNED_ABSOLUTE_DIR
              Stream NDJSON scan events. The database must be a new file inside
              the task-private workspace directory.
      status  --database ABSOLUTE_DB --scan-id UUID
      children --database ABSOLUTE_DB --scan-id UUID --node-id U64 [--limit N]
      hotspots --database ABSOLUTE_DB --scan-id UUID --node-id U64 [--limit N] [--min-bytes U64]
              Best-first descendant hotspots under one node, ordered by
              effective attributed bytes. Ancestor-inclusive; do not sum.
      issues  --database ABSOLUTE_DB --scan-id UUID

    Options accept both `--flag value` and `--flag=value`.

    Privacy:
      * stdout is one JSON object per line; stderr never carries paths.
      * The input paths, user name and file names are never echoed.

    Exit codes: 0 success, 1 internal, 2 arguments, 3 not found, 4 conflict,
    5 access denied, 6 insufficient space.
    """

    /// Parses arguments. The first argument is the command.
    public static func parse(arguments: [String]) -> Result<AgentCLICommand, AgentCLIError> {
        guard let first = arguments.first else {
            return .failure(AgentCLIError(code: .invalidArgument))
        }
        if first == "--help" || first == "-h" || first == "help" {
            return .success(.help)
        }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "volume":
            return parseSingle(rest, required: ["root"]).map { values in
                .volume(root: values["root"] ?? "")
            }
        case "scan":
            return parseSingle(rest, required: ["root", "database", "workspace"]).map { values in
                .scan(
                    root: values["root"] ?? "",
                    database: values["database"] ?? "",
                    workspace: values["workspace"] ?? ""
                )
            }
        case "status":
            return parseSingle(rest, required: ["database", "scan-id"]).map { values in
                .status(database: values["database"] ?? "", scanID: values["scan-id"] ?? "")
            }
        case "children":
            return parseSingle(
                rest,
                required: ["database", "scan-id", "node-id"],
                optional: ["limit"]
            ).map { values in
                .children(
                    database: values["database"] ?? "",
                    scanID: values["scan-id"] ?? "",
                    nodeID: values["node-id"] ?? "",
                    limit: values["limit"] ?? ""
                )
            }
        case "hotspots":
            return parseSingle(
                rest,
                required: ["database", "scan-id", "node-id"],
                optional: ["limit", "min-bytes"]
            ).map { values in
                .hotspots(
                    database: values["database"] ?? "",
                    scanID: values["scan-id"] ?? "",
                    nodeID: values["node-id"] ?? "",
                    limit: values["limit"] ?? "",
                    minBytes: values["min-bytes"] ?? ""
                )
            }
        case "issues":
            return parseSingle(rest, required: ["database", "scan-id"]).map { values in
                .issues(database: values["database"] ?? "", scanID: values["scan-id"] ?? "")
            }
        default:
            return .failure(AgentCLIError(code: .invalidArgument))
        }
    }

    private static func parseSingle(
        _ arguments: [String],
        required: [String],
        optional: [String] = []
    ) -> Result<[String: String], AgentCLIError> {
        var values: [String: String] = [:]
        let allowed = Set(required + optional)
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--"), argument.count > 2 else {
                return .failure(AgentCLIError(code: .invalidArgument))
            }
            let body = String(argument.dropFirst(2))
            let name: String
            let value: String
            if let equals = body.firstIndex(of: "=") {
                name = String(body[body.startIndex..<equals])
                value = String(body[body.index(after: equals)...])
            } else {
                name = body
                index += 1
                guard index < arguments.count else {
                    return .failure(AgentCLIError(code: .invalidArgument))
                }
                value = arguments[index]
            }
            guard allowed.contains(name), values[name] == nil else {
                return .failure(AgentCLIError(code: .invalidArgument))
            }
            values[name] = value
            index += 1
        }
        for name in required where values[name] == nil {
            return .failure(AgentCLIError(code: .invalidArgument))
        }
        return .success(values)
    }
}
