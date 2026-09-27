import Foundation
import SpaceJudgeDomain

/// Reasons a snapshot node cannot be turned into a runtime file URL.
public enum RuntimePathResolverError: Error, Equatable, Sendable {
    /// The session root path is empty.
    case emptyRoot
    /// A stored name was not strict UTF-8, was empty, or contained a path
    /// separator, NUL, `.` or `..`.
    case invalidComponent
    /// The first ancestor was not the scan root.
    case rootMismatch
    /// The resolved path escaped the selected root after standardization.
    case outsideRoot
    /// The ancestor chain was empty or otherwise unusable.
    case invalidChain
}

/// Resolves a snapshot ancestor chain into a session-only file URL.
///
/// SQLite never stores absolute paths. A URL is composed at runtime from the
/// process-local selection root plus validated, single-component ancestor
/// names, then verified to stay inside the root. Symlinks are never followed by
/// this resolver; the caller performs the existence check off the main thread
/// and reports failure without echoing private paths.
public struct RuntimePathResolver: Sendable {
    /// Session-only POSIX path of the user-selected root.
    public let rootPath: String
    /// Root node of the active scan, used for the mismatch check.
    public let rootNodeID: NodeID

    public init(rootPath: String, rootNodeID: NodeID) {
        self.rootPath = rootPath
        self.rootNodeID = rootNodeID
    }

    /// Root-first ancestor nodes plus their scan-local names (same order).
    public func url(
        ancestorNodes: [NodeRecord],
        names: [NameRecord]
    ) throws -> URL {
        guard !rootPath.isEmpty else { throw RuntimePathResolverError.emptyRoot }
        guard ancestorNodes.count == names.count, let root = ancestorNodes.first else {
            throw RuntimePathResolverError.invalidChain
        }
        guard root.id == rootNodeID else {
            throw RuntimePathResolverError.rootMismatch
        }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        var target = rootURL
        // The first ancestor is the scan root; its name is already represented
        // by the selected URL and must not be appended twice.
        for index in 1..<ancestorNodes.count {
            let component = try validate(names[index])
            target.appendPathComponent(component)
        }

        let standardizedRoot = rootURL.standardizedFileURL
        let standardizedTarget = target.standardizedFileURL
        let rootComponents = standardizedRoot.pathComponents
        let targetComponents = standardizedTarget.pathComponents
        guard targetComponents.count >= rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else {
            throw RuntimePathResolverError.outsideRoot
        }
        return standardizedTarget
    }

    /// Strictly validates one stored name as a single POSIX path component.
    public func validate(_ name: NameRecord) throws -> String {
        guard let decoded = name.decodedString else {
            throw RuntimePathResolverError.invalidComponent
        }
        guard !decoded.isEmpty,
              decoded != ".",
              decoded != "..",
              !decoded.contains("/"),
              !decoded.contains("\0") else {
            throw RuntimePathResolverError.invalidComponent
        }
        return decoded
    }
}
