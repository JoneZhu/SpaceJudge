import SwiftUI
import SpaceJudgeAppSupport

/// Phase 3 app shell.
///
/// The scene only wires the AppKit delegate, the open-panel adapter and the
/// SwiftUI status/list UI. All testable state lives in `SpaceJudgeAppSupport`.
///
/// Menu commands are installed by `AppDelegate` through AppKit rather than a
/// SwiftUI `.commands` builder: the enablement depends on the `@Observable`
/// model, and AppKit `validateMenuItem` makes the menu item state a reliable,
/// observable function of the shared `AppCommandPolicy`.
@main
struct SpaceJudgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("SpaceJudge") {
            RootView()
                .environmentObject(appDelegate)
        }
        .defaultSize(width: 1120, height: 760)
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
                    Button("重试") {
                        Task { await appDelegate.retryBootstrap() }
                    }
                    .controlSize(.large)
                    .disabled(appDelegate.isBootstrapping)
                    .accessibilityIdentifier("bootstrap-retry")
                }
                .padding(40)
                .frame(minWidth: 480, minHeight: 360)
            } else {
                VStack(spacing: 10) {
                    ProgressView("正在准备…")
                    if appDelegate.isBootstrapping {
                        Text("正在打开本地快照数据库…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 480, minHeight: 360)
            }
        }
    }
}
