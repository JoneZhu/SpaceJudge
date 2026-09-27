import Foundation
import Testing
import SpaceJudgeDomain
@testable import SpaceJudgeScan

@Suite("Directory boundary policy")
struct DirectoryBoundaryPolicyTests {
    private typealias Decision = DirectoryTraversalDecision

    private func decide(
        _ policy: BoundaryPolicy,
        root: UInt64? = 1,
        current: UInt64? = 1,
        child: UInt64? = 1,
        mount: Bool = false,
        firmlink: Bool = false
    ) -> Decision {
        DirectoryBoundaryPolicy.decide(
            policy: policy,
            rootDeviceID: root,
            currentDeviceID: current,
            childDeviceID: child,
            isMountPoint: mount,
            isFirmlink: firmlink
        )
    }

    // MARK: selectedTree

    @Test("selectedTree enters everything, including mounts and firmlinks")
    func selectedTree() {
        #expect(decide(.selectedTree, child: 2) == .descend(extraFlags: []))
        #expect(decide(.selectedTree, mount: true) == .descend(extraFlags: []))
        #expect(decide(.selectedTree, firmlink: true) == .descend(extraFlags: [.firmlinkProjection]))
        #expect(
            decide(.selectedTree, mount: true, firmlink: true)
                == .descend(extraFlags: [.firmlinkProjection])
        )
    }

    // MARK: stayOnRootFileSystem

    @Test("stayOnRootFileSystem enters a same-device directory")
    func stayOnSameDevice() {
        let decision = decide(.stayOnRootFileSystem)
        #expect(decision == .descend(extraFlags: []))
        #expect(decision.shouldDescend)
    }

    @Test("stayOnRootFileSystem truncates an unexpected device transition")
    func stayOnDeviceTransition() {
        #expect(
            decide(.stayOnRootFileSystem, child: 2)
                == .boundary(extraFlags: [.mountBoundary], reason: .unexpectedDeviceTransition)
        )
        // The comparison is always against the root device, so a child that is
        // back on the root device is entered even if a stale current device
        // says otherwise.
        #expect(
            decide(.stayOnRootFileSystem, root: 1, current: 2, child: 1)
                == .descend(extraFlags: [])
        )
    }

    @Test("stayOnRootFileSystem truncates mount points regardless of device")
    func stayOnMount() {
        #expect(
            decide(.stayOnRootFileSystem, mount: true)
                == .boundary(extraFlags: [.mountBoundary], reason: .mountPoint)
        )
        #expect(
            decide(.stayOnRootFileSystem, child: 2, mount: true)
                == .boundary(extraFlags: [.mountBoundary], reason: .mountPoint)
        )
    }

    @Test("stayOnRootFileSystem keeps a same-device firmlink but never grants a transition")
    func stayOnFirmlink() {
        #expect(
            decide(.stayOnRootFileSystem, firmlink: true)
                == .descend(extraFlags: [.firmlinkProjection])
        )
        // A firmlink whose projected directory reports a different device must
        // still be truncated under the old policy.
        #expect(
            decide(.stayOnRootFileSystem, child: 2, firmlink: true)
                == .boundary(extraFlags: [.mountBoundary], reason: .unexpectedDeviceTransition)
        )
    }

    @Test("Unknown devices never fabricate a transition")
    func unknownDevices() {
        #expect(decide(.stayOnRootFileSystem, root: nil, child: 2) == .descend(extraFlags: []))
        #expect(decide(.stayOnRootFileSystem, root: 1, child: nil) == .descend(extraFlags: []))
        #expect(
            decide(.visibleStartupVolumeGroup, current: nil, child: 2)
                == .descend(extraFlags: [])
        )
        #expect(
            decide(.visibleStartupVolumeGroup, current: 1, child: nil)
                == .descend(extraFlags: [])
        )
    }

    // MARK: visibleStartupVolumeGroup

    @Test("visible group enters an ordinary same-device directory")
    func visibleSameDevice() {
        #expect(decide(.visibleStartupVolumeGroup) == .descend(extraFlags: []))
    }

    @Test("visible group enters a firmlink and marks the projection")
    func visibleFirmlink() {
        #expect(
            decide(.visibleStartupVolumeGroup, firmlink: true)
                == .descend(extraFlags: [.firmlinkProjection])
        )
    }

    @Test("visible group truncates an unauthorized device transition")
    func visibleDeviceTransition() {
        #expect(
            decide(.visibleStartupVolumeGroup, current: 1, child: 2)
                == .boundary(extraFlags: [.mountBoundary], reason: .unexpectedDeviceTransition)
        )
        // After a firmlink moved the authorized device to 2, a further
        // transition to 3 is still unauthorized.
        #expect(
            decide(.visibleStartupVolumeGroup, current: 2, child: 3)
                == .boundary(extraFlags: [.mountBoundary], reason: .unexpectedDeviceTransition)
        )
        // The children of the firmlink projection are on the new device and
        // therefore allowed.
        #expect(decide(.visibleStartupVolumeGroup, current: 2, child: 2) == .descend(extraFlags: []))
    }

    @Test("A mount point always wins, even with a firmlink flag")
    func visibleMountWins() {
        #expect(
            decide(.visibleStartupVolumeGroup, mount: true)
                == .boundary(extraFlags: [.mountBoundary], reason: .mountPoint)
        )
        #expect(
            decide(.visibleStartupVolumeGroup, mount: true, firmlink: true)
                == .boundary(extraFlags: [.mountBoundary], reason: .mountPoint)
        )
        #expect(
            decide(.visibleStartupVolumeGroup, child: 1, mount: true)
                == .boundary(extraFlags: [.mountBoundary], reason: .mountPoint)
        )
    }
}
