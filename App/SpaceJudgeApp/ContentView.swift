import AppKit
import SpaceJudgeAppSupport
import SpaceJudgeDomain
import SpaceJudgeTreemap
import SpaceJudgeTreemapUI
import SwiftUI

/// Phase 7 shell: one compact navigation bar, the native treemap surface and a
/// small capacity strip.
///
/// The treemap fills the window; the navigation bar and the status strip are
/// ordinary rows so they can never overlap the AppKit canvas. All testable
/// classification lives in `SpaceJudgeAppSupport` (`AppPresentationState`,
/// `CapacityPresentation`); this file only renders it.
struct ContentView: View {
    let model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsInfo = false
    @State private var showsReconciliation = false
    @State private var showsProjectList = false
    @State private var showsAgentAnalysis = false
    @State private var analysisNodeID: NodeID?
    @State private var analysisSnapshot: AgentAnalysisSnapshot?
    @State private var cleanupContext: CodexCleanupContext?
    @State private var includesTargetPath = true
    @State private var codexDraft: CodexDesktopDraft?
    @State private var handoffStatus = "正在准备扫描摘要…"
#if DEBUG
    @State private var showsDiagnostics = false
#endif

    private let accent = Color(red: 0.20, green: 0.66, blue: 0.42)
    /// Soft green used for the treemap's directory text, matching the accepted
    /// prototype. Dark mode uses a lighter tone so it stays readable.
    private var directoryTint: Color {
        colorScheme == .dark
            ? Color(red: 0.62, green: 0.86, blue: 0.70)
            : Color(red: 0.18, green: 0.44, blue: 0.30)
    }

    var body: some View {
        Group {
            if model.hasRoot {
                VStack(spacing: 0) {
                    topBar
                    Divider()
                    treemapArea
                    Divider()
                    statusStrip
                }
            } else {
                welcomePage
            }
        }
        .frame(minWidth: 736, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showsAgentAnalysis) { agentAnalysisPanel }
        // A new scan/root invalidates local panel state so an old reveal error
        // or info panel cannot survive into the new scan.
        .onChange(of: model.scanID) { _, _ in
            showsInfo = false
            showsReconciliation = false
            showsProjectList = false
        }
        // While a new focus loads, the popover would otherwise show the old
        // page as if it were the current range.
        .onChange(of: model.isSceneStale) { _, stale in
            if stale { showsProjectList = false }
        }
#if DEBUG
        .background(diagnosticsShortcut)
        .sheet(isPresented: $showsDiagnostics) {
            diagnosticsList
        }
#endif
    }

    // MARK: Welcome / explicit scan location

