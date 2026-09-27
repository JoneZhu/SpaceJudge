import AppKit
import SpaceJudgeAppSupport

/// AppKit adapter for `DirectoryAccess`.
///
/// It only presents the panel and forwards to the URL security-scope methods;
/// all pairing decisions live in `AppModel` so they can be unit tested.
@MainActor
final class OpenPanelDirectoryAccess: DirectoryAccess {
    func pickDirectory() async -> DirectorySelection? {
#if DEBUG
        // Pi-only smoke seam: lets an automated build select a fixture root
        // without driving the open panel. Release ignores it entirely.
        if let raw = ProcessInfo.processInfo.environment["SPACEJUDGE_TEST_ROOT_PATH"],
           raw.hasPrefix("/") {
            return DirectorySelection(url: URL(fileURLWithPath: raw, isDirectory: true))
        }
#endif
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.prompt = "选择"
        panel.message = "选择要扫描的文件夹或磁盘"
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return nil }
        return DirectorySelection(url: url)
    }

    func startAccess(for selection: DirectorySelection) -> Bool {
        selection.url.startAccessingSecurityScopedResource()
    }

    func stopAccess(for selection: DirectorySelection) {
        selection.url.stopAccessingSecurityScopedResource()
    }
}
