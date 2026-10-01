import Foundation
import SpaceJudgeDomain

/// `spacejudge-agent-cli volume --root ABSOLUTE_PATH`.
///
/// Resolves capacity facts through the same public Foundation provider the app
/// uses. The input path is never echoed in the output.
public enum AgentVolumeCommand {
    public static func run(rootPath: String) -> AgentCLIResult {
        do {
            _ = try AgentCLIPath.requireDirectory(rootPath)
            let facts = FoundationVolumeFactsProvider().facts(forFileSystemPath: rootPath)
            let line = AgentJSON.line([
                "type": "volume",
                "ok": true,
                "capacityBytes": AgentJSON.uint64OrNull(facts.totalCapacityBytes),
                "capacityGB": AgentJSON.gigabytesOrNull(facts.totalCapacityBytes),
                "availableBytes": AgentJSON.uint64OrNull(facts.availableCapacityBytes),
                "availableGB": AgentJSON.gigabytesOrNull(facts.availableCapacityBytes),
                "usedBytes": AgentJSON.uint64OrNull(facts.usedBytes),
                "usedGB": AgentJSON.gigabytesOrNull(facts.usedBytes)
            ])
            return AgentCLIResult.output(line)
        } catch {
            return AgentCLIResult.failure(AgentCLIErrorClassifier.classify(error))
        }
    }
}
