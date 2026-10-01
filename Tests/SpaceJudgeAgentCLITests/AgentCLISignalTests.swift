import Darwin
import Foundation
import Testing
@testable import SpaceJudgeAgentCLIKit
import SpaceJudgeDomain
import SpaceJudgeStore

/// Real-process test: the executable must translate SIGINT into the existing
/// cooperative cancellation and persist `cancelled` before exiting.
@Suite("spacejudge-agent-cli signals", .serialized)
struct AgentCLISignalTests {
    private static var executableURL: URL {
        // Sources/../Tests/SpaceJudgeAgentCLITests/<file> -> package root.
        let file = URL(fileURLWithPath: #filePath)
        let root = file
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent(".build/debug/spacejudge-agent-cli")
    }

    @Test("SIGINT persists a cancelled terminal")
    func sigintCancels() async throws {
        let executable = Self.executableURL
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))

        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("sj-signal-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let database = workspace.appendingPathComponent("scan.sqlite")
        defer { try? FileManager.default.removeItem(at: base) }

        // A wide tree keeps the scan alive long enough for a real SIGINT.
        let manager = FileManager.default
        try manager.createDirectory(
            at: workspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for directory in 0..<200 {
            let folder = root.appendingPathComponent("d\(directory)", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in 0..<60 {
                manager.createFile(
                    atPath: folder.appendingPathComponent("f\(file).bin").path,
                    contents: Data("payload".utf8)
                )
            }
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "scan",
            "--root", root.path,
            "--database", database.path,
            "--workspace", workspace.path
        ]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        let collector = SignalLineCollector()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collector.append(String(decoding: data, as: UTF8.self))
            }
        }

        try process.run()
        let pid = process.processIdentifier

        let started = await collector.waitFor(lineContaining: "\"type\":\"started\"", timeout: 20)
        #expect(started)

        // Exact PID only; never killall/pkill.
        #expect(kill(pid, SIGINT) == 0)

        let exited = await waitForExit(process, timeout: 20)
        #expect(exited)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            kill(pid, SIGKILL)
        }

        #expect(process.terminationStatus == 0)
        let output = collector.text
        #expect(output.contains("\"type\":\"cancelled\""), "output: \(output)")

        let scanIDText = try #require(collector.jsonObject(type: "started")?["scanId"] as? String)
        let scanID = try #require(UUID(uuidString: scanIDText))
        let repository = try SQLiteSnapshotRepository.openReadOnly(path: database.path)
        let state = try await repository.scanState(ScanID(rawValue: scanID))
        #expect(state?.status == .cancelled)
        await repository.close()
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

private final class SignalLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += text
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func waitFor(lineContaining needle: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if text.contains(needle) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return text.contains(needle)
    }

    /// Finds the first complete NDJSON object of a given `type`.
    func jsonObject(type: String) -> [String: Any]? {
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  dictionary["type"] as? String == type else {
                continue
            }
            return dictionary
        }
        return nil
    }
}
