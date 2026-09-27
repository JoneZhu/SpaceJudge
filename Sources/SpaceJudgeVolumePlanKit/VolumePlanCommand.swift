import Darwin
import Foundation
import SpaceJudgeAppSupport
import SpaceJudgeDomain
import SpaceJudgeScan

/// Privacy-safe report produced by `spacejudge-volume-plan`.
///
/// It deliberately omits the input path, user name, volume UUID, BSD disk name
/// and mount-from location. Unknown public facts are `nil`, never a fabricated
/// `false`.
public struct VolumePlanProbeReport: Sendable, Equatable {
    public let schemaVersion: Int
    public let planKind: VolumeScanPlanKind
    public let boundaryPolicy: BoundaryPolicy
    public let isVolume: Bool?
    public let isRootFileSystem: Bool?
    public let fileSystemType: String?
    public let rootDeviceKnown: Bool
    public let rootEntryCount: Int
    public let firmlinkEntryCount: Int
    public let mountPointEntryCount: Int
    public let unexpectedDeviceEntryCount: Int

    public init(
        schemaVersion: Int = 1,
        planKind: VolumeScanPlanKind,
        boundaryPolicy: BoundaryPolicy,
        isVolume: Bool?,
        isRootFileSystem: Bool?,
        fileSystemType: String?,
        rootDeviceKnown: Bool,
        rootEntryCount: Int,
        firmlinkEntryCount: Int,
        mountPointEntryCount: Int,
        unexpectedDeviceEntryCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.planKind = planKind
        self.boundaryPolicy = boundaryPolicy
        self.isVolume = isVolume
        self.isRootFileSystem = isRootFileSystem
        self.fileSystemType = fileSystemType
        self.rootDeviceKnown = rootDeviceKnown
        self.rootEntryCount = rootEntryCount
        self.firmlinkEntryCount = firmlinkEntryCount
        self.mountPointEntryCount = mountPointEntryCount
        self.unexpectedDeviceEntryCount = unexpectedDeviceEntryCount
    }

    private func jsonValue(_ value: Bool?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    private func jsonValue(_ value: String?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    /// Encodes the report as one JSON object (no trailing newline).
    public func jsonLine() throws -> String {
        let document: [String: Any] = [
            "schemaVersion": schemaVersion,
            "planKind": VolumePlanProbeReport.planKindName(planKind),
            "boundaryPolicy": VolumePlanProbeReport.boundaryPolicyName(boundaryPolicy),
            "isVolume": jsonValue(isVolume),
            "isRootFileSystem": jsonValue(isRootFileSystem),
            "fileSystemType": jsonValue(fileSystemType),
            "rootDeviceKnown": rootDeviceKnown,
            "rootEntryCount": rootEntryCount,
            "firmlinkEntryCount": firmlinkEntryCount,
            "mountPointEntryCount": mountPointEntryCount,
            "unexpectedDeviceEntryCount": unexpectedDeviceEntryCount
        ]
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let line = String(data: data, encoding: .utf8) else {
            throw VolumePlanProbeError.jsonEncodingFailed
        }
        return line
    }

    static func planKindName(_ kind: VolumeScanPlanKind) -> String {
        switch kind {
        case .selectedFileSystem: return "selectedFileSystem"
        case .visibleStartupVolumeGroup: return "visibleStartupVolumeGroup"
        }
    }

    static func boundaryPolicyName(_ policy: BoundaryPolicy) -> String {
        switch policy {
        case .selectedTree: return "selectedTree"
        case .stayOnRootFileSystem: return "stayOnRootFileSystem"
        case .visibleStartupVolumeGroup: return "visibleStartupVolumeGroup"
        }
    }
}

/// Errors from the non-recursive probe.
public enum VolumePlanProbeError: Error, Equatable, Sendable {
    /// The root could not be opened as a directory.
    case rootUnreadable(errno: Int32)
    /// The immediate children could not be enumerated.
    case enumerationFailed
    /// The JSON document could not be encoded.
    case jsonEncodingFailed
}

/// Runs the non-recursive root probe using the production enumerator, parser
/// and planner. It reads only the root's immediate children.
public enum VolumePlanProbe {
    /// Probes `rootPath`. Throws `VolumePlanProbeError` on unreadable roots.
    public static func run(rootPath: String) throws -> VolumePlanProbeReport {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let descriptor = rootURL.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return open(pointer, O_RDONLY | O_DIRECTORY)
        }
        guard descriptor >= 0 else {
            throw VolumePlanProbeError.rootUnreadable(errno: errno)
        }
        defer { _ = close(descriptor) }

        var rootStatus = stat()
        let rootDeviceID: UInt64? = fstat(descriptor, &rootStatus) == 0
            ? UInt64(UInt32(bitPattern: rootStatus.st_dev))
            : nil

        let plan = FoundationVolumeScanPlanner().plan(
            for: DirectorySelection(url: rootURL)
        )

        var entries: [RawDirectoryEntry] = []
        do {
            let enumerator = DarwinBulkEnumerator()
            var cursor = try enumerator.makeCursor(
                in: DirectoryHandle(fileDescriptor: descriptor),
                request: EnumerationRequest()
            )
            var finished = false
            while !finished {
                let page = try cursor.nextPage()
                entries.append(contentsOf: page.entries)
                finished = page.isLast
            }
        } catch {
            throw VolumePlanProbeError.enumerationFailed
        }

        var firmlinkCount = 0
        var mountPointCount = 0
        var unexpectedDeviceCount = 0
        for entry in entries {
            if entry.isMountPoint { mountPointCount += 1 }
            if entry.isFirmlink { firmlinkCount += 1 }
            guard entry.kind == .directory else { continue }
            let decision = DirectoryBoundaryPolicy.decide(
                policy: plan.boundaryPolicy,
                rootDeviceID: rootDeviceID,
                currentDeviceID: rootDeviceID,
                childDeviceID: entry.deviceID,
                isMountPoint: entry.isMountPoint,
                isFirmlink: entry.isFirmlink
            )
            if case .boundary(_, .unexpectedDeviceTransition) = decision {
                unexpectedDeviceCount += 1
            }
        }

        return VolumePlanProbeReport(
            planKind: plan.kind,
            boundaryPolicy: plan.boundaryPolicy,
            isVolume: plan.evidence.isVolume,
            isRootFileSystem: plan.evidence.isRootFileSystem,
            fileSystemType: plan.evidence.fileSystemType,
            rootDeviceKnown: rootDeviceID != nil,
            rootEntryCount: entries.count,
            firmlinkEntryCount: firmlinkCount,
            mountPointEntryCount: mountPointCount,
            unexpectedDeviceEntryCount: unexpectedDeviceCount
        )
    }
}

/// Outcome of a `spacejudge-volume-plan` invocation, captured for tests.
public struct VolumePlanCommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

/// The full command-line behavior, separated from process exit so it can be
/// unit-tested without spawning a process.
public enum VolumePlanCommand {
    public static let usage = """
    usage: spacejudge-volume-plan [--root PATH]

    Resolves the startup-volume scan plan for PATH (default: /) from public
    Foundation volume properties and enumerates the root's IMMEDIATE children only.

    Privacy and scope:
      * No recursion; no personal directory contents are read.
      * stdout is a single JSON object.
      * The input path, user name, volume UUID, BSD disk name and mount-from
        location are never printed.

    Exit codes: 0 success (safe degradation included), 2 arguments, 3 root
    unreadable, 4 JSON encoding failure.
    """

