import Foundation
import SpaceJudgeBenchSupport

// `spacejudge-e2e-bench` CLI.
//
// One stable JSON object goes to stdout; all progress and errors go to stderr.
// Exit codes: 0 success, 2 arguments, 3 fixture, 4 scan/store, 5 verification.

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())

if E2EBenchArguments.helpRequested(arguments) {
    print(E2EBenchArguments.usage)
    exit(0)
}

let options: E2EBenchOptions
do {
    options = try E2EBenchArguments.parse(arguments)
} catch let error as E2EBenchArgumentError {
    writeError(error.description)
    writeError("run with --help for usage")
    exit(2)
} catch {
    writeError("\(error)")
    exit(2)
}

do {
    let result = try await E2EBenchRunner().run(options, log: log)
    print(result.jsonString())
    exit(0)
} catch let error as E2EBenchError {
    writeError(error.description)
    exit(error.exitCode)
} catch {
    writeError("\(error)")
    exit(1)
}
