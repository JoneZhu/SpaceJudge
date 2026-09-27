import SpaceJudgeDomain

/// Why a directory entry became a traversal boundary.
///
/// Internal to the engine; both reasons publish the existing `mountBoundary`
/// node flag so the database schema does not grow.
public enum BoundaryReason: Sendable, Equatable, Hashable {
    /// The directory is a real file-system mount point.
    case mountPoint
    /// The directory lives on a device the current policy did not authorize.
    case unexpectedDeviceTransition
}

/// What to do with one directory entry.
public enum DirectoryTraversalDecision: Sendable, Equatable, Hashable {
    /// Enter the directory, adding these flags to the node.
    case descend(extraFlags: NodeFlags)
    /// Treat the directory as a boundary leaf, adding these flags.
    case boundary(extraFlags: NodeFlags, reason: BoundaryReason)

    /// The flags to attach to the node regardless of the decision.
    public var extraFlags: NodeFlags {
        switch self {
        case .descend(let flags), .boundary(let flags, _):
            return flags
        }
    }

    /// Whether traversal should continue into the directory.
    public var shouldDescend: Bool {
        if case .descend = self { return true }
        return false
    }
}

/// Pure, exhaustively testable directory boundary policy.
///
/// The engine supplies the facts it already observed from `getattrlistbulk`
/// plus the root/current device identities; this type owns only the decision.
/// Keeping it free of file-system access makes every policy combination a unit
/// test instead of a machine-dependent integration test.
public enum DirectoryBoundaryPolicy {
    /// Decides whether to enter one directory entry.
    ///
    /// Priority is fixed and must not be reordered:
    /// 1. a mount point is always a boundary (even with a firmlink flag);
    /// 2. under `visibleStartupVolumeGroup` a firmlink is always entered and
    ///    marked, because it is the one authorized projection into the paired
    ///    data volume;
    /// 3. under `visibleStartupVolumeGroup`, the direct children of a directory
    ///    that was itself entered through a firmlink may live on the projected
    ///    volume; that single authorized transition is carried by
    ///    `enteredThroughFirmlink` and is never inherited;
    /// 4. an explicit child/current device mismatch is a boundary;
    /// 5. an unknown device on either side is a normal directory;
    /// 6. everything else is a normal directory.
    ///
    /// Under `stayOnRootFileSystem` the comparison is always against the root
    /// device, so a firmlink never authorizes crossing into the data volume.
    public static func decide(
        policy: BoundaryPolicy,
        rootDeviceID: UInt64?,
        currentDeviceID: UInt64?,
        childDeviceID: UInt64?,
        isMountPoint: Bool,
        isFirmlink: Bool,
        enteredThroughFirmlink: Bool = false
    ) -> DirectoryTraversalDecision {
        switch policy {
        case .selectedTree:
            // Explicitly authorized to cross mounts. The firmlink fact is still
            // recorded so diagnostics remain truthful.
            return .descend(extraFlags: isFirmlink ? [.firmlinkProjection] : [])

        case .stayOnRootFileSystem:
            if isMountPoint {
                return .boundary(extraFlags: [.mountBoundary], reason: .mountPoint)
            }
            if let child = childDeviceID, let root = rootDeviceID, child != root {
                return .boundary(
                    extraFlags: [.mountBoundary],
                    reason: .unexpectedDeviceTransition
                )
            }
            return .descend(extraFlags: isFirmlink ? [.firmlinkProjection] : [])

        case .visibleStartupVolumeGroup:
            if isMountPoint {
                return .boundary(extraFlags: [.mountBoundary], reason: .mountPoint)
            }
            if isFirmlink {
                return .descend(extraFlags: [.firmlinkProjection])
            }
            if enteredThroughFirmlink {
                // The one transition authorized by the firmlink that led here.
                return .descend(extraFlags: [])
            }
            if let child = childDeviceID, let current = currentDeviceID, child != current {
                return .boundary(
                    extraFlags: [.mountBoundary],
                    reason: .unexpectedDeviceTransition
                )
            }
            return .descend(extraFlags: [])
        }
    }
}
