import Foundation

/// Dispatcher for the non-streaming agent CLI commands.
///
/// `scan` is intentionally excluded because it is long-lived and owns process
/// signal handling; the executable wires that path explicitly.
public enum AgentCLI {
    /// Executes `help`, `volume`, `status`, `children` and `issues`.
    public static func executeNonScan(arguments: [String]) async -> AgentCLIResult {
        switch AgentCLIParser.parse(arguments: arguments) {
        case .failure(let error):
            return AgentCLIResult.failure(error)
        case .success(let command):
            switch command {
            case .help:
                return AgentCLIResult(exitCode: 0, stdout: AgentCLIParser.usage + "\n")
            case .volume(let root):
                return AgentVolumeCommand.run(rootPath: root)
            case .status(let database, let scanID):
                return await AgentQueryCommands.status(databasePath: database, scanIDText: scanID)
            case .children(let database, let scanID, let nodeID, let limit):
                return await AgentQueryCommands.children(
                    databasePath: database,
                    scanIDText: scanID,
                    nodeIDText: nodeID,
                    limitText: limit
                )
            case .hotspots(let database, let scanID, let nodeID, let limit, let minBytes):
                return await AgentQueryCommands.hotspots(
                    databasePath: database,
                    scanIDText: scanID,
                    nodeIDText: nodeID,
                    limitText: limit,
                    minBytesText: minBytes
                )
            case .issues(let database, let scanID):
                return await AgentQueryCommands.issues(databasePath: database, scanIDText: scanID)
            case .scan:
                // Streamed separately by the executable.
                return AgentCLIResult.failure(AgentCLIError(code: .internalError))
            }
        }
    }
}
