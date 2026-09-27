import Foundation
import Testing
@testable import SpaceJudgeBenchSupport

private final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var combined: String {
        lock.lock()
        defer { lock.unlock() }
        return messages.joined(separator: "\n")
    }
}

@Suite("E2E benchmark arguments")
struct E2EBenchArgumentsTests {
    @Test("Defaults parse from --nodes")
    func defaults() throws {
        let options = try E2EBenchArguments.parse(["--nodes", "100000"])
        #expect(options.requestedNodes == 100_000)
        #expect(options.shape == .mixed)
        #expect(options.filesPerDirectory == 8)
        #expect(!options.cancelAfterFirstCommit)
        #expect(options.keepArtifactsPath == nil)
    }

    @Test("All options parse")
    func allOptions() throws {
        let options = try E2EBenchArguments.parse([
            "--nodes", "1000", "--shape", "wide", "--files-per-directory", "3",
            "--cancel-after-first-commit",
            "--keep-artifacts", "/tmp/spacejudge-demo"
        ])
        #expect(options.requestedNodes == 1_000)
        #expect(options.shape == .wide)
        #expect(options.filesPerDirectory == 3)
        #expect(options.cancelAfterFirstCommit)
        #expect(options.keepArtifactsPath == "/tmp/spacejudge-demo")
    }

    @Test("Missing and invalid --nodes are rejected")
    func invalidNodes() {
        #expect(throws: E2EBenchArgumentError.missingRequired(option: "--nodes")) {
            try E2EBenchArguments.parse([])
        }
        #expect(throws: E2EBenchArgumentError.missingValue(option: "--nodes")) {
            try E2EBenchArguments.parse(["--nodes"])
        }
        #expect(throws: E2EBenchArgumentError.invalidValue(option: "--nodes", value: "0")) {
            try E2EBenchArguments.parse(["--nodes", "0"])
        }
        #expect(throws: E2EBenchArgumentError.invalidValue(option: "--nodes", value: "-5")) {
            try E2EBenchArguments.parse(["--nodes", "-5"])
        }
        #expect(throws: E2EBenchArgumentError.invalidValue(option: "--nodes", value: "abc")) {
            try E2EBenchArguments.parse(["--nodes", "abc"])
        }
    }

    @Test("Invalid shape and unknown options are rejected")
    func invalidShape() {
        #expect(throws: E2EBenchArgumentError.invalidValue(option: "--shape", value: "deep")) {
            try E2EBenchArguments.parse(["--nodes", "10", "--shape", "deep"])
        }
        #expect(throws: E2EBenchArgumentError.unknownOption("--bogus")) {
            try E2EBenchArguments.parse(["--nodes", "10", "--bogus"])
        }
        #expect(throws: E2EBenchArgumentError.invalidValue(option: "--files-per-directory", value: "0")) {
            try E2EBenchArguments.parse(["--nodes", "10", "--files-per-directory", "0"])
        }
        // The removed, unbounded file-size knob is now just an unknown option.
        #expect(throws: E2EBenchArgumentError.unknownOption("--file-bytes")) {
            try E2EBenchArguments.parse(["--nodes", "10", "--file-bytes", "1048576"])
        }
    }

    @Test("Help is detected without parsing")
    func help() {
        #expect(E2EBenchArguments.helpRequested(["--help"]))
        #expect(E2EBenchArguments.helpRequested(["-h"]))
        #expect(E2EBenchArguments.helpRequested(["--nodes", "10", "--help"]))
        #expect(!E2EBenchArguments.helpRequested(["--nodes", "10"]))
        #expect(E2EBenchArguments.usage.contains("--nodes"))
    }
}

@Suite("Artifact root", .serialized)
struct ArtifactRootTests {
    private func uniquePath() -> String {
        NSTemporaryDirectory() + "spacejudge-artifact-\(UUID().uuidString)"
    }

    @Test("Temporary root is created with a marker and removed on cleanup")
    func temporaryCleanup() throws {
        let root = try ArtifactRoot.prepare(keepArtifactsAt: nil)
        #expect(root.isTemporary)
        #expect(root.rootPath.hasPrefix(NSTemporaryDirectory()))
        #expect(FileManager.default.fileExists(atPath: root.markerPath))
        #expect(root.fixturePath == root.rootPath + "/fixture")
        #expect(root.databasePath == root.rootPath + "/spacejudge.sqlite")

        #expect(root.cleanup())
        #expect(!FileManager.default.fileExists(atPath: root.rootPath))
    }

    @Test("Cleanup refuses a root whose marker was removed")
    func markerTamperRefused() throws {
        let root = try ArtifactRoot.prepare(keepArtifactsAt: nil)
        try FileManager.default.removeItem(atPath: root.markerPath)
        #expect(!root.cleanup())
        #expect(FileManager.default.fileExists(atPath: root.rootPath))
        // Manual teardown for the test itself.
        try? FileManager.default.removeItem(atPath: root.rootPath)
    }

