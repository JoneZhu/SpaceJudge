import Foundation
import Observation

/// Owns one opt-in, single-turn agent process. No shell command interpolation.
@MainActor @Observable
public final class AgentAnalysisController {
    public private(set) var snapshot: AgentAnalysisSnapshot?
    public private(set) var output = ""
    public private(set) var status = "准备中…"
    public private(set) var isBusy = false
    public private(set) var succeeded = false
    public var runtimePath: String
    public var nodePath: String
    private var process: Process?
    private var input: Pipe?
    private var jobDirectory: URL?
    private var generation = UUID()
    private var cancelled = false

    public init() {
        let defaults = UserDefaults.standard
        let bundled = Self.bundledLocations(resources: Bundle.main.resourceURL)
        runtimePath = bundled?.runtime
            ?? defaults.string(forKey: "agentRuntimePath")
            ?? ProcessInfo.processInfo.environment["SPACEJUDGE_AGENT_RUNTIME"] ?? ""
        nodePath = bundled?.node ?? defaults.string(forKey: "agentNodePath") ?? Self.findNode() ?? ""
    }

    /// Production installations use sealed bundle resources before a stale
    /// development path. Explicit manual changes still work for this session.
    static func bundledLocations(resources: URL?) -> (runtime: String, node: String)? {
        guard let resources else { return nil }
        let runtime = resources.appendingPathComponent("AgentRuntime", isDirectory: true)
        let node = runtime.appendingPathComponent("bin/node")
        guard FileManager.default.fileExists(atPath: runtime.appendingPathComponent("dist/agent-bridge.js").path),
              FileManager.default.isExecutableFile(atPath: node.path) else { return nil }
        return (runtime.path, node.path)
    }

    public var usesBundledRuntime: Bool {
        guard let bundled = Self.bundledLocations(resources: Bundle.main.resourceURL) else { return false }
        return runtimePath == bundled.runtime && nodePath == bundled.node
    }

