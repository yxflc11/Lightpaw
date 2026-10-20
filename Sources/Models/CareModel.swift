import AppKit
import Combine
import Foundation
import OSLog

enum ApplicationFilter: String, CaseIterable {
    case all = "全部", homebrew = "Homebrew", updates = "可更新"
}

enum CleanupScanState: Equatable {
    case idle, running, ready(Int), cancelled, failed
}

final class CareModel: ObservableObject {
    private let lifecycleLog = Logger(subsystem: "local.codex.memorywatch", category: "Lifecycle")
    @Published var page: CarePage = .overview
    @Published var mainWindowVisible = true
    @Published var popoverVisible = false
    @Published var latest: Reading?
    @Published var memoryPoints: [Double?] = []
    @Published var memoryEvents: [String] = []
    @Published var monitorLogError: String?
    @Published var moleVersion = "检测中"
    @Published var system: [String: Any] = [:]
    @Published var systemError = ""
    @Published var systemRefreshing = false
    @Published var systemUpdatedAt: Date?
    @Published var diskPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var diskEntries: [DiskEntry] = []
    @Published var diskTotal: Double?
    @Published var diskFileCount: Double?
    @Published var diskStatus = "尚未扫描"
    @Published var selectedDisk: String?
    @Published var apps: [MoleApplication] = []
    @Published var selectedApp: String?
    @Published var appSearch = ""
    @Published var brewSourcesVerified = false
    @Published var applicationFilter: ApplicationFilter = .all
    @Published var brewSnapshot: BrewUpdateSnapshot?
    @Published var brewCatalogLoaded = false
    @Published var brewCatalogError = ""
    @Published var brewCheckValid = false
    @Published var selectedBrewToken: String?
    @Published var pendingBrewUpdate: BrewUpdatePlan?
    @Published var cleanEntries: [CleanupEntry] = []
    @Published var selectedCleanIDs: Set<Int> = []
    @Published var cleanSearch = ""
    @Published var permanentCleanup = false
    @Published var cleanPreview = ""
    @Published private(set) var cleanupScanState: CleanupScanState = .idle
    @Published var optimizePreview = ""
    @Published var sessions: [[String: Any]] = []
    @Published var jobBusy = false
    @Published var jobTitle = ""
    @Published var jobPhase = ""
    @Published var jobText = ""
    @Published var jobFailed = false
    @Published var uninstallReview: String?
    @Published var uninstallScriptAcknowledged = false
    @Published var pendingApp: MoleApplication?
    @Published var showDetails = false
    @Published var showProtection = false
    @Published var protectionText = ""
    let toolManager = CodexToolsModel()
    private let sampler = Sampler()
    private let sampleQueue = DispatchQueue(label: "MacCare.memory", qos: .utility)
    private var sampleTimer: DispatchSourceTimer?
    private var statusTimer: Timer?
    private var logStore: LogStore?
    private let statusBridge = MoleBridge()
    private let operationBridge = MoleBridge()
    private let selectedCleanup = SelectedCleanup()
    private let brewService = BrewService()
    private let brewUpdates = BrewUpdates()
    private var brewUpdateOperation = false
    private var pendingBrewPlan: BrewUninstallPlan?
    private var brewOperation = false
    private var brewCancellationRequested = false
    private let cleanupQueue = DispatchQueue(label: "MacCare.selection", qos: .utility)
    private let localHistory = LocalHistory()
    private var preparingSelection = false
    private var selectionGeneration = UUID()
    private var protocolState: UninstallProtocol?
    private var pendingIdentity: BundleIdentity?
    private var previewDate: [String: Date] = [:]
    private var previewRules: [String: String] = [:]
    private var runID = UUID()
    private var isStopping = false
    var onMemoryUpdate: ((Reading) -> Void)?
    var onAllOperationsStopped: (() -> Void)?
    var mutationSupported: Bool { moleVersion == "1.61.0" }
    var uninstallScriptRequired: Bool { pendingBrewPlan?.scriptReviewRequired == true }
    var uninstallScriptSource: String? { pendingBrewPlan?.scriptReviewSource }
    var uninstallCanExecute: Bool {
        pendingApp?.isManaged == true
            ? pendingBrewPlan?.canExecute == true && (!uninstallScriptRequired || uninstallScriptAcknowledged)
            : uninstallReview != nil
    }
    var chosenApp: MoleApplication? { apps.first { $0.id == selectedApp } }
    var filteredApps: [MoleApplication] {
        apps.filter { appSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(appSearch) || $0.bundleID.localizedCaseInsensitiveContains(appSearch) }
    }
    var chosenBrewApp: BrewUpdateItem? { filteredBrewApps.first { $0.token == selectedBrewToken } }
    var filteredBrewApps: [BrewUpdateItem] {
        (brewSnapshot?.items ?? []).filter {
            (applicationFilter != .updates || $0.hasUpdate) &&
            (appSearch.isEmpty || ($0.name + " " + $0.token).localizedCaseInsensitiveContains(appSearch))
        }
    }
    var brewResultsFresh: Bool { brewCheckValid && brewSnapshot?.isFresh == true }
    var brewStatusText: String {
        if !brewCatalogError.isEmpty { return brewCatalogError }
        guard let snapshot = brewSnapshot else { return "从 Homebrew 安装的应用会显示在这里" }
        if let date = snapshot.metadataRefreshedAt {
            let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            return "已安装 \(snapshot.items.count) 项 · \(time) 检查" + (brewResultsFresh ? "" : " · 需重新检查")
        }
        return "已安装 \(snapshot.items.count) 项 · 尚未检查新版本"
    }
    var selectedDiskEntry: DiskEntry? { diskEntries.first { $0.id == selectedDisk } }
    var logsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CodexMemoryWatch") }
    var healthScore: Int? {
        guard let value = number(system["health_score"]), (0...100).contains(value), value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
    var healthTitle: String {
        guard let score = healthScore else { return "暂不可用" }
        let message = safeString(system["health_score_msg"])
        if message.contains(":") { return score < 45 ? "需要处理" : "需要留意" }
        switch score {
        case 85...100: return "状态良好"
        case 65..<85: return "状态平稳"
        case 45..<65: return "需要留意"
        default: return "需要处理"
        }
    }
    var systemIsStale: Bool {
        guard let updated = systemUpdatedAt else { return true }
        return Date().timeIntervalSince(updated) > 60
    }
    private var systemStatusVisible: Bool { popoverVisible || (mainWindowVisible && page == .overview) }

    func cleanupRestriction(_ entry: CleanupEntry) -> String? { selectedCleanup.restriction(path: entry.path) }
    func toggleCleanSelection(_ entry: CleanupEntry) {
        guard !jobBusy, cleanupRestriction(entry) == nil else { return }
        setCleanSelection([entry], selected: !selectedCleanIDs.contains(entry.id))
    }
    private func setCleanSelection(_ entries: [CleanupEntry], selected: Bool) {
        for entry in entries {
            for row in cleanEntries {
                let sameOrDescendant = row.path == entry.path || row.path.hasPrefix(entry.path + "/")
                if selected {
                    if sameOrDescendant && cleanupRestriction(row) == nil { selectedCleanIDs.insert(row.id) }
                } else if sameOrDescendant || entry.path.hasPrefix(row.path + "/") {
                    selectedCleanIDs.remove(row.id)
                }
            }
        }
    }
    func selectAllClean(_ selected: Bool) {
        guard !jobBusy else { return }
        let rows = cleanEntries.filter {
            (cleanSearch.isEmpty || ($0.path + " " + $0.section).localizedCaseInsensitiveContains(cleanSearch)) && cleanupRestriction($0) == nil
        }
        setCleanSelection(rows, selected: selected)
    }
    var cleanSelectionSummary: String {
        let selected = cleanEntries.filter { selectedCleanIDs.contains($0.id) }
        let roots = selected.filter { row in !selected.contains { $0.id != row.id && row.path.hasPrefix($0.path + "/") } }
        guard !roots.isEmpty else { return "未选择项目" }
        let sizes = roots.compactMap { Self.previewBytes($0.detail) }
        return "已选 \(roots.count) 项" + (sizes.count == roots.count ? " · 约 " + bytesText(sizes.reduce(0,+)) : " · 部分大小未知")
    }
    private static func previewBytes(_ text: String) -> Double? {
        guard let range = text.range(of: #"^[0-9]+(?:\.[0-9]+)?\s*(?:GB|MB|KB|B)"#, options: .regularExpression) else { return nil }
        let value = String(text[range]).replacingOccurrences(of: " ", with: "")
        for (unit, factor) in [("GB", 1073741824.0), ("MB", 1048576.0), ("KB", 1024.0), ("B", 1.0)] where value.hasSuffix(unit) {
            return Double(value.dropLast(unit.count)).map { $0 * factor }
        }
        return nil
    }

    func start() {
        isStopping = false
        detectMole()
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now(), repeating: 10, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            // Drain Foundation temporaries after each sample, even while the UI is hidden.
            autoreleasepool { self?.sampleMemory() }
        }
        timer.resume(); sampleTimer = timer
        refreshSystem()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.systemStatusVisible, !self.jobBusy else { return }
            self.refreshSystem()
        }
    }
    func detectMole() {
        let url = URL(fileURLWithPath: "/opt/homebrew/bin/mo").resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: url.path), let script = try? String(contentsOf: url),
              let range = script.range(of: #"(?m)^VERSION="[^"]+""#, options: .regularExpression) else { moleVersion = "未检测到"; return }
        moleVersion = String(script[range]).replacingOccurrences(of: "VERSION=", with: "").replacingOccurrences(of: "\"", with: "")
    }
    private func sampleMemory() {
        toolManager.poll()
        let r = sampler.sample(); var loggingError: String?
        do {
            if logStore == nil { logStore = try LogStore(directory: logsURL) }
            try logStore?.append(logRecord(r))
        } catch { loggingError = "监测仍运行，但日志暂时无法写入。" }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latest = r
            if self.monitorLogError != loggingError { self.monitorLogError = loggingError }
            self.memoryPoints.append(r.totalFootprintBytes.map { Double($0) / GiB })
            if self.memoryPoints.count > 60 { self.memoryPoints.removeFirst(self.memoryPoints.count - 60) }
            for (name, change) in [("主程序", r.rootChanges), ("界面进程", r.rendererChanges)] where change.changed {
                let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                self.memoryEvents.insert("\(time) · \(name)变化：新增 \(change.started.count)，退出 \(change.exited.count)；原因未判定。", at: 0)
            }
            if self.memoryEvents.count > 8 { self.memoryEvents.removeLast(self.memoryEvents.count - 8) }
            self.onMemoryUpdate?(r)
        }
    }
    func setVisible(_ visible: Bool) {
        if mainWindowVisible != visible {
            mainWindowVisible = visible
            lifecycleLog.notice("main_window_visible=\(visible, privacy: .public)")
        }
        updateSystemObservation()
    }
    func setPopoverVisible(_ visible: Bool) {
        if popoverVisible != visible {
            popoverVisible = visible
            lifecycleLog.notice("popover_visible=\(visible, privacy: .public)")
        }
        updateSystemObservation()
    }
    private func updateSystemObservation() {
        if systemStatusVisible { refreshSystemIfStale() }
        else if statusBridge.isRunning { statusBridge.cancel() }
    }
    func refreshSystemIfStale() {
        guard systemIsStale, !jobBusy, !isStopping else { return }
        refreshSystem()
    }
    func pageChanged() {
        updateSystemObservation()
        if page == .history && sessions.isEmpty && !jobBusy { refreshHistory() }
    }
    func refreshSystem() {
        guard !statusBridge.isRunning, !jobBusy, !isStopping else { return }
        systemRefreshing = true
        do {
            try statusBridge.start(arguments: ["status", "--json"], timeout: 35, onOutput: { _ in }) { [weak self] r in
                guard let self else { return }; self.systemRefreshing = false
                if r.cancelled {
                    if self.systemStatusVisible { self.refreshSystemIfStale() }
                    return
                }
                guard r.exitCode == 0, !r.truncated, let j = Self.json(r.stdout) as? [String: Any] else {
                    self.systemError = "Mole 状态采集未完成。" + String(MoleText.plain(r.stderr).suffix(200)); return
                }
                // Full process commands may contain private arguments. They are not retained in UI state.
                var safe = j
                if let procs = j["top_processes"] as? [[String: Any]] { safe["top_processes"] = procs.map { $0.filter { $0.key != "command" } } }
                self.system = safe; self.systemUpdatedAt = Date()
                self.systemError = r.stderr.isEmpty ? "" : "部分采集有提示，可用指标仍已显示。"
            }
        } catch { systemRefreshing = false; systemError = error.localizedDescription }
    }
    static func json(_ text: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(text.utf8)) }
    private func begin(_ title: String, arguments: [String], timeout: TimeInterval = 300, output: ((String) -> Void)? = nil, completion: @escaping (MoleCommandResult) -> Void) {
        guard !jobBusy else { return }
        jobBusy = true; jobTitle = title; jobPhase = "正在运行"; jobText = ""; jobFailed = false; showDetails = false
        let id = UUID(); runID = id
        do {
            try operationBridge.start(arguments: arguments, timeout: timeout, onOutput: { [weak self] chunk in
                guard let self, self.runID == id else { return }
                self.jobText += MoleText.plain(chunk)
                if self.jobText.utf8.count > 512 * 1024 { self.jobText = "…仅显示最近的输出…\n" + String(self.jobText.suffix(220000)) }
                output?(self.jobText)
            }) { [weak self] r in
                guard let self, self.runID == id else { return }
                self.jobBusy = false
                if r.cancelled { self.jobPhase = "已取消；已执行的步骤不会自动撤销" }
                else if r.exitCode != 0 || r.truncated { self.jobPhase = r.truncated ? "结果过大，请缩小范围" : "未完整完成，请查看详情"; self.jobFailed = true }
                else { self.jobPhase = "本次运行结束" }
                self.uninstallReview = nil; self.protocolState = nil
                completion(r); if !self.jobBusy { self.onAllOperationsStopped?() }
            }
        } catch { jobBusy = false; jobFailed = true; jobPhase = "无法启动"; jobText = error.localizedDescription }
    }
    func cancelOperation() {
        guard jobBusy else { return }
        jobPhase = "正在取消…"; uninstallReview = nil
        if brewUpdateOperation {
            pendingBrewUpdate = nil
            if brewUpdates.isRunning { brewUpdates.cancel() }
            else { finishBrewUpdate(); jobPhase = "已取消，应用未改动"; onAllOperationsStopped?() }
        } else if preparingSelection {
            selectedCleanup.cancel()
            selectionGeneration = UUID(); preparingSelection = false; jobBusy = false; jobPhase = "已取消检查，文件未改动"
            DispatchQueue.main.async { self.onAllOperationsStopped?() }
        } else if selectedCleanup.isRunning { selectedCleanup.cancel() }
        else if brewOperation {
            brewCancellationRequested = true
            if brewService.isRunning { brewService.cancel() }
            else { finishBrewOperation(); jobPhase = "已取消，应用未改动"; onAllOperationsStopped?() }
        } else { operationBridge.cancel() }
    }
    func stopAll() { isStopping = true; statusBridge.cancel(); cancelOperation(); sampleTimer?.cancel(); statusTimer?.invalidate() }
    private func alert(_ title: String, _ message: String, accept: String = "确定") -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.alertStyle = .warning; alert.addButton(withTitle: accept); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "分析此文件夹"; panel.directoryURL = URL(fileURLWithPath: diskPath)
        if panel.runModal() == .OK, let url = panel.url { scanDisk(url.path) }
    }
    func scanDisk(_ path: String? = nil) {
        guard !jobBusy else { return }
        let target = URL(fileURLWithPath: path ?? diskPath).standardizedFileURL
        diskPath = target.path; selectedDisk = nil; diskStatus = "正在扫描…"; diskEntries = []; diskTotal = nil
        begin("分析磁盘空间", arguments: ["analyze", "--json", target.path], timeout: 240) { [weak self] r in
            guard let self else { return }
            guard r.exitCode == 0, !r.cancelled, !r.truncated, let j = Self.json(r.stdout) as? [String: Any] else { self.diskStatus = "未取得完整结果"; return }
            self.diskEntries = (j["entries"] as? [[String: Any]] ?? []).compactMap(DiskEntry.init).sorted { ($0.size ?? 0) > ($1.size ?? 0) }
            self.diskTotal = number(j["total_size"]); self.diskFileCount = number(j["total_files"])
            let status = safeString(j["scan_status"])
            self.diskStatus = status == "complete" ? "扫描完成（按 Mole 排除规则）" : status == "partial" ? "部分结果 · 已测容量为下限" : status == "unavailable" ? "无法读取此目录" : "完整性未知"
            self.jobPhase = self.diskStatus
        }
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func applicationFilterChanged() {
        selectedApp = nil; selectedBrewToken = nil
        if applicationFilter != .all && !brewCatalogLoaded && !jobBusy { loadBrewApps() }
    }
    func refreshApplicationList() {
        if applicationFilter == .all { refreshApps() } else { loadBrewApps() }
    }
    private func beginBrewUpdate(_ title: String, phase: String) {
        jobBusy = true; brewUpdateOperation = true; jobTitle = title; jobPhase = phase
        jobText = ""; jobFailed = false; showDetails = false; pendingBrewUpdate = nil
    }
    private func finishBrewUpdate() {
        jobBusy = false; brewUpdateOperation = false; pendingBrewUpdate = nil
    }
    func loadBrewApps() {
        guard !jobBusy else { return }
        beginBrewUpdate("读取 Homebrew 应用", phase: "读取本机安装记录…")
        brewCatalogError = ""; brewCheckValid = false
        do {
            try brewUpdates.loadInstalled { [weak self] result in
                guard let self else { return }
                self.finishBrewUpdate(); self.brewCatalogLoaded = true
                switch result {
                case .success(let snapshot):
                    self.brewSnapshot = snapshot; self.selectedBrewToken = nil
                    self.jobPhase = "已读取 \(snapshot.items.count) 个 Homebrew 项目"
                case .failure(let error):
                    self.jobFailed = true; self.jobPhase = "未能读取 Homebrew 应用"
                    self.brewCatalogError = "读取失败，请重试"; self.jobText = error.localizedDescription
                }
                self.onAllOperationsStopped?()
            }
        } catch { finishBrewUpdate(); jobFailed = true; jobPhase = "无法读取 Homebrew"; jobText = error.localizedDescription; onAllOperationsStopped?() }
    }
    func checkBrewUpdates() {
        guard !jobBusy else { return }
        applicationFilter = .homebrew
        beginBrewUpdate("检查应用更新", phase: "刷新 Homebrew 与配方元数据…")
        brewCheckValid = false; brewCatalogError = ""
        do {
            try brewUpdates.checkForUpdates(onOutput: { [weak self] in self?.appendJobOutput($0) }) { [weak self] result in
                guard let self else { return }
                self.finishBrewUpdate(); self.brewCatalogLoaded = true
                switch result {
                case .success(let snapshot):
                    self.brewSnapshot = snapshot; self.brewCheckValid = snapshot.isFresh
                    let count = snapshot.items.filter { $0.hasUpdate }.count
                    self.jobPhase = "检查完成 · \(count) 个应用有更新"
                case .failure(let error):
                    self.jobFailed = true; self.jobPhase = "检查未完成，请查看详情"
                    self.brewCatalogError = "检查未完成，已有结果未刷新"
                    self.appendJobOutput("\n" + error.localizedDescription)
                }
                self.onAllOperationsStopped?()
            }
        } catch { finishBrewUpdate(); jobFailed = true; jobPhase = "无法检查更新"; jobText = error.localizedDescription; onAllOperationsStopped?() }
    }
    func prepareBrewUpdate() {
        guard !jobBusy, brewResultsFresh, let item = chosenBrewApp, item.canPrepare,
              let target = item.availableVersion else { return }
        beginBrewUpdate("检查更新内容 · " + item.name, phase: "核对安装记录与目标版本…")
        do {
            try brewUpdates.prepare(token: item.token, expectedVersion: target, onOutput: { [weak self] in self?.appendJobOutput($0) }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let plan): self.pendingBrewUpdate = plan; self.jobPhase = "等待确认更新"
                case .failure(let error):
                    self.finishBrewUpdate(); self.jobFailed = true; self.jobPhase = "更新计划未就绪"
                    self.appendJobOutput("\n" + error.localizedDescription); self.onAllOperationsStopped?()
                }
            }
        } catch { finishBrewUpdate(); jobFailed = true; jobPhase = "无法准备更新"; jobText = error.localizedDescription; onAllOperationsStopped?() }
    }
    func confirmBrewUpdate() {
        guard let plan = pendingBrewUpdate, plan.canExecute, brewUpdateOperation else { return }
        pendingBrewUpdate = nil; showDetails = true; jobPhase = "正在更新 " + plan.name
        do {
            try brewUpdates.upgrade(plan, onOutput: { [weak self] in self?.appendJobOutput($0) }) { [weak self] result in
                guard let self else { return }
                self.brewCheckValid = false
                if !result.stderr.isEmpty && !self.jobText.contains(MoleText.plain(result.stderr)) { self.appendJobOutput("\n" + result.stderr) }
                // Verify the installed receipt after brew exits; exit 0 alone is not proof.
                do {
                    try self.brewUpdates.loadInstalled { [weak self] inventory in
                        guard let self else { return }
                        self.finishBrewUpdate()
                        var confirmed = false
                        if case .success(let snapshot) = inventory {
                            self.brewSnapshot = snapshot
                            confirmed = snapshot.items.contains { $0.token == plan.token && $0.installedVersion == plan.targetVersion && !$0.appPaths.isEmpty && $0.appPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) } }
                        }
                        if result.cancelled { self.jobPhase = "更新已取消；请核对应用当前版本" }
                        else if result.exitCode == 0 && !result.truncated && confirmed { self.jobPhase = "已更新 \(plan.name) 至 \(plan.targetVersion)" }
                        else { self.jobFailed = true; self.jobPhase = "未确认更新完整完成，请查看详情" }
                        do { try self.localHistory.append(command: "Homebrew 更新 · " + plan.name,
                            summary: confirmed ? plan.installedVersion + " → " + plan.targetVersion : "更新状态需核对",
                            skipped: result.cancelled ? 1 : 0, failed: self.jobFailed ? 1 : 0) }
                        catch { self.appendJobOutput("\n更新已结束，但历史记录写入失败。") }
                        self.onAllOperationsStopped?()
                    }
                } catch { self.finishBrewUpdate(); self.jobFailed = true; self.jobPhase = "更新已结束，安装结果未能复核"; self.appendJobOutput("\n" + error.localizedDescription); self.onAllOperationsStopped?() }
            }
        } catch { finishBrewUpdate(); jobFailed = true; jobPhase = "无法执行更新"; appendJobOutput("\n" + error.localizedDescription); onAllOperationsStopped?() }
    }
    func prepareSelectedBrewUninstall() {
        guard !jobBusy, let item = chosenBrewApp, let path = item.appPaths.first,
              let identity = BundleIdentity(path: path), let app = MoleApplication([
                "name": URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                "path": path, "bundle_id": identity.bundleID, "source": "Homebrew", "size": "—"
              ]) else { return }
        prepareBoundUninstall(app, dryRun: false)
    }
    func refreshApps() {
        guard !jobBusy else { return }
        brewSourcesVerified = false
        begin("读取已安装应用", arguments: ["uninstall", "--list"], timeout: 180) { [weak self] r in
            guard let self, !r.cancelled else { return }
            guard r.exitCode == 0, !r.truncated, let list = Self.json(r.stdout) as? [[String: Any]] else {
                self.jobFailed = true; self.jobPhase = "无法读取应用列表，请查看详情"; return
            }
            self.apps = list.compactMap(MoleApplication.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.selectedApp = nil; self.jobPhase = "已读取 \(self.apps.count) 个应用"
            self.reconcileBrewSources { _ in }
        }
    }
    func appRestriction(_ app: MoleApplication) -> String? {
        if !brewSourcesVerified && !app.isManaged { return "应用安装来源未核对完成，请刷新列表后再试。" }
        if !mutationSupported && !app.isManaged { return "当前 Mole 版本未通过写入接口验证，仅支持查看。" }
        if ["com.openai.codex", "local.codex.memorywatch"].contains(app.bundleID) { return "正在使用的 Codex 与 Lightpaw 受到保护。" }
        if app.query.hasPrefix("-") || (app.name + app.query).unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { return "应用名称包含不支持的字符。" }
        if app.path.hasPrefix("/System/") || app.path.hasPrefix("/Library/") { return "系统组件仅供查看。" }
        if app.isManaged { return nil }
        let matches = apps.filter { $0.name.caseInsensitiveCompare(app.query) == .orderedSame || $0.query.caseInsensitiveCompare(app.query) == .orderedSame }
        if matches.count != 1 || matches.first?.path != app.path { return "有同名应用，无法把 Mole 的名称匹配唯一绑定到此路径。" }
        if app.path.hasPrefix("/System/") || app.path.hasPrefix("/Library/") { return "系统组件仅供查看。" }
        return nil
    }
    private func reconcileBrewSources(completion: @escaping (Bool) -> Void) {
        jobBusy = true; brewOperation = true; brewCancellationRequested = false
        jobPhase = "核对 Homebrew 安装来源…"
        do {
            try brewService.installedAppPaths { [weak self] result in
                guard let self else { return }
                self.jobBusy = false; self.brewOperation = false
                if self.brewCancellationRequested { self.jobPhase = "已取消来源核对"; completion(false); self.onAllOperationsStopped?(); return }
                switch result {
                case .success(let paths):
                    self.apps = self.apps.map { app in var updated = app; if paths.contains(app.path) { updated.source = "Homebrew" }; return updated }
                    self.brewSourcesVerified = true; self.jobPhase = "已核对 \(self.apps.count) 个应用的安装来源"; completion(true)
                case .failure(let error):
                    self.brewSourcesVerified = false; self.jobFailed = true; self.jobPhase = "部分安装来源未能核对，普通卸载暂不可用"
                    self.jobText += "\n" + error.localizedDescription; completion(false)
                }
                if !self.jobBusy { self.onAllOperationsStopped?() }
            }
        } catch {
            jobBusy = false; brewOperation = false; brewSourcesVerified = false; jobFailed = true
            jobPhase = "无法核对安装来源"; jobText += "\n" + error.localizedDescription; completion(false); onAllOperationsStopped?()
        }
    }
    func prepareUninstall(dryRun: Bool = false) {
        guard let app = chosenApp, !jobBusy else { return }
        jobTitle = "检查卸载内容 · " + app.name; jobFailed = false; jobText = ""
        reconcileBrewSources { [weak self] verified in
            guard let self, verified, let current = self.apps.first(where: { $0.id == app.id }) else { return }
            self.prepareBoundUninstall(current, dryRun: dryRun)
        }
    }
    private func prepareBoundUninstall(_ app: MoleApplication, dryRun: Bool) {
        detectMole()
        if let reason = appRestriction(app) { _ = alert("无法建立卸载计划", reason); return }
        if app.isManaged { prepareBrewUninstall(app); return }
        let previewOnly = dryRun
        guard let identity = BundleIdentity(path: app.path), identity.bundleID == app.bundleID else { _ = alert("应用已变化", "重新读取应用列表后再试。"); return }
        pendingApp = app; pendingIdentity = identity; uninstallReview = nil; protocolState = UninstallProtocol(expected: app)
        let args = ["uninstall"] + (previewOnly ? ["--dry-run"] : []) + [app.query]
        begin(previewOnly ? "预览卸载 · \(app.name)" : "准备卸载 · \(app.name)", arguments: args, timeout: 900, output: { [weak self] text in
            guard let self, var proto = self.protocolState else { return }
            let event = proto.receive(text); self.protocolState = proto
            switch event {
            case .none: break
            case .advanceDiscovery: self.operationBridge.writeInput("y\n")
            case .review(let review):
                guard BundleIdentity(path: app.path) == identity else { self.jobFailed = true; self.jobPhase = "应用路径发生变化，已中止"; self.operationBridge.cancel(); return }
                self.uninstallReview = review; self.jobPhase = previewOnly ? "预览已就绪 · 不会删除" : "等待你确认卸载内容"
            case .reject(let why): self.jobFailed = true; self.jobText += "\n" + why; self.operationBridge.cancel()
            }
        }) { [weak self] r in
            guard let self else { return }
            if !r.cancelled && r.exitCode == 0 {
                if previewOnly { self.jobPhase = "卸载预览结束，应用未删除" }
                else if !FileManager.default.fileExists(atPath: app.path) { self.jobPhase = "应用文件已移除；关联项目结果见详情"; self.apps.removeAll { $0.id == app.id }; self.selectedApp = nil }
                else { self.jobPhase = "应用仍存在，未确认卸载成功"; self.jobFailed = true }
            }
            self.pendingApp = nil; self.pendingIdentity = nil
        }
    }
    private func prepareBrewUninstall(_ app: MoleApplication) {
        guard let identity = BundleIdentity(path: app.path), identity.bundleID == app.bundleID else { _ = alert("应用已变化", "请重新读取应用列表。"); return }
        pendingApp = app; pendingIdentity = identity; pendingBrewPlan = nil; uninstallReview = nil; uninstallScriptAcknowledged = false
        brewCancellationRequested = false; brewOperation = true; jobBusy = true; jobFailed = false; jobTitle = "检查卸载内容 · " + app.name
        jobPhase = "读取 Homebrew 安装记录…"; jobText = ""; showDetails = false
        do {
            try brewService.prepare(appPath: app.path, bundleID: app.bundleID, onOutput: { [weak self] chunk in self?.appendJobOutput(chunk) }) { [weak self] result in
                guard let self else { return }
                if self.brewCancellationRequested { self.finishBrewOperation(); self.jobPhase = "已取消，应用未改动"; self.onAllOperationsStopped?(); return }
                switch result {
                case .failure(let error):
                    self.finishBrewOperation(); self.jobFailed = true; self.jobPhase = "检查未完成"; self.jobText += "\n" + error.localizedDescription; self.onAllOperationsStopped?()
                case .success(let plan):
                    guard BundleIdentity(path: app.path) == identity else { self.finishBrewOperation(); self.jobFailed = true; self.jobPhase = "应用已变化，请重新读取"; self.onAllOperationsStopped?(); return }
                    self.pendingBrewPlan = plan; self.uninstallReview = plan.preview
                    self.jobPhase = plan.canExecute ? "等待确认卸载内容" : "此应用需专用卸载流程，详情见清单"
                }
            }
        } catch { finishBrewOperation(); jobFailed = true; jobPhase = "无法读取 Homebrew"; jobText = error.localizedDescription; onAllOperationsStopped?() }
    }
    private func appendJobOutput(_ chunk: String) {
        jobText += MoleText.plain(chunk)
        if jobText.utf8.count > 512 * 1024 { jobText = "…仅显示最近输出…\n" + String(jobText.suffix(220000)) }
    }
    private func finishBrewOperation() {
        jobBusy = false; brewOperation = false; pendingBrewPlan = nil
        uninstallReview = nil; pendingApp = nil; pendingIdentity = nil; uninstallScriptAcknowledged = false
    }
    func confirmUninstall() {
        guard uninstallCanExecute else { return }
        guard let app = pendingApp, uninstallReview != nil, let identity = pendingIdentity, BundleIdentity(path: app.path) == identity else { cancelOperation(); return }
        if app.isManaged {
            guard let plan = pendingBrewPlan, plan.canExecute else { return }
            brewCheckValid = false
            uninstallReview = nil; showDetails = true; jobPhase = "正在通过 Homebrew 卸载…"
            do {
                try brewService.uninstall(plan, scriptReviewConfirmed: uninstallScriptAcknowledged, onOutput: { [weak self] chunk in self?.appendJobOutput(chunk) }) { [weak self] result in
                    guard let self else { return }
                    self.finishBrewOperation()
                    if !result.stderr.isEmpty && !self.jobText.contains(MoleText.plain(result.stderr)) { self.appendJobOutput("\n" + result.stderr) }
                    let removed = !FileManager.default.fileExists(atPath: app.path)
                    if result.cancelled { self.jobPhase = "已取消；已完成的卸载步骤不会自动恢复" }
                    else if result.exitCode == 0 && !result.truncated && removed {
                        self.jobPhase = "已卸载 " + app.name
                        self.removeMissingAppsAfterUninstall()
                        if let snapshot = self.brewSnapshot {
                            self.brewSnapshot = BrewUpdateSnapshot(items: snapshot.items.filter { item in
                                item.token != plan.token && (item.appPaths.isEmpty || item.appPaths.contains { FileManager.default.fileExists(atPath: $0) })
                            }, checkedAt: snapshot.checkedAt, metadataRefreshedAt: nil)
                        }
                        self.brewCheckValid = false; self.selectedBrewToken = nil
                    } else { self.jobFailed = true; self.jobPhase = "卸载未完整完成，请查看详情" }
                    do { try self.localHistory.append(command: "Homebrew 卸载 · " + app.name, summary: removed ? "应用已移除" : "应用仍存在", removed: removed ? 1 : 0, skipped: result.cancelled ? 1 : 0, failed: self.jobFailed ? 1 : 0) }
                    catch { self.jobText += "\n卸载已结束，但历史记录写入失败。" }
                    self.onAllOperationsStopped?(); self.refreshSystem()
                }
            } catch { finishBrewOperation(); jobFailed = true; jobPhase = "无法执行卸载"; jobText += "\n" + error.localizedDescription; onAllOperationsStopped?() }
            return
        }
        // The review sheet is the final confirmation; keep stdin open until the
        // protocol has proved the exact selected app and the user confirms here.
        uninstallReview = nil; showDetails = true; jobPhase = "正在卸载…"; operationBridge.writeInput("\n")
    }
    // One cask may own several app bundles. Remove every disappeared row after
    // successful uninstall, while retaining applications whose paths still exist.
    func removeMissingAppsAfterUninstall() {
        apps.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if let selectedApp, !apps.contains(where: { $0.id == selectedApp }) { self.selectedApp = nil }
    }
    private func rules(for kind: String) -> String {
        let name = kind == "clean" ? "whitelist" : "whitelist_optimize"
        var url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mole/\(name)")
        if kind == "optimize" && !FileManager.default.fileExists(atPath: url.path) {
            url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mole/whitelist_checks")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return "未保存自定义规则，使用 Mole 默认保护策略。" }
        return (try? String(contentsOf: url)) ?? "保护文件存在但无法读取；Mole 将拒绝继续操作。"
    }
    func previewValid(_ kind: String) -> Bool {
        guard let date = previewDate[kind], Date().timeIntervalSince(date) < 600 else { return false }
        guard let current = rulesSnapshot(kind), let expected = previewRules[kind] else { return false }
        return current == expected
    }
    private func rulesSnapshot(_ kind: String) -> String? {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mole")
        var url = base.appendingPathComponent(kind == "clean" ? "whitelist" : "whitelist_optimize")
        if kind == "optimize" && !FileManager.default.fileExists(atPath: url.path) { url = base.appendingPathComponent("whitelist_checks") }
        guard FileManager.default.fileExists(atPath: url.path) else { return url.path + "\n<absent>" }
        guard let contents = try? String(contentsOf: url) else { return nil }
        return url.path + "\n" + contents
    }
    func previewMaintenance(_ kind: String) {
        guard ["clean", "optimize"].contains(kind), !jobBusy else { return }
        guard let initialRules = rulesSnapshot(kind) else {
            jobFailed = true; jobPhase = "无法读取保护规则，请检查文件权限"
            if kind == "clean" { cleanupScanState = .failed }
            return
        }
        let started = Date(); previewDate[kind] = nil
        if kind == "clean" { cleanEntries = []; cleanPreview = ""; selectedCleanIDs = []; cleanupScanState = .running } else { optimizePreview = "" }
        begin(kind == "clean" ? "扫描可清理项目" : "预览系统优化", arguments: [kind, "--dry-run"], timeout: 480, output: { [weak self] text in
            let titles = ["User essentials": "用户缓存与日志", "App caches": "应用缓存", "Browsers": "浏览器缓存", "Cloud & Office": "云盘与办公应用", "Developer tools": "开发工具缓存", "System": "系统项目", "System caches": "系统缓存", "Deep cleanup": "残留项目"]
            if let header = text.components(separatedBy: .newlines).last(where: { $0.hasPrefix("➤ ") }) {
                let title = String(header.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                self?.jobPhase = "正在检查 · " + (titles[title] ?? title)
            }
        }) { [weak self] r in
            guard let self else { return }
            let text = MoleText.plain(r.stdout + "\n" + r.stderr)
            if kind == "clean" { self.cleanPreview = text } else { self.optimizePreview = text }
            guard r.exitCode == 0, !r.cancelled, !r.truncated else {
                if kind == "clean" {
                    self.cleanupScanState = r.cancelled ? .cancelled : .failed
                    if r.cancelled { self.jobPhase = "扫描已取消，文件未改动" }
                }
                return
            }
            guard self.rulesSnapshot(kind) == initialRules else {
                self.jobFailed = true; self.jobPhase = "扫描期间保护规则已变化，请重新预览"
                if kind == "clean" { self.cleanupScanState = .failed }
                return
            }
            self.previewDate[kind] = Date(); self.previewRules[kind] = initialRules
            if kind == "clean" {
                let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mole/clean-list.txt")
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let date = attrs[.modificationDate] as? Date, date >= started.addingTimeInterval(-1),
                      let size = attrs[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024, let report = try? String(contentsOf: file) else {
                    self.previewDate[kind] = nil; self.cleanupScanState = .failed
                    self.jobFailed = true; self.jobPhase = "未取得本次扫描清单，请重试"; return
                }
                self.cleanEntries = MoleText.cleanupEntries(report)
                self.cleanupScanState = .ready(self.cleanEntries.count)
            }
            self.jobPhase = "预览完成 · 尚未执行"
        }
        if kind == "clean", !jobBusy, cleanupScanState == .running { cleanupScanState = .failed }
    }
    func executeMaintenance(_ kind: String) {
        if kind == "clean" { executeSelectedCleanup(); return }
        guard kind == "optimize", !jobBusy else { return }; detectMole()
        guard mutationSupported, previewValid(kind) else { _ = alert("请先重新预览", "预览有效期为 10 分钟；Mole 版本或保护规则变化后需要重新核对。"); return }
        let message = "执行 Mole 的整组系统维护，包括适用的缓存、数据库、索引、网络与 Finder 设置任务；部分步骤可能要求管理员验证或短暂影响网络。Mole 会依据实时状态及保护规则跳过不适用项目。"
        guard alert("执行 Mole 系统优化？", message, accept: "执行系统优化") else { return }
        detectMole()
        guard mutationSupported, previewValid(kind) else {
            previewDate[kind] = nil; jobFailed = true; jobPhase = "版本、保护规则或预览有效期已变化，请重新预览"; return
        }
        previewDate[kind] = nil
        begin("执行系统优化", arguments: [kind], timeout: 600) { [weak self] r in
            guard let self else { return }
            if r.exitCode == 0 && !r.cancelled && !r.truncated { self.jobPhase = "Mole 执行结束 · 请核对详情中的跳过或失败项目" }
            self.refreshSystem()
        }
    }
    func executeSelectedCleanup() {
        guard !jobBusy, !selectedCleanIDs.isEmpty else { return }
        detectMole()
        guard mutationSupported, previewValid("clean") else { _ = alert("请重新扫描", "清理预览已过期或保护规则有变化。"); return }
        let candidates = cleanEntries.map { CleanupCandidate(id: $0.id, path: $0.path, section: $0.section, detail: $0.detail) }
        let selected = selectedCleanIDs, permanently = permanentCleanup
        let id = UUID(); selectionGeneration = id; preparingSelection = true
        jobBusy = true; jobFailed = false; jobTitle = "检查已选项目"; jobPhase = "核对文件与占用状态…"; jobText = ""; showDetails = false
        cleanupQueue.async { [weak self] in
            guard let self else { return }
            let prepared = Result { try self.selectedCleanup.prepare(candidates: candidates, selectedIDs: selected) }
            DispatchQueue.main.async {
                guard self.selectionGeneration == id else { return }
                self.preparingSelection = false
                switch prepared {
                case .failure(let error):
                    self.jobBusy = false; self.jobFailed = true; self.jobPhase = "检查未完成"; self.jobText = error.localizedDescription; self.onAllOperationsStopped?()
                case .success(let plan):
                    self.jobText = plan.items.map { "待处理：" + shortPath($0.path) }.joined(separator: "\n")
                    self.jobText += "\n" + plan.skipped.map { "保留：\(shortPath($0.path)) · \($0.message)" }.joined(separator: "\n")
                    guard !plan.items.isEmpty else {
                        self.jobBusy = false; self.jobPhase = "所选项目均已保留，请查看原因"; self.showDetails = true; self.onAllOperationsStopped?(); return
                    }
                    let paths = plan.items.prefix(10).map { "• " + shortPath($0.path) }.joined(separator: "\n")
                    let tail = plan.items.count > 10 ? "\n以及另外 \(plan.items.count - 10) 个已选项目。" : ""
                    let behavior = permanently ? "这些项目会永久删除，无法从废纸篓恢复。" : "这些项目会移到废纸篓，可在 Finder 中恢复；清空后才释放磁盘空间。"
                    let title = permanently ? "永久清理 \(plan.items.count) 项？" : "将 \(plan.items.count) 项移到废纸篓？"
                    guard self.previewValid("clean"), self.alert(title, behavior + "\n\n" + paths + tail + (plan.skipped.isEmpty ? "" : "\n\n另有 \(plan.skipped.count) 项未通过检查，将保留。"), accept: permanently ? "永久清理" : "移到废纸篓") else {
                        self.jobBusy = false; self.jobPhase = "已取消，文件未改动"; self.onAllOperationsStopped?(); return
                    }
                    guard self.previewValid("clean") else { self.jobBusy = false; self.jobFailed = true; self.jobPhase = "保护规则或预览已变化，请重新扫描"; self.onAllOperationsStopped?(); return }
                    self.previewDate["clean"] = nil; self.cleanupScanState = .idle
                    self.jobTitle = permanently ? "清理已选项目" : "移到废纸篓"; self.jobPhase = "正在处理已确认的项目…"
                    self.selectedCleanup.execute(plan, permanently: permanently, onProgress: { result in
                        self.jobText += "\n\(result.status.rawValue)：\(shortPath(result.path)) · \(result.message)"
                    }) { results in
                        let trashed = results.filter { $0.status == .trashed }.count, removed = results.filter { $0.status == .removed }.count
                        let failed = results.filter { $0.status == .failed }.count
                        let kept = results.count - trashed - removed - failed
                        let donePaths = results.filter { $0.status == .trashed || $0.status == .removed }.map(\.path)
                        let doneIDs = Set(self.cleanEntries.filter { row in donePaths.contains { row.path == $0 || row.path.hasPrefix($0 + "/") } }.map(\.id))
                        self.cleanEntries.removeAll { doneIDs.contains($0.id) }; self.selectedCleanIDs.subtract(doneIDs)
                        self.jobBusy = false; self.jobFailed = failed > 0
                        self.jobPhase = "已处理 \(trashed + removed) 项" + (kept > 0 ? " · 保留 \(kept) 项" : "") + (failed > 0 ? " · 失败 \(failed) 项" : "")
                        if trashed > 0 { self.jobPhase += " · 文件可从废纸篓恢复" }
                        do { try self.localHistory.append(command: permanently ? "清理已选项目" : "移到废纸篓", summary: "\(trashed + removed) 项", trashed: trashed, removed: removed, skipped: kept, failed: failed) }
                        catch { self.jobText += "\n操作已结束，但本机历史写入失败。" }
                        self.onAllOperationsStopped?(); self.refreshSystem()
                    }
                }
            }
        }
    }
    func viewProtection() {
        let clean = rules(for: "clean"); let optimize = rules(for: "optimize")
        protectionText = "清理保护规则\n" + clean + "\n\n优化保护规则\n" + optimize
        showProtection = true
    }
    func refreshHistory() {
        begin("读取 Mole 操作历史", arguments: ["history", "--json", "--limit", "20"], timeout: 35) { [weak self] r in
            guard let self, !r.cancelled else { return }
            guard r.exitCode == 0, !r.truncated, let j = Self.json(r.stdout) as? [String: Any], j["sessions"] is [[String: Any]] else {
                self.sessions = self.localHistory.read(); self.jobFailed = true; self.jobPhase = "已显示本机记录；Mole 历史暂不可用"; return
            }
            self.sessions = Array((self.localHistory.read() + (j["sessions"] as? [[String: Any]] ?? [])).sorted { safeString($0["started_at"]) > safeString($1["started_at"]) }.prefix(20)); self.jobPhase = "已读取最近 \(self.sessions.count) 次记录"
        }
    }
}