    @Test("Keep mode refuses to overwrite an existing directory")
    func keepRefusesExisting() throws {
        let path = uniquePath()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: FixtureError.destinationExists(path)) {
            try ArtifactRoot.prepare(keepArtifactsAt: path)
        }
    }

    @Test("Keep mode creates a fresh directory and cleanup is a no-op")
    func keepMode() throws {
        let path = uniquePath()
        let root = try ArtifactRoot.prepare(keepArtifactsAt: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(!root.isTemporary)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!root.cleanup())
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

@Suite("Fixture generation", .serialized)
struct FixtureGeneratorTests {
    private func run(_ options: E2EBenchOptions) throws -> (FixtureManifest, String) {
        let root = NSTemporaryDirectory() + "spacejudge-fixture-\(UUID().uuidString)"
        let manifest = try FixtureGenerator().generate(options: options, at: root)
        return (manifest, root)
    }

    @Test("Mixed fixture creates exactly the requested node count")
    func mixedCounts() throws {
        let options = E2EBenchOptions(requestedNodes: 2_000, shape: .mixed)
        let (manifest, root) = try run(options)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(manifest.actualNodes == 2_000)
        #expect(manifest.directoryCount + manifest.fileCount == 2_000)
        #expect(manifest.directoryCount > 1)
        #expect(manifest.fileCount > 0)
        #expect(manifest.logicalBytes == UInt64(manifest.fileCount))
        #expect(manifest.shape == .mixed)
    }

    @Test("Wide fixture is a single directory with all files")
    func wideCounts() throws {
        let options = E2EBenchOptions(requestedNodes: 300, shape: .wide)
        let (manifest, root) = try run(options)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(manifest.actualNodes == 300)
        #expect(manifest.directoryCount == 1)
        #expect(manifest.fileCount == 299)
        #expect(manifest.logicalBytes == 299)
    }

    @Test("Generation is deterministic for identical parameters")
    func deterministic() throws {
        let options = E2EBenchOptions(requestedNodes: 1_500, shape: .mixed)
        let (first, firstRoot) = try run(options)
        let (second, secondRoot) = try run(options)
        defer {
            try? FileManager.default.removeItem(atPath: firstRoot)
            try? FileManager.default.removeItem(atPath: secondRoot)
        }
        #expect(first == second)
    }
}

@Suite("E2E pipeline smoke", .serialized)
struct E2EBenchPipelineTests {
    private static let stubMetrics = SystemMetrics(
        peakResidentBytes: { 12_345_678 },
        openFileDescriptorCount: { 7 }
    )
    private static let unavailableMetrics = SystemMetrics(
        peakResidentBytes: { nil },
        openFileDescriptorCount: { nil }
    )

    private func json(_ result: E2EBenchResult) throws -> [String: Any] {
        let data = Data(result.jsonString().utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw NSError(domain: "test", code: 1)
        }
        return dictionary
    }

    private func assertFinite(_ text: String) {
        let lowered = text.lowercased()
        // Match JSON number tokens only; key names like scanAndPersist contain
        // the letters "nan".
        #expect(!lowered.contains(": nan"))
        #expect(!lowered.contains(": inf"))
        #expect(!lowered.contains(": -inf"))
    }

    @Test("Mixed completed run persists every node and reopens read-only")
    func mixedCompleted() async throws {
        let options = E2EBenchOptions(requestedNodes: 2_500, shape: .mixed)
        let result = try await E2EBenchRunner(metrics: Self.stubMetrics).run(options) { _ in }
        #expect(result.status == "completed")
        #expect(result.actualNodes == 2_500)
        #expect(result.persistedNodes == 2_500)
        #expect(result.rootAggregateComplete)
        #expect(result.fdBaseline == 7)
        #expect(result.fdAfterClose == 7)
        #expect(result.fdDelta == 0)
        #expect(result.peakResidentBytes == 12_345_678)
        #expect(result.firstStartedMillis.isFinite)
        #expect(result.firstCommittedMillis.isFinite)
        #expect(result.scanAndPersistSeconds > 0)
        #expect(result.nodesPerSecond > 0)
        let expectedRate = Double(result.persistedNodes) / result.scanAndPersistSeconds
        #expect(abs(result.nodesPerSecond - expectedRate) <= 0.001 * max(1, expectedRate))

        let dictionary = try json(result)
        #expect(dictionary["schemaVersion"] as? Int == 1)
        #expect(dictionary["status"] as? String == "completed")
        #expect(dictionary["requestedNodes"] as? Int == 2_500)
        #expect(dictionary["actualNodes"] as? Int == 2_500)
        #expect(dictionary["persistedNodes"] as? Int == 2_500)
        #expect(dictionary["rootAggregateComplete"] as? Bool == true)
        #expect(dictionary["peakResidentBytes"] as? Int == 12_345_678)
        #expect(dictionary["fdDelta"] as? Int == 0)
        assertFinite(result.jsonString())
    }

    @Test("Wide completed run succeeds")
    func wideCompleted() async throws {
        let options = E2EBenchOptions(requestedNodes: 300, shape: .wide)
        let result = try await E2EBenchRunner(metrics: Self.stubMetrics).run(options) { _ in }
        #expect(result.status == "completed")
        #expect(result.actualNodes == 300)
        #expect(result.persistedNodes == 300)
        #expect(result.rootAggregateComplete)
        assertFinite(result.jsonString())
    }

    @Test("Cancel after first commit reaches cancelled with latency fields")
    func cancelAfterFirstCommit() async throws {
        let options = E2EBenchOptions(
            requestedNodes: 8_000,
            shape: .mixed,
            cancelAfterFirstCommit: true
        )
        let result = try await E2EBenchRunner(metrics: Self.stubMetrics).run(options) { _ in }
        #expect(result.status == "cancelled")
        #expect(result.cancelRequestedMillis != nil)
        #expect(result.cancelTerminalMillis != nil)
        #expect(result.cancelLatencyMillis != nil)
        #expect(result.updatesAfterCancelRequest != nil)
        #expect(result.persistedNodes <= UInt64(result.actualNodes))

        // Cancelled throughput must be based on persisted nodes, not the full
        // fixture: otherwise a 6k-node run would look ~17x faster than it is.
        #expect(result.scanAndPersistSeconds > 0)
        let expectedRate = Double(result.persistedNodes) / result.scanAndPersistSeconds
        #expect(abs(result.nodesPerSecond - expectedRate) <= 0.001 * max(1, expectedRate))
        #expect(result.persistedNodes < UInt64(result.actualNodes))
        let fixtureRate = Double(result.actualNodes) / result.scanAndPersistSeconds
        #expect(abs(result.nodesPerSecond - fixtureRate) > 1)

        let dictionary = try json(result)
        #expect(dictionary["status"] as? String == "cancelled")
        #expect(dictionary["cancelLatencyMillis"] is Double)
        #expect(dictionary["updatesAfterCancelRequest"] is Int)
        assertFinite(result.jsonString())
    }

    @Test("Unavailable OS metrics serialize as null, never as zero")
    func unavailableMetrics() async throws {
        let options = E2EBenchOptions(requestedNodes: 200, shape: .wide)
        let result = try await E2EBenchRunner(metrics: Self.unavailableMetrics).run(options) { _ in }
        #expect(result.peakResidentBytes == nil)
        #expect(result.fdBaseline == nil)
        #expect(result.fdAfterClose == nil)
        #expect(result.fdDelta == nil)

        let dictionary = try json(result)
        #expect(dictionary["peakResidentBytes"] is NSNull)
        #expect(dictionary["fdBaseline"] is NSNull)
        #expect(dictionary["fdDelta"] is NSNull)
        assertFinite(result.jsonString())
    }

    @Test("Keep-artifacts mode leaves the fixture and database in place")
    func keepArtifacts() async throws {
        let path = NSTemporaryDirectory() + "spacejudge-keep-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let options = E2EBenchOptions(
            requestedNodes: 150,
            shape: .wide,
            keepArtifactsPath: path
        )
        let result = try await E2EBenchRunner(metrics: Self.stubMetrics).run(options) { _ in }
        #expect(result.status == "completed")
        #expect(FileManager.default.fileExists(atPath: path + "/fixture"))
        #expect(FileManager.default.fileExists(atPath: path + "/spacejudge.sqlite"))
    }

    @Test("Invalid fixture parameters are rejected before any scan")
    func invalidFixtureParameters() async {
        let options = E2EBenchOptions(requestedNodes: 0, shape: .mixed)
        await #expect(throws: E2EBenchError.fixture("--nodes must be >= 1 (got 0)")) {
            try await E2EBenchRunner(metrics: Self.stubMetrics).run(options) { _ in }
        }
    }

    @Test("A temporary cleanup failure cannot report success or claim removal")
    func cleanupFailureCannotSucceed() async throws {
        let root = try ArtifactRoot.prepare(keepArtifactsAt: nil)
        try FileManager.default.removeItem(atPath: root.markerPath)
        defer { try? FileManager.default.removeItem(atPath: root.rootPath) }

        let logs = LogCollector()
        let runner = E2EBenchRunner(
            metrics: Self.stubMetrics,
            artifactRootProvider: { _ in root }
        )
        let options = E2EBenchOptions(requestedNodes: 150, shape: .wide)
        await #expect(throws: E2EBenchError.fixture(
            "temporary artifacts could not be removed; refusing to report success"
        )) {
            try await runner.run(options) { logs.append($0) }
        }
        #expect(!logs.combined.contains("removed temporary artifacts"))
        #expect(logs.combined.contains("warning: could not remove temporary artifacts"))
        #expect(FileManager.default.fileExists(atPath: root.rootPath))
    }
}
