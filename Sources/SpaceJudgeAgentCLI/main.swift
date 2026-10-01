import Darwin
import Foundation
import SpaceJudgeAgentCLIKit

/// Serialized stdout writer. The protocol channel is one JSON object per line;
/// a single lock keeps concurrent producers from interleaving bytes.
final class AgentLineEmitter: @unchecked Sendable {
    private let lock = NSLock()

    func emit(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }
}

@main
struct SpaceJudgeAgentCLIExecutable {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let emitter = AgentLineEmitter()

        switch AgentCLIParser.parse(arguments: arguments) {
        case .failure(let error):
            emitter.emit(error.jsonLine())
            Darwin.exit(error.code.exitCode)

        case .success(.scan(let root, let database, let workspace)):
            let outcome = await runScan(
                root: root,
                database: database,
                workspace: workspace,
                emitter: emitter
            )
            Darwin.exit(outcome.exitCode)

        case .success:
            let result = await AgentCLI.executeNonScan(arguments: arguments)
            write(result, to: emitter)
            Darwin.exit(result.exitCode)
        }
    }

    private static func write(_ result: AgentCLIResult, to emitter: AgentLineEmitter) {
        if !result.stdout.isEmpty {
            // stdout already contains trailing newlines from the command.
            guard let data = result.stdout.data(using: .utf8) else { return }
            FileHandle.standardOutput.write(data)
        }
        if !result.stderr.isEmpty {
            guard let data = result.stderr.data(using: .utf8) else { return }
            FileHandle.standardError.write(data)
        }
    }

    /// Installs SIGINT/SIGTERM handling, runs the scan and forwards cancel
    /// signals into the cooperative path.
    private static func runScan(
        root: String,
        database: String,
        workspace: String,
        emitter: AgentLineEmitter
    ) async -> AgentScanOutcome {
        let (signals, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM] {
            // Ignore the default disposition; the dispatch source below is the
            // only consumer so the process cannot die without persisting.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { continuation.yield(()) }
            source.resume()
            sources.append(source)
        }
        defer {
            for source in sources { source.cancel() }
            continuation.finish()
        }

        return await AgentScanCommand.run(
            rootPath: root,
            databasePath: database,
            workspacePath: workspace,
            emit: { emitter.emit($0) },
            cancelSignals: signals
        )
    }
}