    private var welcomePage: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 24)
            VStack(spacing: 12) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(accent.gradient)
                    .padding(20)
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 26))
                    .accessibilityHidden(true)
                Text("SpaceJudge")
                    .font(.system(size: 30, weight: .semibold))
                Text("空间，一眼看清。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("选择要扫描的位置")
                    .font(.headline)
                    .padding(.bottom, 2)
                welcomeLocation("我的用户目录", subtitle: "查看应用数据、项目和个人文件", icon: "house",
                    initialURL: FileManager.default.homeDirectoryForCurrentUser, identifier: "welcome-home")
                welcomeLocation("Macintosh HD", subtitle: "选择磁盘，查看整个扫描范围", icon: "internaldrive",
                    initialURL: URL(fileURLWithPath: "/", isDirectory: true), identifier: "welcome-disk")
                welcomeLocation("选择其他文件夹…", subtitle: "只分析你关心的位置", icon: "folder.badge.plus",
                    initialURL: nil, identifier: "welcome-folder")
            }
            .frame(maxWidth: 460)
            HStack(spacing: 6) {
                if model.phase == .choosingRoot {
                    ProgressView().controlSize(.small)
                    Text("在系统窗口中确认扫描位置")
                } else {
                    Image(systemName: "lock.shield")
                    Text("只读扫描 · 不会删除文件 · 结果边扫边显示")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: 24)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func welcomeLocation(_ title: String, subtitle: String, icon: String,
                                 initialURL: URL?, identifier: String) -> some View {
        Button {
            Task { await model.chooseRoot(initialURL: initialURL) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(directoryTint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!model.canChooseRoot)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Top navigation

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.chooseRoot() }
            } label: {
                Image(systemName: "folder")
            }
            .disabled(!model.canChooseRoot)
            .help("选择文件夹或磁盘")
            .accessibilityLabel("选择文件夹或磁盘")
            .accessibilityIdentifier("choose-root")

            Divider().frame(height: 16)

            Button {
                Task { await model.goBack() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .help("后退")
            .accessibilityLabel("后退")
            .accessibilityIdentifier("go-back")

            Button {
                Task { await model.goUp() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(!model.canGoUp)
            .help("上一级")
            .accessibilityLabel("上一级")
            .accessibilityIdentifier("go-up")

            breadcrumbs

            Divider().frame(height: 16)

            statusView

            Button {
                showsProjectList.toggle()
            } label: {
                Image(systemName: "list.bullet")
            }
            .disabled(model.treemapScene == nil || model.isSceneStale)
            .help("列出当前范围项目（含 0 占用）")
            .accessibilityLabel("列出当前范围项目")
            .accessibilityIdentifier("project-list")
            .popover(isPresented: $showsProjectList, arrowEdge: .bottom) {
                projectList
            }

            // Cancel only exists while a scan is actually running; a stable
            // state never shows a row of disabled grey buttons.
            if model.canCancel {
                Button {
                    Task { await model.cancelScan() }
                } label: {
                    Label("取消", systemImage: "stop.circle")
                }
                .help("取消当前扫描")
                .accessibilityIdentifier("cancel-scan")
            }

            Button {
                Task { await model.rescan() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!model.canRescan)
            .help("刷新整个扫描范围（⌘R），保留当前位置")
            .accessibilityLabel("刷新整个扫描范围")
            .accessibilityIdentifier("rescan")

            Picker("详细程度", selection: detailModeBinding) {
                Text("概览").tag(TreemapDetailMode.overview)
                Text("详细").tag(TreemapDetailMode.detail)
            }
            .pickerStyle(.segmented)
            .frame(width: 116)
            .labelsHidden()
            .help("切换概览或详细密度")
            .accessibilityIdentifier("detail-mode")

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var agentAnalysisPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("用 Codex 制定清理方案").font(.title2)
                Spacer()
                Button("关闭") { showsAgentAnalysis = false }
            }
            if let snapshot = analysisSnapshot {
                let scope = snapshot.nodes.first { $0.nodeId == snapshot.scopeNodeId }
                Text("\(scope?.name ?? "当前目录") · \(scope?.attributed.gb ?? "未知") GB · \(scope?.attributed.bytes ?? "未知") B")
                    .font(.headline).lineLimit(2)
                Text("快照 \(snapshot.scanId.prefix(8)) · 版本 \(snapshot.revision) · \(snapshot.nodes.count) 项")
                    .font(.caption).foregroundStyle(.secondary)
                if snapshot.captureTruncated || snapshot.scanStatus != "completed" {
                    Text("这是部分数据。Agent 会说明未覆盖范围；不会把未捕获的目录当成 0。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if let path = cleanupContext?.targetPath {
                Toggle("提供准确路径，便于定向核查（可关闭）", isOn: $includesTargetPath)
                    .font(.callout)
                Text(verbatim: includesTargetPath ? path : "路径不携带；Codex 会先询问目标位置")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(3).help(path)
            }
            Text("提供所选项目的路径（可选）、占用摘要与 SpaceJudge CLI 用法，帮助 Codex 核查并给出具体清理步骤、风险和收益。不会自动发送，不传文件内容；在 Codex 检查后确认发送。")
                .font(.callout).foregroundStyle(.secondary)
            Text("直接使用桌面 Codex 自己的登录，无需 SpaceJudge 单独登录，也无需 Node。结果和后续对话留在 Codex。")
                .font(.callout)
            Text("Codex 可做必要的只读核查和所选目录重扫；删除、prune、停服务等需另行授权。这是外部交接，Codex 使用自己的权限；不会自动连接 MCP 或修改配置。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text(handoffStatus).font(.caption).textSelection(.enabled)
                Spacer()
                Button("复制分析草稿") {
                    guard let draft = codexDraft else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft.prompt, forType: .string)
                    handoffStatus = "已复制，可粘贴到 Codex；尚未发送"
                }
                .disabled(codexDraft == nil)
                Button("打开 Codex 草稿") { openCodexDraft() }
                    .disabled(codexDraft == nil)
                    .accessibilityIdentifier("open-codex-draft")
            }
            ScrollView {
                Text(verbatim: codexDraft?.prompt ?? "正在读取固定快照，不会重扫磁盘。")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 180)
        }
        .padding(24).frame(width: 650, height: 650)
        .onChange(of: includesTargetPath) { _, _ in rebuildCleanupDraft() }
        .task {
            guard let node = analysisNodeID else { return }
            do {
                let captured = try await model.captureCleanupHandoff(nodeID: node)
                try Task.checkCancellation()
                analysisSnapshot = captured.snapshot; cleanupContext = captured.context
                rebuildCleanupDraft()
            } catch is CancellationError { } catch {
                handoffStatus = "快照不可用，请等待扫描/刷新结束后重新右键分析。"
            }
        }
    }

    private func rebuildCleanupDraft() {
        guard let snapshot = analysisSnapshot, let context = cleanupContext else { return }
        do {
            codexDraft = try CodexDesktopDraft(snapshot: snapshot,
                context: includesTargetPath ? context : context.withholdingPath(),
                cliPath: CodexCleanupContext.bundledCLIPath(bundleURL: Bundle.main.bundleURL))
            handoffStatus = "清理方案草稿已就绪 · 尚未发送"
        } catch {
            codexDraft = nil
            handoffStatus = "摘要过长，无法安全生成跳转；请进入更小的目录，或关闭路径后重试。"
        }
    }

    private func openCodexDraft() {
        guard let draft = codexDraft else { return }
        guard NSWorkspace.shared.urlForApplication(toOpen: draft.url) != nil,
              NSWorkspace.shared.open(draft.url) else {
            handoffStatus = "未能打开 Codex。可复制草稿手动粘贴；请检查桌面应用是否已安装。"
            return
        }
        handoffStatus = "已请求打开 Codex 草稿，请在 Codex 中确认发送"
    }

    private var detailModeBinding: Binding<TreemapDetailMode> {
        Binding(
            get: { model.detailMode },
            set: { model.setDetailMode($0) }
        )
    }

    private var statusView: some View {
        // Adaptive: at the minimum window width the full counters would push
        // the path and actions out, so the compact variant keeps only the
        // status and moves the full counters into the tooltip/AX value.
        ViewThatFits(in: .horizontal) {
            fullStatusView
            compactStatusView
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityStatus)
    }

    private var fullStatusView: some View {
        HStack(spacing: 6) {
            statusSpinner
            Text(statusTitle)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .accessibilityIdentifier("scan-status")
            if let counts = countsLine {
                Text(counts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("scan-counts")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(accessibilityStatus)
    }

    private var compactStatusView: some View {
        HStack(spacing: 6) {
            statusSpinner
            Text(statusTitle)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .accessibilityIdentifier("scan-status")
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(accessibilityStatus)
    }

    @ViewBuilder
    private var statusSpinner: some View {
        if model.presentationState.isBusy, model.presentationState != .cancelling {
            ProgressView().controlSize(.mini)
        }
    }

    private var accessibilityStatus: String {
        if let counts = countsLine {
            return "\(statusTitle)，\(counts)"
        }
        return statusTitle
    }

    private var statusTitle: String {
        if model.isRefreshing {
            return model.phase == .cancelling ? "正在取消刷新" : "正在刷新"
        }
        if model.phase == .scanning { return "扫描中 · 实时更新" }
        return model.presentationState.title
    }

    /// Transient/terminal counters. Never a fabricated percentage. Kept in the
    /// tooltip/AX value even when the compact toolbar hides them.
    private var countsLine: String? {
        if model.isRefreshing { return model.progressLine }
        switch model.presentationState {
        case .awaitingFirstBatch:
            return "等待首批数据"
        case .scanning:
            return model.progressLine
        case .completed where model.summary != nil:
            if let summary = model.summary {
                return "\(summary.fileCount) 文件 · \(summary.directoryCount) 目录"
            }
            return nil
        default:
            return nil
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.nodeID) { index, item in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        Task { await model.navigate(to: item.nodeID) }
                    } label: {
                        Text(item.name.isEmpty ? "…" : item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(index == 0 ? .callout.weight(.semibold) : .callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        index == model.breadcrumbs.count - 1 ? directoryTint : .secondary
                    )
                    .help(item.name.isEmpty ? "…" : item.name)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("breadcrumbs")
    }

    // MARK: Treemap

    private var treemapArea: some View {
        ZStack {
            if model.hasRoot {
                TreemapViewRepresentable(
                    content: treemapContent,
                    actions: treemapActions
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
                .padding(8)
            } else {
                emptyState
            }

            stateExplanation

            VStack {
                Spacer()
                if let other = model.selectedOther {
                    otherSelectionSummary(other)
                        .padding(.bottom, 10)
                }
                if model.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(model.isRefreshing
                             ? "正在刷新整个扫描范围 · 当前显示上次结果"
                             : "边扫描边显示 · 当前结果尚未完整")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("live-scan-indicator")
                }
                if let pendingMessage = model.hiddenOmittedMessage {
                    Text(pendingMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityIdentifier("hidden-omitted-message")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if showsInfo, let item = model.selectedItem {
                infoPanel(item: item)
                    .padding(12)
            }
        }
    }

    /// Loading / empty / zero / stale-scene explanation. Only shown when there
    /// is a root and no live scan overlay would duplicate it.
    @ViewBuilder
    private var stateExplanation: some View {
        if model.hasRoot,
           !model.presentationState.isBusy,
           let text = model.presentationState.explanation,
           model.selectedItem == nil {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    if model.presentationState == .loading {
                        ProgressView().controlSize(.small)
                    }
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if model.isSceneStale {
                    Text("当前显示的是上一位置的地图，新位置仍在读取。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 8) {
                    if model.presentationState == .sceneError || model.sceneError != nil {
                        Button("重试读取") { model.retrySceneLoad() }
                            .accessibilityIdentifier("scene-retry")
                    }
                    if model.presentationState == .zeroAllocation {
                        Button("查看项目") { showsProjectList = true }
                            .accessibilityIdentifier("zero-projects")
                    }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(24)
            .accessibilityIdentifier("presentation-explanation")
        }
    }

    // MARK: Project list

    /// Bounded list of the current focus page, including zero-weight items that
    /// cannot be reached on the map. It is a popover, never a side bar, and it
    /// uses the already-loaded snapshot page.
    private var projectList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("当前范围项目")
                    .font(.headline)
                Spacer()
                Text("最多 \(model.focusPageLimit) 项")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let items = model.treemapScene?.focusPage.items, !items.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(items, id: \.nodeID) { item in
                            Button {
                                selectFromList(item)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: iconName(for: item.kind))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 14)
                                    Text(item.name.isEmpty ? "—" : item.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    if let bytes = model.listEffectiveBytes(for: item) {
                                        if item.isDirectoryLike, bytes == 0 {
                                            Text("0 占用")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                        Text(ByteFormatting.bytes(bytes))
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    } else {
                                        // Unknown directory aggregate: never claim a
                                        // deterministic 0.
                                        Text("—")
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                        Text(model.progressWording.pendingAggregateLabel)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(kindLabel(for: item.kind))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(item.name)
                        }
                    }
                }
                .frame(maxHeight: 320)
            } else {
                Text("此范围没有已加载的项目")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 360)
        .accessibilityIdentifier("project-list-popover")
    }

    private func selectFromList(_ item: TreemapSceneItem) {
        model.selectNode(item.nodeID)
        showsProjectList = false
        showsInfo = true
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("选择文件夹或磁盘开始")
                .font(.title3.weight(.medium))
            Button {
                Task { await model.chooseRoot() }
            } label: {
                Label("选择文件夹或磁盘", systemImage: "folder")
            }
            .controlSize(.large)
            Text("SpaceJudge 只读取文件元数据，不删除、不移动、不读取内容。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var treemapContent: TreemapViewRepresentable.Content {
        TreemapViewRepresentable.Content(
            scene: model.treemapScene,
            detailMode: model.detailMode,
            selectedIdentity: selectedIdentity,
            appearance: colorScheme == .dark ? .dark : .light,
            scanGeneration: model.sceneGeneration,
            expansionVersion: model.expansionVersion,
            accessibilityValue: accessibilityValue,
            isTerminal: model.isTerminal
        )
    }

    private var selectedIdentity: TreemapRenderTile.Identity? {
        if let other = model.selectedOther {
            return .other(parent: other.parentID)
        }
        if let nodeID = model.selectedNodeID {
            return .node(nodeID)
        }
        return nil
    }

    private var accessibilityValue: String {
        let focus = model.breadcrumbs.last?.name ?? model.rootDisplayName ?? "未选择"
        let count = model.visibleItemCount
        return "当前目录 \(focus)，可见 \(count) 项，\(model.presentationState.title)"
    }

    private var treemapActions: TreemapCanvasActions {
        TreemapCanvasActions(
            select: { tile in applySelection(tile) },
            singleClick: { tile in
                guard !model.isSceneStale else { return }
                applySelection(tile)
                // Single click expands a collapsed directory only. An already
                // preview-expanded directory is left untouched so a double
                // click to enter can never be stolen by a re-layout.
                guard let nodeID = tile.identity.nodeID,
                      let kind = tile.kind, kind.isDirectoryLike, !tile.isExpanded else { return }
                model.expand(nodeID)
            },
            doubleClick: { tile in
                guard !model.isSceneStale else { return }
                guard let nodeID = tile.identity.nodeID else { return }
                if let kind = tile.kind, kind.isDirectoryLike {
                    Task { await model.enter(nodeID) }
                } else {
                    model.selectNode(nodeID)
                    showsInfo = true
                }
            },
            enterDirectory: { tile in
                guard !model.isSceneStale else { return }
                guard let nodeID = tile.identity.nodeID,
                      let kind = tile.kind, kind.isDirectoryLike else { return }
                Task { await model.enter(nodeID) }
            },
            expand: { tile in
                guard !model.isSceneStale else { return }
                guard let nodeID = tile.identity.nodeID else { return }
                model.expand(nodeID)
            },
            collapse: { tile in
                guard !model.isSceneStale else { return }
                guard let nodeID = tile.identity.nodeID else { return }
                model.collapse(nodeID)
            },
            showInfo: { tile in
                guard !model.isSceneStale else { return }
                guard let nodeID = tile.identity.nodeID else { return }
                model.selectNode(nodeID)
                showsInfo = true
            },
            reveal: { tile in
                guard !model.isSceneStale else { return }
                guard let nodeID = tile.identity.nodeID else { return }
                model.selectNode(nodeID)
                Task { await revealSelection() }
            },
            analyze: { tile in
                guard model.canAnalyzeWithAgent, let node = tile.identity.nodeID, !tile.isOther else { return }
                model.selectNode(node)
                analysisNodeID = node; analysisSnapshot = nil; cleanupContext = nil; codexDraft = nil
                includesTargetPath = true
                handoffStatus = "正在准备扫描摘要…"
                showsAgentAnalysis = true
            },
            canAnalyze: { tile in model.canAnalyzeWithAgent && tile.identity.nodeID != nil && !tile.isOther },
            keyboardEnter: { tile, command in
                guard !model.isSceneStale else { return }
                guard let nodeID = tile.identity.nodeID,
                      let kind = tile.kind, kind.isDirectoryLike else { return }
                if command {
                    Task { await model.enter(nodeID) }
                } else if !tile.isExpanded {
                    model.expand(nodeID)
                } else {
                    model.collapse(nodeID)
                }
            },
            escape: {
                model.clearSelection()
                showsInfo = false
            }
        )
    }

    /// Routes a canvas selection to the model, including synthetic `other`
    /// tiles that have no node identity and therefore no Finder/enter action.
    /// A stale old map never produces a new selection.
    private func applySelection(_ tile: TreemapRenderTile) {
        guard !model.isSceneStale else { return }
        if tile.isOther {
            model.selectOther(
                parentID: tile.parentID,
                collapsedCount: tile.collapsedCount,
                effectiveBytes: tile.effectiveBytes
            )
        } else if let nodeID = tile.identity.nodeID {
            model.selectNode(nodeID)
        }
    }

    // MARK: Selection summary

    /// Synthetic "other" tile summary: count and known weight only, with no
    /// Finder or enter action.
    private func otherSelectionSummary(_ other: TreemapOtherSelection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.down.right")
                .foregroundStyle(.secondary)
            Text("其他（\(other.collapsedCount) 项）")
                .lineLimit(1)
            Text(ByteFormatting.bytes(other.effectiveBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("合计占用")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("其他 \(other.collapsedCount) 项，合计 \(ByteFormatting.bytes(other.effectiveBytes))")
    }

    private func selectionSummary(item: TreemapSceneItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: item.kind))
                .foregroundStyle(.secondary)
            Text(item.name.isEmpty ? "—" : item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(ByteFormatting.bytes(model.selectedEffectiveBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if item.isDirectoryLike, model.selectedAggregate == nil {
                Text(model.progressWording.pendingAggregateLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(kindLabel(for: item.kind))
                .font(.caption)
                .foregroundStyle(.tertiary)
            if item.isDirectoryLike, model.isExpanded(item.nodeID) {
                Button("折叠") { model.collapse(item.nodeID) }
            } else if item.isDirectoryLike {
                Button("展开") { model.expand(item.nodeID) }
            }
            if item.isDirectoryLike {
                Button("进入") { Task { await model.enter(item.nodeID) } }
            }
            Button("在 Finder 中显示") { Task { await revealSelection() } }
            Button("信息") { showsInfo.toggle() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "已选择 \(item.name)，\(ByteFormatting.bytes(model.selectedEffectiveBytes))，\(kindLabel(for: item.kind))"
        )
    }

    // MARK: Info panel

    private func infoPanel(item: TreemapSceneItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // The title takes the remaining bounded width and truncates in the
            // middle; the close button keeps a fixed, always-visible hit area
            // and a higher layout priority so a very long name can never push
            // it out of the panel.
            HStack(spacing: 8) {
                Text(item.name.isEmpty ? "—" : item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(0)
                Button {
                    showsInfo = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .layoutPriority(1)
                .help("关闭信息")
                .accessibilityLabel("关闭信息")
                .accessibilityIdentifier("info-close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("类型", kindLabel(for: item.kind))
                    if let path = model.selectedRelativePath {
                        infoRow("相对路径", path, wraps: true)
                    }
                    infoRow("有效占用", ByteFormatting.bytes(model.selectedEffectiveBytes))
                    if item.kind == .regularFile {
                        infoRow("逻辑大小", ByteFormatting.bytes(item.logicalBytes))
                        infoRow("已分配", ByteFormatting.bytes(item.allocatedBytes))
                    }
                    if let aggregate = model.selectedAggregate {
                        infoRow("聚合逻辑", ByteFormatting.bytes(aggregate.logicalBytes))
                        infoRow("聚合分配", ByteFormatting.bytes(aggregate.allocatedBytes))
                        infoRow("统计", model.progressWording.aggregateStatusText(isComplete: aggregate.isComplete))
                    } else if item.isDirectoryLike {
                        infoRow("聚合统计", model.progressWording.pendingAggregateLabel)
                    }
                    if let modified = item.modifiedAt {
                        infoRow("修改时间", Self.dateFormatter.string(from: modified))
                    }
                    let flags = flagDescriptions(item.flags)
                    if !flags.isEmpty {
                        infoRow("标记", flags.joined(separator: "、"), wraps: true)
                    }
                    if let error = model.revealError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 260)
            HStack(spacing: 8) {
                if item.isDirectoryLike {
                    Button("进入") { Task { await model.enter(item.nodeID) } }
                }
                Button("在 Finder 中显示") { Task { await revealSelection() } }
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private func infoRow(_ label: String, _ value: String, wraps: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(wraps ? 4 : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: Status strip

    private var statusStrip: some View {
        HStack(spacing: 10) {
            capacityStrip
            // Current focus size only. The whole-scan root reconciliation is
            // long and lives in the strip's tooltip, so it can never be misread
            // as the current map's size or squeeze the numbers at 736 pt.
            Text(model.focusSizeLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("focus-size-line")
            if model.isSceneStale {
                Text("（上一位置）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            if let message = model.refreshMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(message)
                    .accessibilityIdentifier("refresh-result")
            }
            if model.issueCount > 0 {
                Text("\(model.issueCount) 个问题")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("扫描期间部分目录无法读取或发生变化")
            }
            if model.showsPermissionHelp {
                Button {
                    openPrivacySettings()
                } label: {
                    Label("完全磁盘访问…", systemImage: "lock.shield")
                        .font(.caption2)
                }
                .help("在系统设置中授予完全磁盘访问权限后重试")
                .accessibilityIdentifier("permission-help")
            }
            if let userError = model.userError {
                errorChip(
                    userError.message,
                    dismiss: { model.dismissUserError() },
                    retry: { Task { await model.rescan() } }
                )
            }
            if let error = model.revealError {
                errorChip(error, dismiss: { model.dismissRevealError() })
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func errorChip(
        _ message: String,
        dismiss: (() -> Void)? = nil,
        retry: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(message)
                .accessibilityIdentifier("scan-error")
            if let retry {
                Button("重试", action: retry)
                    .font(.caption2)
                    .disabled(!model.canRescan)
                    .accessibilityIdentifier("scan-error-retry")
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
    }

    /// Compact capacity strip: a small used bar plus text and a source tooltip.
    /// Attribution reconciliation is deliberately kept out of this row so the
    /// numbers never get squeezed out at the minimum width.
    private var capacityStrip: some View {
        let presentation = model.capacityPresentation
        return HStack(spacing: 6) {
            Text("容量")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let fraction = presentation.usedFraction {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(2, 84 * fraction))
                }
                .frame(width: 84, height: 5)
                .accessibilityHidden(true)
            }
            Text(presentation.line)
                .font(.caption)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityIdentifier("capacity-line")
        }
        // The long root reconciliation and the provenance label live in the
        // tooltip; the visible strip keeps the compact total/used/remaining.
        .help(capacityHelp(presentation))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(capacityHelp(presentation))
    }

    private func capacityHelp(_ presentation: CapacityPresentation) -> String {
        var parts = [presentation.accessibilityLabel, model.focusSizeLine]
        if let scanScope = model.scanScopeReconciliationLine {
            parts.append(scanScope)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Diagnostics (Debug only)

#if DEBUG
    private var diagnosticsShortcut: some View {
        Button("") {
            showsDiagnostics.toggle()
        }
        .keyboardShortcut("d", modifiers: [.command, .option])
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var diagnosticsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.largestItemsCaption)
                    .font(.headline)
                Spacer()
                Button("关闭") { showsDiagnostics = false }
            }
            if let page = model.childPage, !page.items.isEmpty {
                List(page.items, id: \.node.id) { item in
                    HStack {
                        Text(item.name.decodedString ?? String(decoding: item.name.utf8, as: UTF8.self))
                            .lineLimit(1)
                        Spacer()
                        Text(ByteFormatting.bytes(item.effectiveAttributedBytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(kindLabel(for: item.node.kind))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("暂无诊断数据")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 520, height: 420)
    }
#endif

    // MARK: Actions

    private func revealSelection() async {
        if let url = await model.finderURLForSelection() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        openURL(url)
    }

    // MARK: Presentation helpers

    private func kindLabel(for kind: NodeKind) -> String {
        switch kind {
        case .directory: return "目录"
        case .mountPoint: return "宗卷"
        case .regularFile: return "文件"
        case .symbolicLink: return "链接"
        case .socket, .fifo, .characterDevice, .blockDevice: return "特殊"
        case .unknown: return "未知"
        }
    }

    private func iconName(for kind: NodeKind) -> String {
        switch kind {
        case .directory: return "folder"
        case .mountPoint: return "externaldrive"
        case .regularFile: return "doc"
        case .symbolicLink: return "link"
        case .socket, .fifo, .characterDevice, .blockDevice: return "gearshape"
        case .unknown: return "questionmark.square"
        }
    }

    private func flagDescriptions(_ flags: NodeFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.package) { result.append("包") }
        if flags.contains(.duplicateHardLink) { result.append("硬链接重复") }
        if flags.contains(.inaccessible) { result.append("不可访问") }
        if flags.contains(.mountBoundary) { result.append("未跨越挂载点") }
        if flags.contains(.sparse) { result.append("稀疏文件") }
        if flags.contains(.changedDuringScan) { result.append("扫描中发生变化") }
        if flags.contains(.symlinkLoop) { result.append("符号链接循环") }
        if flags.contains(.clonedAllocation) { result.append("可能为克隆分配") }
        if flags.contains(.fallbackEnumerator) { result.append("使用了回退枚举") }
        return result
    }
}
