import AppKit
import SpaceJudgeAppSupport
import SpaceJudgeDomain
import SpaceJudgeTreemap
import SpaceJudgeTreemapUI
import SwiftUI

/// Phase 4 shell: compact toolbar, native treemap surface, hover/selection
/// overlay and a small capacity footer.
struct ContentView: View {
    let model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsInfo = false
    @State private var showsDiagnostics = false

    private let accent = Color(red: 0.20, green: 0.66, blue: 0.42)

    var body: some View {
        // The treemap is the main content; the toolbar and footer are
        // safe-area insets so they always render above the AppKit canvas.
        treemapArea
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    toolBar
                    Divider()
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    footer
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .frame(minWidth: 900, minHeight: 640)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .topTrailing) {
                if showsInfo, let item = model.selectedItem {
                    infoPanel(item: item)
                        .padding(12)
                }
            }
            // A new scan/root invalidates any local panel state so an old
            // reveal error or info panel cannot survive into the new scan.
            .onChange(of: model.scanID) { _, _ in
                showsInfo = false
            }
#if DEBUG
            .background(diagnosticsShortcut)
            .sheet(isPresented: $showsDiagnostics) {
                diagnosticsList
            }
#endif
    }

    // MARK: Toolbar

    private var toolBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.chooseRoot() }
            } label: {
                Label("选择位置", systemImage: "folder")
            }
            .disabled(model.phase == .choosingRoot)
            .accessibilityIdentifier("choose-root")

            Button {
                Task { await model.goBack() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .help("后退")
            .accessibilityIdentifier("go-back")

            Button {
                Task { await model.goUp() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(!model.canGoUp)
            .help("上一级")
            .accessibilityIdentifier("go-up")

            breadcrumbs

            Spacer(minLength: 8)

            if model.isScanning {
                ProgressView().controlSize(.small)
            }
            Text(model.phase.statusText)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .accessibilityIdentifier("scan-status")

            Button {
                Task { await model.rescan() }
            } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }
            .disabled(!model.hasRoot || model.isScanning)
            .accessibilityIdentifier("rescan")

            Button {
                Task { await model.cancelScan() }
            } label: {
                Label("取消", systemImage: "stop.circle")
            }
            .disabled(!model.isScanning)
            .accessibilityIdentifier("cancel-scan")

            Picker("详细程度", selection: detailModeBinding) {
                Text("概览").tag(TreemapDetailMode.overview)
                Text("详细").tag(TreemapDetailMode.detail)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .labelsHidden()
            .accessibilityIdentifier("detail-mode")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var detailModeBinding: Binding<TreemapDetailMode> {
        Binding(
            get: { model.detailMode },
            set: { model.setDetailMode($0) }
        )
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
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == model.breadcrumbs.count - 1 ? .primary : .secondary)
                }
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
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
            } else {
                emptyState
            }

            if model.hasRoot, let scene = model.treemapScene,
               scene.focusPage.items.isEmpty, !model.isScanning {
                Text("此位置没有可直接显示的子项目")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack {
                Spacer()
                if let item = model.selectedItem {
                    selectionSummary(item: item)
                        .padding(.bottom, 10)
                } else if let other = model.selectedOther {
                    otherSelectionSummary(other)
                        .padding(.bottom, 10)
                }
                if let error = model.sceneError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
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
        return "当前目录 \(focus)，可见 \(count) 项，\(model.phase.statusText)"
    }

    private var treemapActions: TreemapCanvasActions {
        TreemapCanvasActions(
            select: { tile in applySelection(tile) },
            singleClick: { tile in
                applySelection(tile)
                guard let nodeID = tile.identity.nodeID,
                      let kind = tile.kind, kind.isDirectoryLike, !tile.isExpanded else { return }
                model.expand(nodeID)
            },
            doubleClick: { tile in
                guard let nodeID = tile.identity.nodeID else { return }
                if let kind = tile.kind, kind.isDirectoryLike {
                    Task { await model.enter(nodeID) }
                } else {
                    model.selectNode(nodeID)
                    showsInfo = true
                }
            },
            enterDirectory: { tile in
                guard let nodeID = tile.identity.nodeID,
                      let kind = tile.kind, kind.isDirectoryLike else { return }
                Task { await model.enter(nodeID) }
            },
            expand: { tile in
                guard let nodeID = tile.identity.nodeID else { return }
                model.expand(nodeID)
            },
            showInfo: { tile in
                guard let nodeID = tile.identity.nodeID else { return }
                model.selectNode(nodeID)
                showsInfo = true
            },
            reveal: { tile in
                guard let nodeID = tile.identity.nodeID else { return }
                model.selectNode(nodeID)
                Task { await revealSelection() }
            },
            keyboardEnter: { tile, command in
                guard let nodeID = tile.identity.nodeID,
                      let kind = tile.kind, kind.isDirectoryLike else { return }
                if command {
                    Task { await model.enter(nodeID) }
                } else {
                    model.expand(nodeID)
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
    private func applySelection(_ tile: TreemapRenderTile) {
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
            Text(ByteFormatting.bytes(item.effectiveBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(kindLabel(for: item.kind))
                .font(.caption)
                .foregroundStyle(.tertiary)
            if item.isDirectoryLike, !model.expandedNodeIDs.contains(item.nodeID) {
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
            "已选择 \(item.name)，\(ByteFormatting.bytes(item.effectiveBytes))，\(kindLabel(for: item.kind))"
        )
    }

    // MARK: Info panel

    private func infoPanel(item: TreemapSceneItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name.isEmpty ? "—" : item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    showsInfo = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭信息")
            }
            infoRow("类型", kindLabel(for: item.kind))
            infoRow("相对路径", model.selectedRelativePath ?? "—")
            infoRow("有效占用", ByteFormatting.bytes(item.effectiveBytes))
            if item.kind == .regularFile {
                infoRow("逻辑大小", ByteFormatting.bytes(item.logicalBytes))
                infoRow("已分配", ByteFormatting.bytes(item.allocatedBytes))
            }
            if let aggregate = model.selectedAggregate {
                infoRow("聚合逻辑", ByteFormatting.bytes(aggregate.logicalBytes))
                infoRow("聚合分配", ByteFormatting.bytes(aggregate.allocatedBytes))
                infoRow("统计", aggregate.isComplete ? "已完成" : "正在统计")
            } else if item.isDirectoryLike {
                infoRow("聚合统计", "正在统计")
            }
            if let modified = item.modifiedAt {
                infoRow("修改时间", Self.dateFormatter.string(from: modified))
            }
            let flags = flagDescriptions(item.flags)
            if !flags.isEmpty {
                infoRow("标记", flags.joined(separator: "、"))
            }
            if let error = model.revealError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if item.isDirectoryLike {
                    Button("进入") { Task { await model.enter(item.nodeID) } }
                }
                Button("在 Finder 中显示") { Task { await revealSelection() } }
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            legend
            Text(model.capacityLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("capacity-line")
            if let attribution = model.attributionLine {
                Text(attribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("scan-attribution-line")
            }
            Spacer()
            if model.issueCount > 0 {
                Text("\(model.issueCount) 个问题")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.showsPermissionHelp {
                Button {
                    openPrivacySettings()
                } label: {
                    Label("打开隐私与安全性设置…", systemImage: "lock.shield")
                        .font(.caption)
                }
                .accessibilityIdentifier("permission-help")
            }
            if let userError = model.userError {
                Text(userError.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(userError.message)
                    .accessibilityIdentifier("scan-error")
            }
            if let error = model.revealError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reveal-error")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Text("图例")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(0..<TreemapPalette.base.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(for: index))
                    .frame(width: 12, height: 8)
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(colorScheme == .dark
                    ? Color(nsColor: NSColor(srgbRed: 0.30, green: 0.30, blue: 0.33, alpha: 1))
                    : Color(nsColor: NSColor(srgbRed: 0.70, green: 0.70, blue: 0.72, alpha: 1)))
                .frame(width: 12, height: 8)
            Text("其他")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("颜色仅用于区分目录")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func color(for index: Int) -> Color {
        let colors = colorScheme == .dark ? TreemapPalette.baseDark : TreemapPalette.base
        let value = colors[index % colors.count]
        return Color(nsColor: value.nsColor)
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