    public var stateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpaceJudgeAgent", isDirectory: true)
    }

    public func prepare(model: AppModel) async {
        guard !isBusy else { return }
        snapshot = nil; output = ""; succeeded = false; status = "正在固定当前目录快照…"
        do {
            snapshot = try await model.captureAgentAnalysis()
            status = "就绪 · 尚未向 Codex 发送数据"
        } catch { status = "快照不可用，请等待扫描/刷新结束后重新打开分析。" }
    }

    public var loginArguments: [String] {
        [URL(fileURLWithPath: runtimePath).appendingPathComponent("dist/agent-bridge.js").path,
         "--login", "--state-dir", stateDirectory.path]
    }

    public func start() {
        guard !isBusy, let snapshot else { return }
        let entry = URL(fileURLWithPath: runtimePath).appendingPathComponent("dist/agent-bridge.js")
        guard runtimePath.hasPrefix("/"), nodePath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: nodePath),
              FileManager.default.fileExists(atPath: entry.path) else {
            status = "请选择已构建的 AgentMCP 运行目录和 Node 可执行文件。"; return
        }
        UserDefaults.standard.set(runtimePath, forKey: "agentRuntimePath")
        UserDefaults.standard.set(nodePath, forKey: "agentNodePath")
        generation = UUID(); let token = generation
        output = ""; cancelled = false; succeeded = false
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("spacejudge-ui-analysis-\(token.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            jobDirectory = directory
            let report = directory.appendingPathComponent("report.json")
            try JSONEncoder().encode(snapshot).write(to: report, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: report.path)
            let process = Process(); let pipe = Pipe(); let errors = Pipe(); let input = Pipe()
            process.executableURL = URL(fileURLWithPath: nodePath)
            process.arguments = [entry.path, "--report", report.path, "--state-dir", stateDirectory.path]
            process.currentDirectoryURL = directory
            process.standardOutput = pipe; process.standardError = errors; process.standardInput = input
            let parser = AgentOutputParser { [weak self] event in
                Task { @MainActor in
                    guard let self, self.generation == token, self.isBusy, !self.cancelled else { return }
                    switch event.type {
                    case "delta": self.output += event.text ?? ""
                    case "status", "error": self.status = event.text ?? "分析未完成"
                    case "done": break
                    default: self.cancel()
                    }
                }
            }
            let drains = DispatchGroup()
            drains.enter(); drains.enter()
            process.terminationHandler = { [weak self] finished in
                drains.notify(queue: .main) {
                  Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.isBusy = false; self.process = nil; self.input = nil
                    let final = parser.finalResult
                    self.output = final.output
                    self.succeeded = finished.terminationStatus == 0 && final.done && !self.cancelled
                    if self.cancelled { self.status = "已取消 · 未执行清理" }
                    else if self.succeeded { self.status = "分析完成 · 结果属于上方固定快照" }
                    else { self.status = "分析未完成。请检查专用 Codex 登录与运行配置。未执行清理。" }
                    self.cleanupReport()
                  }
                }
            }
            self.process = process; self.input = input; isBusy = true; status = "正在启动 Codex…"
            try process.run()
            DispatchQueue.global(qos: .utility).async {
                defer { drains.leave() }
                while let data = try? pipe.fileHandleForReading.read(upToCount: 8192), !data.isEmpty {
                    parser.consume(data)
                }
                parser.consume(Data())
                try? pipe.fileHandleForReading.close()
            }
            DispatchQueue.global(qos: .utility).async {
                defer { drains.leave() }
                while let data = try? errors.fileHandleForReading.read(upToCount: 8192), !data.isEmpty {}
                try? errors.fileHandleForReading.close()
            }
        } catch {
            isBusy = false; process = nil; input = nil; cleanupReport()
            status = "无法启动 Agent。请检查运行目录和 Node。"
        }
    }

    public func cancel() {
        guard isBusy, let process else { return }
        cancelled = true; status = "正在取消…"
        process.terminate() // Bridge denies approvals, cancels ACP, reaps its process group.
    }

    private func cleanupReport() {
        if let directory = jobDirectory { try? FileManager.default.removeItem(at: directory) }
        jobDirectory = nil
    }

    private static func findNode() -> String? {
        let fm = FileManager.default
        let standard = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        if let node = standard.first(where: { fm.isExecutableFile(atPath: $0) }) { return node }
        let nvm = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        let versions = (try? fm.contentsOfDirectory(atPath: nvm.path)) ?? []
        return versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nvm.appendingPathComponent("\($0)/bin/node").path }
            .first { fm.isExecutableFile(atPath: $0) }
    }
}

/// Drain continuously with a hard cap; output is plain text, never evaluated Markdown/HTML.
struct AgentOutputEvent: Decodable, Sendable { let type: String; let text: String? }
final class AgentOutputParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var total = 0
    private var failed = false
    private var output = ""
    private var done = false
    private let emit: @Sendable (AgentOutputEvent) -> Void
    init(emit: @escaping @Sendable (AgentOutputEvent) -> Void) { self.emit = emit }
    func consume(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { return }
        total += data.count
        guard total <= 1_000_000, buffer.count + data.count <= 1_000_000 else { fail(); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard line.count <= 128_000,
                  let event = try? JSONDecoder().decode(AgentOutputEvent.self, from: line),
                  ["delta", "status", "error", "done"].contains(event.type),
                  !done, event.type == "done" || event.text != nil else { fail(); return }
            emit(event)
            if event.type == "delta" { output += event.text ?? "" }
            if event.type == "done" { done = true }
        }
        if buffer.count > 128_000 || (data.isEmpty && !buffer.isEmpty) { fail() }
    }
    private func fail() { failed = true; buffer.removeAll(); emit(AgentOutputEvent(type: "invalid", text: nil)) }
    var finalResult: (output: String, done: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (output, done && !failed)
    }
}
