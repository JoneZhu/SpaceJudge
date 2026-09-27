import Foundation
import Testing
import SpaceJudgeVolumePlanKit

@Suite("spacejudge-volume-plan CLI", .serialized)
struct VolumePlanCommandTests {
    private func jsonObject(_ result: VolumePlanCommandResult) throws -> [String: Any] {
        let data = try #require(result.stdout.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("The startup root resolves to a visible volume group")
    func rootProbe() throws {
        let result = VolumePlanCommand.execute(arguments: ["--root", "/"])
        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let json = try jsonObject(result)
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["planKind"] as? String == "visibleStartupVolumeGroup")
        #expect(json["boundaryPolicy"] as? String == "visibleStartupVolumeGroup")
        #expect(json["isVolume"] as? Bool == true)
        #expect(json["isRootFileSystem"] as? Bool == true)
        #expect(json["rootDeviceKnown"] as? Bool == true)
        #expect((json["rootEntryCount"] as? Int ?? 0) > 0)
        #expect((json["firmlinkEntryCount"] as? Int ?? 0) > 0)
    }

    @Test("An ordinary temporary directory degrades to selectedFileSystem")
    func ordinaryDirectoryProbe() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacejudge-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = VolumePlanCommand.execute(arguments: ["--root", directory.path])
        #expect(result.exitCode == 0)
        let json = try jsonObject(result)
        #expect(json["planKind"] as? String == "selectedFileSystem")
        #expect(json["boundaryPolicy"] as? String == "stayOnRootFileSystem")
        #expect(json["rootEntryCount"] as? Int == 0)
        #expect(json["firmlinkEntryCount"] as? Int == 0)
        #expect(json["mountPointEntryCount"] as? Int == 0)
        #expect(json["unexpectedDeviceEntryCount"] as? Int == 0)
    }

    @Test("A missing path exits 3")
    func missingRoot() {
        let result = VolumePlanCommand.execute(
            arguments: ["--root", "/spacejudge-missing-\(UUID().uuidString)"]
        )
        #expect(result.exitCode == 3)
        #expect(result.stdout.isEmpty)
    }

    @Test("A non-directory path exits 3")
    func nonDirectoryRoot() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacejudge-plan-file-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = VolumePlanCommand.execute(arguments: ["--root", file.path])
        #expect(result.exitCode == 3)
        #expect(result.stdout.isEmpty)
    }

    @Test("stdout and stderr never reveal the input path or user name")
    func privacy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacejudge-private-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = VolumePlanCommand.execute(arguments: ["--root", directory.path])
        #expect(result.exitCode == 0)
        #expect(!result.stdout.contains(directory.path))
        #expect(!result.stdout.contains(directory.lastPathComponent))
        #expect(!result.stderr.contains(directory.path))

        let userName = NSUserName()
        if !userName.isEmpty {
            #expect(!result.stdout.contains(userName))
        }
    }

    @Test("--root=PATH form is accepted")
    func equalsForm() throws {
        let result = VolumePlanCommand.execute(arguments: ["--root=/"])
        #expect(result.exitCode == 0)
        #expect(!result.stdout.isEmpty)
    }

    @Test("--help exits 0 with usage and --root without a value exits 2")
    func helpAndArgumentErrors() {
        let help = VolumePlanCommand.execute(arguments: ["--help"])
        #expect(help.exitCode == 0)
        #expect(help.stdout.contains("usage:"))

        let missing = VolumePlanCommand.execute(arguments: ["--root"])
        #expect(missing.exitCode == 2)
        #expect(missing.stdout.isEmpty)
        #expect(!missing.stderr.isEmpty)

        let unknown = VolumePlanCommand.execute(arguments: ["--bogus"])
        #expect(unknown.exitCode == 2)
        #expect(unknown.stdout.isEmpty)
        #expect(!unknown.stderr.contains("--bogus"))
    }

    @Test("An unknown positional private path is never echoed to stdout or stderr")
    func unknownPositionalPathNotEchoed() {
        let secret = "/private/Users/secret-name"
        let result = VolumePlanCommand.execute(arguments: [secret])
        #expect(result.exitCode == 2)
        #expect(result.stdout.isEmpty)
        #expect(!result.stderr.contains(secret))
        #expect(!result.stderr.contains("secret-name"))
        #expect(!result.stderr.contains("Users"))
        let userName = NSUserName()
        if !userName.isEmpty {
            #expect(!result.stderr.contains(userName))
        }
    }

    @Test("Unknown public facts serialize as JSON null, not false")
    func nullEvidence() throws {
        let report = VolumePlanProbeReport(
            planKind: .selectedFileSystem,
            boundaryPolicy: .stayOnRootFileSystem,
            isVolume: nil,
            isRootFileSystem: nil,
            fileSystemType: nil,
            rootDeviceKnown: false,
            rootEntryCount: 0,
            firmlinkEntryCount: 0,
            mountPointEntryCount: 0,
            unexpectedDeviceEntryCount: 0
        )
        let line = try report.jsonLine()
        #expect(line.contains("\"isVolume\":null"))
        #expect(line.contains("\"isRootFileSystem\":null"))
        #expect(line.contains("\"fileSystemType\":null"))
        #expect(!line.contains("\"isVolume\":false"))
        #expect(!line.contains("\n"))
    }
}
