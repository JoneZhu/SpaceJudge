// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpaceJudgeCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SpaceJudgeDomain", targets: ["SpaceJudgeDomain"]),
        .library(name: "SpaceJudgeScan", targets: ["SpaceJudgeScan"]),
        .library(name: "SpaceJudgeStore", targets: ["SpaceJudgeStore"]),
        .library(name: "SpaceJudgeUseCases", targets: ["SpaceJudgeUseCases"]),
        .library(name: "SpaceJudgeTreemap", targets: ["SpaceJudgeTreemap"]),
        .library(name: "SpaceJudgeTreemapUI", targets: ["SpaceJudgeTreemapUI"]),
        .library(name: "SpaceJudgeAppSupport", targets: ["SpaceJudgeAppSupport"]),
        .library(name: "SpaceJudgeBenchSupport", targets: ["SpaceJudgeBenchSupport"]),
        .library(name: "SpaceJudgeAgentCLIKit", targets: ["SpaceJudgeAgentCLIKit"]),
        .executable(name: "spacejudge-core-smoke", targets: ["SpaceJudgeCoreSmoke"]),
        .executable(name: "spacejudge-scan-smoke", targets: ["SpaceJudgeScanSmoke"]),
        .executable(name: "spacejudge-persist-smoke", targets: ["SpaceJudgePersistSmoke"]),
        .executable(name: "spacejudge-store-bench", targets: ["SpaceJudgeStoreBench"]),
        .executable(name: "spacejudge-treemap-bench", targets: ["SpaceJudgeTreemapBench"]),
        .executable(name: "spacejudge-e2e-bench", targets: ["SpaceJudgeE2EBench"]),
        .executable(name: "spacejudge-volume-plan", targets: ["SpaceJudgeVolumePlan"]),
        .executable(name: "spacejudge-agent-cli", targets: ["SpaceJudgeAgentCLI"])
    ],
    targets: [
        .target(
            name: "SpaceJudgeDomain"
        ),
        .target(
            name: "SpaceJudgeScan",
            dependencies: ["SpaceJudgeDomain"]
        ),
        .target(
            name: "SpaceJudgeStore",
            dependencies: ["SpaceJudgeDomain"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "SpaceJudgeUseCases",
            dependencies: ["SpaceJudgeDomain"]
        ),
        .target(
            name: "SpaceJudgeTreemap",
            dependencies: ["SpaceJudgeDomain"]
        ),
        .target(
            name: "SpaceJudgeAppSupport",
            dependencies: [
                "SpaceJudgeDomain", "SpaceJudgeScan", "SpaceJudgeStore", "SpaceJudgeTreemap",
                "SpaceJudgeUseCases"
            ]
        ),
        .target(
            name: "SpaceJudgeTreemapUI",
            dependencies: ["SpaceJudgeDomain", "SpaceJudgeTreemap", "SpaceJudgeAppSupport"]
        ),
        .executableTarget(
            name: "SpaceJudgeCoreSmoke",
            dependencies: ["SpaceJudgeDomain", "SpaceJudgeTreemap"]
        ),
        .executableTarget(
            name: "SpaceJudgeScanSmoke",
            dependencies: ["SpaceJudgeScan", "SpaceJudgeDomain"]
        ),
        .executableTarget(
            name: "SpaceJudgePersistSmoke",
            dependencies: [
                "SpaceJudgeScan", "SpaceJudgeStore", "SpaceJudgeUseCases", "SpaceJudgeDomain"
            ]
        ),
        .executableTarget(
            name: "SpaceJudgeStoreBench",
            dependencies: ["SpaceJudgeStore", "SpaceJudgeDomain"]
        ),
        .executableTarget(
            name: "SpaceJudgeTreemapBench",
            dependencies: ["SpaceJudgeDomain", "SpaceJudgeTreemap", "SpaceJudgeTreemapUI"]
        ),
        .target(
            name: "SpaceJudgeBenchSupport",
            dependencies: [
                "SpaceJudgeDomain", "SpaceJudgeScan", "SpaceJudgeStore", "SpaceJudgeUseCases"
            ]
        ),
        .target(
            name: "SpaceJudgeVolumePlanKit",
            dependencies: [
                "SpaceJudgeAppSupport", "SpaceJudgeDomain", "SpaceJudgeScan"
            ]
        ),
        .target(
            name: "SpaceJudgeAgentCLIKit",
            dependencies: [
                "SpaceJudgeAppSupport", "SpaceJudgeDomain", "SpaceJudgeScan",
                "SpaceJudgeStore", "SpaceJudgeUseCases"
            ]
        ),
        .executableTarget(
            name: "SpaceJudgeAgentCLI",
            dependencies: ["SpaceJudgeAgentCLIKit"]
        ),
        .executableTarget(
            name: "SpaceJudgeE2EBench",
            dependencies: ["SpaceJudgeBenchSupport"]
        ),
        .executableTarget(
            name: "SpaceJudgeVolumePlan",
            dependencies: [
                "SpaceJudgeVolumePlanKit"
            ]
        ),
        .testTarget(
            name: "SpaceJudgeDomainTests",
            dependencies: ["SpaceJudgeDomain"]
        ),
        .testTarget(
            name: "SpaceJudgeScanTests",
            dependencies: ["SpaceJudgeScan", "SpaceJudgeDomain"]
        ),
        .testTarget(
            name: "SpaceJudgeStoreTests",
            dependencies: ["SpaceJudgeStore", "SpaceJudgeDomain"]
        ),
        .testTarget(
            name: "SpaceJudgeUseCaseTests",
            dependencies: [
                "SpaceJudgeUseCases", "SpaceJudgeDomain", "SpaceJudgeScan", "SpaceJudgeStore"
            ]
        ),
        .testTarget(
            name: "SpaceJudgeTreemapTests",
            dependencies: ["SpaceJudgeTreemap", "SpaceJudgeDomain"]
        ),
        .testTarget(
            name: "SpaceJudgeAppSupportTests",
            dependencies: [
                "SpaceJudgeAppSupport", "SpaceJudgeDomain", "SpaceJudgeScan",
                "SpaceJudgeStore", "SpaceJudgeUseCases"
            ]
        ),
        .testTarget(
            name: "SpaceJudgeTreemapUITests",
            dependencies: [
                "SpaceJudgeTreemapUI", "SpaceJudgeTreemap", "SpaceJudgeAppSupport",
                "SpaceJudgeDomain"
            ]
        ),
        .testTarget(
            name: "SpaceJudgeBenchSupportTests",
            dependencies: [
                "SpaceJudgeBenchSupport", "SpaceJudgeDomain", "SpaceJudgeScan",
                "SpaceJudgeStore", "SpaceJudgeUseCases"
            ]
        ),
        .testTarget(
            name: "SpaceJudgeVolumePlanTests",
            dependencies: [
                "SpaceJudgeVolumePlanKit", "SpaceJudgeDomain", "SpaceJudgeAppSupport"
            ]
        ),
        .testTarget(
            name: "SpaceJudgeAgentCLITests",
            dependencies: [
                "SpaceJudgeAgentCLIKit", "SpaceJudgeDomain", "SpaceJudgeScan",
                "SpaceJudgeStore", "SpaceJudgeAppSupport", "SpaceJudgeUseCases"
            ]
        )
    ]
)
