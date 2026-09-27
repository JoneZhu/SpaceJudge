import Foundation
import SpaceJudgeVolumePlanKit

// `spacejudge-volume-plan` diagnostic CLI entry point.
//
// All behavior lives in `VolumePlanCommand` so it can be unit-tested; this file
// only forwards arguments, writes the captured streams and exits with the
// documented code.

let result = VolumePlanCommand.execute(arguments: Array(CommandLine.arguments.dropFirst()))

if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}
if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}
exit(result.exitCode)
