import Foundation
import SpaceJudgeAppSupport
import SpaceJudgeDomain
import SpaceJudgeScan
import SpaceJudgeStore

/// Stable process-level error codes for the agent CLI NDJSON contract.
///
/// Callers are expected to branch on `code`; `message` is human-readable and is
/// deliberately generic so it can never leak a path, user name or file name.
public enum AgentCLIErrorCode: String, Sendable, Equatable, CaseIterable {
    case invalidArgument = "INVALID_ARGUMENT"
    case notFound = "NOT_FOUND"
    case conflict = "CONFLICT"
    case accessDenied = "ACCESS_DENIED"
    case insufficientSpace = "INSUFFICIENT_SPACE"
    case internalError = "INTERNAL"

    /// Stable process exit code for this error class.
    public var exitCode: Int32 {
        switch self {
        case .invalidArgument: return 2
        case .notFound: return 3
        case .conflict: return 4
        case .accessDenied: return 5
        case .insufficientSpace: return 6
        case .internalError: return 1
        }
    }

    /// Path-free human-readable message. Callers must not depend on it.
    public var message: String {
        switch self {
        case .invalidArgument: return "The request is invalid."
        case .notFound: return "The requested item was not found."
        case .conflict: return "The request conflicts with the current state."
        case .accessDenied: return "Access was denied."
        case .insufficientSpace: return "There is not enough storage space."
        case .internalError: return "An internal error occurred."
        }
    }
}

/// A path-free, process-level CLI failure.
public struct AgentCLIError: Error, Sendable, Equatable {
    public let code: AgentCLIErrorCode
    public let message: String

    public init(code: AgentCLIErrorCode) {
        self.code = code
        self.message = code.message
    }

    public init(code: AgentCLIErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    /// One NDJSON error object without a trailing newline.
    public func jsonLine() -> String {
        AgentJSON.line([
            "type": "error",
            "code": code.rawValue,
            "message": message
        ])
    }
}

/// Converts arbitrary thrown errors into stable, path-free CLI error classes.
public enum AgentCLIErrorClassifier {
    public static func classify(_ error: any Error) -> AgentCLIError {
        if let error = error as? AgentCLIError {
            return error
        }
        if let error = error as? SnapshotStoreError {
            switch error {
            case .storageCapacityUnavailable, .insufficientStorage:
                return AgentCLIError(code: .insufficientSpace)
            case .scanNotFound:
                return AgentCLIError(code: .notFound)
            case .scanAlreadyExists:
                return AgentCLIError(code: .conflict)
            case .scanNotRunning:
                return AgentCLIError(code: .conflict)
            default:
                return AgentCLIError(code: .internalError)
            }
        }
        if let error = error as? ScanError {
            switch error {
            case .rootOpenFailed(let errno):
                return classifyErrno(errno)
            case .scanRootInsideSnapshotWorkspace:
                return AgentCLIError(code: .invalidArgument)
            case .tooManyWorkspaceExclusions:
                return AgentCLIError(code: .invalidArgument)
            case .cancelled:
                return AgentCLIError(code: .conflict)
            default:
                return AgentCLIError(code: .internalError)
            }
        }
        if let error = error as? SnapshotWorkspaceError {
            switch error {
            case .workspaceRootSymbolicLink, .unsafeWorkspaceEntry:
                return AgentCLIError(code: .invalidArgument)
            case .workspaceRootNotDirectory, .workspaceUnavailable,
                 .workspacePermissionsUnavailable, .entryRemovalFailed:
                return AgentCLIError(code: .accessDenied)
            }
        }
        return AgentCLIError(code: .internalError)
    }

    private static func classifyErrno(_ code: Int32) -> AgentCLIError {
        switch code {
        case EACCES, EPERM:
            return AgentCLIError(code: .accessDenied)
        case ENOENT, ENOTDIR:
            return AgentCLIError(code: .notFound)
        default:
            return AgentCLIError(code: .internalError)
        }
    }
}