    /// Executes one invocation.
    public static func execute(arguments: [String]) -> VolumePlanCommandResult {
        if arguments.contains("--help") || arguments.contains("-h") {
            return VolumePlanCommandResult(exitCode: 0, stdout: usage + "\n", stderr: "")
        }

        let root: String
        switch parseRoot(arguments) {
        case .value(let value):
            root = value
        case .failure(let message):
            return VolumePlanCommandResult(
                exitCode: 2,
                stdout: "",
                stderr: "error: \(message)\nerror: run with --help for usage\n"
            )
        }

        do {
            let report = try VolumePlanProbe.run(rootPath: root)
            let line = try report.jsonLine()
            return VolumePlanCommandResult(exitCode: 0, stdout: line + "\n", stderr: "")
        } catch let error as VolumePlanProbeError {
            switch error {
            case .rootUnreadable(let code):
                return VolumePlanCommandResult(
                    exitCode: 3,
                    stdout: "",
                    stderr: "error: cannot open root as a directory (errno \(code))\n"
                )
            case .enumerationFailed:
                return VolumePlanCommandResult(
                    exitCode: 3,
                    stdout: "",
                    stderr: "error: cannot enumerate root immediate children\n"
                )
            case .jsonEncodingFailed:
                return VolumePlanCommandResult(
                    exitCode: 4,
                    stdout: "",
                    stderr: "error: failed to encode JSON\n"
                )
            }
        } catch {
            return VolumePlanCommandResult(
                exitCode: 4,
                stdout: "",
                stderr: "error: failed to encode JSON\n"
            )
        }
    }

    private enum ParsedRoot {
        case value(String)
        case failure(String)
    }

    private static func parseRoot(_ arguments: [String]) -> ParsedRoot {
        var root = "/"
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--root=") {
                root = String(argument.dropFirst("--root=".count))
            } else if argument == "--root" {
                index += 1
                guard index < arguments.count else {
                    return .failure("--root requires a value")
                }
                root = arguments[index]
            } else {
                // Never echo the argument value: it may be a private path. The
                // usage contract says the input path never reaches stderr.
                if argument.hasPrefix("-") {
                    return .failure("unknown option")
                }
                return .failure("unexpected argument")
            }
            index += 1
        }
        return .value(root)
    }
}
