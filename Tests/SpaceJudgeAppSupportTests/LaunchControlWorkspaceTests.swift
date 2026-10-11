import Foundation
import Testing
@testable import SpaceJudgeAppSupport

@Suite("Launch-control workspace isolation")
struct LaunchControlWorkspaceTests {
    @Test("Diagnostic path is unique and never the production root")
    func independentPaths() throws {
        let base = URL(fileURLWithPath: "/private/tmp/launch-control-unit-tests", isDirectory: true)
        let first = try SnapshotWorkspace.launchControl(
            bundleIdentifier: "com.hongdazhu.SpaceJudgeLaunchControl.r012345abcdef", cachesDirectory: base
        )
        let second = try SnapshotWorkspace.launchControl(
            bundleIdentifier: "com.hongdazhu.SpaceJudgeLaunchControl.rfedcba543210", cachesDirectory: base
        )
        #expect(first.rootURL.path == base.path + "/SpaceJudgeLaunchControl-012345abcdef")
        #expect(first.databaseURL.path == first.rootURL.path + "/snapshots.sqlite")
        #expect(first.rootURL != second.rootURL)
        #expect(first.rootURL != base.appendingPathComponent("SpaceJudge", isDirectory: true))
        // Mapping alone must not create a directory or database.
        #expect(!FileManager.default.fileExists(atPath: first.rootURL.path))
    }

    @Test("Production identity and unsafe tokens fail closed", arguments: [
        "com.hongdazhu.SpaceJudge", "", "com.hongdazhu.SpaceJudgeLaunchControl.r",
        "com.hongdazhu.SpaceJudgeLaunchControl.r012345abcde",
        "com.hongdazhu.SpaceJudgeLaunchControl.r012345abcdef0",
        "com.hongdazhu.SpaceJudgeLaunchControl.r012345abcdeF",
        "com.hongdazhu.SpaceJudgeLaunchControl.r012345abcdeg",
        "com.hongdazhu.SpaceJudgeLaunchControl.r../../SpaceJudge",
        "com.hongdazhu.SpaceJudgeLaunchControl.r012345abcde/",
        "com.hongdazhu.SpaceJudgeLaunchControl.r012345abcdef\n"
    ])
    func rejectsUnsafeIdentity(_ identifier: String) {
        #expect(throws: SnapshotWorkspaceError.workspaceUnavailable) {
            try SnapshotWorkspace.launchControl(
                bundleIdentifier: identifier,
                cachesDirectory: URL(fileURLWithPath: "/private/tmp/launch-control-unit-tests", isDirectory: true)
            )
        }
    }

    @Test("Non-file cache URLs are rejected")
    func rejectsRemoteBase() {
        #expect(throws: SnapshotWorkspaceError.workspaceUnavailable) {
            try SnapshotWorkspace.launchControl(
                bundleIdentifier: "com.hongdazhu.SpaceJudgeLaunchControl.r012345abcdef",
                cachesDirectory: URL(string: "https://example.invalid/caches")!
            )
        }
    }
}
