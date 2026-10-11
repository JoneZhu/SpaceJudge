import Foundation
import OSLog
import SpaceJudgeStore

/// A closed vocabulary: no path, scanned name or free-form error reaches logs.
public enum StartupStage: String, Codable, Sendable, CaseIterable {
    case processEntry, appDidFinishLaunching, bootstrapStarted, bootstrapAlreadyRunning
    case workspaceResolved, workspacePrepareStarted, workspacePrepared, databaseFilesPrepared
    case writerOpenStarted, writerOpened, readerOpenStarted, readerOpened, repositoriesReady
    case modelReady, rootViewAppeared, bootstrapFailed, bootstrapDiscarded
    case retryRequested, terminationRequested, shutdownCompleted
}

public struct StartupFailure: Codable, Equatable, Sendable {
    public enum Family: String, Codable, Sendable { case workspace, sqlite, store, cocoa, posix, unknown }
    public let family: Family
    public let code: Int?

    public static func classify(_ error: any Error) -> Self {
        if error is SnapshotWorkspaceError { return Self(family: .workspace, code: nil) }
        if let store = error as? SnapshotStoreError {
            if case .sqlite(let code, _) = store { return Self(family: .sqlite, code: Int(code)) }
            return Self(family: .store, code: nil)
        }
        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain: return Self(family: .cocoa, code: nsError.code)
        case NSPOSIXErrorDomain: return Self(family: .posix, code: nsError.code)
        default: return Self(family: .unknown, code: nil)
        }
    }
}

public struct StartupRecord: Codable, Equatable, Sendable {
    public let schema: Int
    public let session: UUID
    public let sequence: UInt64
    public let pid: Int32
    public let version: String
    public let build: String
    public let timestampUTC: String
    public let elapsedMilliseconds: Double
    public let stage: StartupStage
    public let failure: StartupFailure?

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // All fields are finite primitive values and closed enums.
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{\"schema\":1,\"encodingFailed\":true}"
        }
        return text
    }
}

/// Thread-safe because bootstrap opens repositories in a detached task.
/// OSLog owns persistence/rotation. This logger never opens a file or scans.
public final class StartupDiagnostics: @unchecked Sendable {
    public static let subsystem = "com.hongdazhu.SpaceJudge"
    public static let category = "Startup"
    public static let shared = StartupDiagnostics(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    )

    private let lock = NSLock()
    private let session = UUID()
    private let started = ContinuousClock.now
    private var sequence: UInt64 = 0
    private let version: String
    private let build: String
    private let sink: @Sendable (StartupRecord) -> Void

    public init(version: String?, build: String?, sink: (@Sendable (StartupRecord) -> Void)? = nil) {
        self.version = Self.safeVersion(version)
        self.build = Self.safeVersion(build)
        self.sink = sink ?? { record in
            let logger = Logger(subsystem: Self.subsystem, category: Self.category)
            let json = record.json()
            if record.failure != nil { logger.error("\(json, privacy: .public)") }
            else { logger.notice("\(json, privacy: .public)") }
        }
    }

    public func record(_ stage: StartupStage, error: (any Error)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        let elapsed = started.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        sink(StartupRecord(
            schema: 1, session: session, sequence: sequence, pid: ProcessInfo.processInfo.processIdentifier,
            version: version, build: build,
            timestampUTC: Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)),
            elapsedMilliseconds: max(0, milliseconds), stage: stage,
            failure: error.map(StartupFailure.classify)
        ))
    }

    private static func safeVersion(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 32,
              raw.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              raw.first != ".", raw.last != ".", !raw.contains("..") else { return "unknown" }
        return raw
    }
}
