import SwiftUI
import SpaceJudgeAppSupport

/// Phase 3 app shell.
///
/// The scene only wires the AppKit delegate, the open-panel adapter and the
/// SwiftUI status/list UI. All testable state lives in `SpaceJudgeAppSupport`.
@main
struct SpaceJudgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("SpaceJudge") {
            RootView()
                .environmentObject(appDelegate)
        }
        .defaultSize(width: 960, height: 680)
        .commands {
            CommandGroup(after: .newItem) {
                Button("选择文件夹或磁盘…") {
                    Task { await appDelegate.model?.chooseRoot() }
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(appDelegate.model == nil || appDelegate.model?.phase == .choosingRoot)

                Button("重新扫描") {
                    Task { await appDelegate.model?.rescan() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appDelegate.model?.hasRoot != true)
            }
        }
    }
}

/// Root view that waits for the async database bootstrap before showing the
/// main content.
struct RootView: View {
    @EnvironmentObject private var appDelegate: AppDelegate

    var body: some View {
        Group {
            if let model = appDelegate.model {
                ContentView(model: model)
            } else if let error = appDelegate.bootstrapError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(40)
                .frame(minWidth: 640, minHeight: 420)
            } else {
                ProgressView("正在准备…")
                    .frame(minWidth: 640, minHeight: 420)
            }
        }
    }
}
