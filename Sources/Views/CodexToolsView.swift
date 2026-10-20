import SwiftUI
import AppKit

struct CodexHelperGroup: Identifiable {
    let title: String
    let detail: String
    let count: Int
    let bytes: UInt64?
    var id: String { title }
}

enum CodexHelperInventory {
    // Labels describe known entry points, never whether a tool is idle.
    static func label(executable: String, script: String?, cwd: String?) -> (String, String) {
        guard let script else { return ("其他 Node", "用途未确认；保留") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let embedded = ["/Applications/ChatGPT.app", "/Applications/Codex.app", "/Codex.app"].map { $0 + "/Contents/Resources/cua_node" }
        if embedded.contains(where: { executable == $0 + "/bin/node" && script == $0 + "/lib/node_modules/@oai/cua-repl/bin/cua-repl.mjs" }) {
            return ("电脑操作服务", "连接浏览器和原生应用")
        }
        if let cwd {
            let parent = URL(fileURLWithPath: cwd).deletingLastPathComponent().path
            let bundledNode = embedded.contains { executable == $0 + "/bin/node" }
            if bundledNode && script == "./server.mjs" && cwd == home + "/.codex/code-review-plugin" {
                return ("代码审查", "Codex 代码审查服务")
            }
            if bundledNode && script == "./server.mjs" && parent == home + "/.codex/plugins/cache/openai-bundled/codex-app-tools" {
                return ("Codex 应用工具", "任务、窗口与应用内功能")
            }
            if (bundledNode || executable == home + "/.hermes/node/bin/node") && script == "./mcp/server.bundle.mjs" && parent == home + "/.codex/plugins/cache/openai-curated-remote/creative-production" {
                return ("创意工具", "创意制作插件服务")
            }
        }
        let generations = home + "/Library/Application Support/Codex/artifact-sessions/runtime-generations/"
        if script.hasPrefix(generations), script.hasSuffix("/runtime/node_modules/@oai/artifact-tool/dist/artifact-session/host-daemon.mjs") {
            let prefix = script.components(separatedBy: "/runtime/node_modules/").first ?? ""
            if executable == prefix + "/runtime/bin/node" { return ("文档工具", "表格与演示文稿服务") }
        }
        return ("其他 Node", "用途未确认；保留")
    }

    static func scan() throws -> [CodexHelperGroup] {
        let snapshot = listProcesses()
        guard snapshot.error == 0 else { throw CodexToolsError.processDiscovery }
        let targets = targetExecutables()
        let roots = snapshot.items.filter { targets.contains($0.path) }
        guard !roots.isEmpty || snapshot.skipped == 0 else { throw CodexToolsError.processDiscovery }
        let selected = descendants(snapshot.items, roots: Set(roots.map(\.id)))
        let nodes = selected.filter { $0.name == "node" }
        let labels = Dictionary(uniqueKeysWithValues: nodes.map { p in
            (p.id.pid, label(executable: p.path, script: CodexTools.scriptPath(p), cwd: CodexTools.workingDirectory(p)))
        })
        let lookup = Dictionary(uniqueKeysWithValues: selected.map { ($0.id.pid, $0) })
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"
        var repl: [Int32: (ancestor: Int32, directory: String, file: String)] = [:]
        for process in nodes where labels[process.id.pid]?.0 == "其他 Node" {
            guard process.path.hasSuffix("/Contents/Resources/cua_node/bin/node"),
                  let script = CodexTools.scriptPath(process, argumentIndex: 2), script.hasPrefix(temporary) else { continue }
            let url = URL(fileURLWithPath: script), directory = url.deletingLastPathComponent()
            guard ["kernel.js", "trusted-worker.js"].contains(url.lastPathComponent), directory.lastPathComponent.hasPrefix(".tmp") else { continue }
            var parent = process.parent, seen = Set<Int32>()
            while let ancestor = lookup[parent], seen.insert(parent).inserted {
                if labels[parent]?.0 == "电脑操作服务" {
                    repl[process.id.pid] = (parent, directory.path, url.lastPathComponent); break
                }
                parent = ancestor.parent
            }
        }
        var entries: [String: (detail: String, values: [UInt64?])] = [:]
        for process in nodes {
            var (title, detail) = labels[process.id.pid] ?? ("其他 Node", "用途未确认；保留")
            if let candidate = repl[process.id.pid], repl.values.contains(where: {
                $0.ancestor == candidate.ancestor && $0.directory == candidate.directory && $0.file != candidate.file
            }) {
                title = "持久 JavaScript 环境"; detail = "电脑操作的变量与会话状态"
            }
            var bytes: UInt64 = 0
            let error = cwm_footprint(process.id.pid, process.id.seconds, process.id.micros, &bytes)
            var group = entries[title] ?? (detail, [])
            group.values.append(error == 0 ? bytes : nil)
            entries[title] = group
        }
        guard roots.allSatisfy({ cwm_identity($0.id.pid, $0.id.seconds, $0.id.micros) == 0 }) else {
            throw CodexToolsError.processDiscovery
        }
        return entries.map { title, entry in
            CodexHelperGroup(title: title, detail: entry.detail, count: entry.values.count,
                             bytes: entry.values.allSatisfy { $0 != nil } ? entry.values.compactMap { $0 }.reduce(0, +) : nil)
        }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }
}

struct CodexToolRow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let bytes: UInt64?
    let count: Int?
    let enabled: Bool?
    let reason: String?
    let pending: ToolChangeState?
    var manageable: Bool { enabled != nil && reason == nil }
    var state: String {
        if let pending {
            switch pending.status {
            case .waiting: return pending.targetEnabled ? "待开启" : "待关闭"
            case .conflict: return "配置已变化"
            case .failed: return "需要重试"
            }
        }
        if let reason { return reason }
        return enabled == true ? "自动加载开启" : "自动加载关闭"
    }
}

func toolMemoryText(_ bytes: UInt64?) -> String {
    guard let bytes else { return "—" }
    return bytes == 0 ? "0 B" : bytesText(Double(bytes))
}

extension CodexToolsModel {
    var rows: [CodexToolRow] {
        let pending = Dictionary(uniqueKeysWithValues: changes.map { ($0.key, $0) })
        let metadata = Dictionary(uniqueKeysWithValues: plugins.map { ("plugin:" + $0.id, $0) })
        var rows = configurations.map { key, snapshot in
            let plugin = metadata[key]
            let title = plugin?.title ?? (snapshot.serverID == "chatcut_desktop" ? "ChatCut" : snapshot.serverID == "computer-use" ? "旧电脑操作集成" : snapshot.serverID)
            let reason: String? = CodexTools.isProtectedTargetKey(key) ? "由 Codex 管理" :
                (plugin != nil && plugin?.enabled != snapshot.enabled ? "受其他配置控制" : nil)
            let detail = plugin.map { $0.remote ? "MCP 插件 · 远程连接" : "MCP 插件 · 本地服务" } ?? "自定义 MCP 工具"
            return CodexToolRow(id: key, title: title, detail: detail, bytes: snapshot.totalFootprintBytes,
                                count: snapshot.processInspectionSupported ? snapshot.processes.count : nil,
                                enabled: snapshot.enabled, reason: reason, pending: pending[key])
        }
        rows += groups.map { group in
            let unknown = ["创意工具", "其他 Node"].contains(group.title)
            return CodexToolRow(id: "node:" + group.id, title: group.title, detail: group.detail,
                                bytes: group.bytes, count: group.count, enabled: nil,
                                reason: unknown ? "来源待确认" : "由 Codex 管理", pending: nil)
        }
        let known = Set(rows.map(\.id))
        rows += changes.filter { !known.contains($0.key) }.map {
            CodexToolRow(id: $0.key, title: String($0.key.split(separator: ":", maxSplits: 1).last ?? "工具"),
                         detail: "配置或插件暂时不可用，可撤销此项", bytes: nil, count: nil,
                         enabled: nil, reason: "待核实", pending: $0)
        }
        return rows.sorted {
            let left = $0.manageable || $0.pending != nil, right = $1.manageable || $1.pending != nil
            if left != right { return left }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

struct CodexToolsSheet: View {
    @ObservedObject var tools: CodexToolsModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selectedID: String?
    @ViewState private var manageableOnly = false
    @ViewState private var confirming = false
    private var selected: CodexToolRow? { tools.rows.first { $0.id == selectedID } }
    private var visibleRows: [CodexToolRow] {
        tools.rows.filter { !manageableOnly || $0.manageable || $0.pending != nil }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("后台工具").font(.system(size: 18, weight: .semibold))
                    Text("逐项管理自动加载，保留当前任务连接。")
                        .font(.system(size: 12)).foregroundStyle(PawTheme.secondary)
                }
                Spacer()
                if tools.busy { ProgressView().controlSize(.small) }
                Button { tools.scan() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新工具与配置").disabled(tools.busy).accessibilityLabel("刷新后台工具")
            }
            HStack {
                Picker("显示工具", selection: $manageableOnly) {
                    Text("全部").tag(false); Text("可管理").tag(true)
                }.pickerStyle(.segmented).frame(width: 170).labelsHidden()
                Spacer()
                Text(tools.changes.isEmpty ? "退出 Codex 后应用更改" : "\(tools.changes.count) 项待处理 · 保持 Lightpaw 运行")
                    .font(.system(size: 11)).foregroundStyle(PawTheme.secondary)
            }
            Table(visibleRows, selection: $selectedID) {
                TableColumn("工具") { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title).lineLimit(1)
                        Text(row.state).font(.system(size: 10)).foregroundStyle(row.pending == nil ? PawTheme.secondary : PawTheme.lavender)
                    }.padding(.vertical, 4)
                }.width(min: 190, ideal: 250)
                TableColumn("内存") { row in Text(toolMemoryText(row.bytes)).monospacedDigit() }.width(85)
                TableColumn("下次启动") { row in
                    if row.manageable {
                        Toggle("自动加载 \(row.title)", isOn: Binding(
                            get: { row.pending?.targetEnabled ?? row.enabled ?? false },
                            set: { selectedID = row.id; tools.request(row.id, enabled: $0) }
                        )).toggleStyle(.switch).labelsHidden().controlSize(.small)
                            .disabled(tools.busy || !tools.queueReady || (row.pending != nil && row.pending?.status != .waiting))
                            .accessibilityLabel("自动加载 \(row.title)")
                            .accessibilityIdentifier("tool-toggle-" + row.id)
                    } else {
                        Image(systemName: "lock").foregroundStyle(PawTheme.secondary).help(row.reason ?? "暂不可管理")
                    }
                }.width(90)
            }.font(.system(size: 12)).scrollContentBackground(.hidden).background(PawTheme.sidebar)
                .frame(maxHeight: .infinity)
                .overlay { if visibleRows.isEmpty && !tools.busy { Text("暂无可管理工具").foregroundStyle(PawTheme.secondary) } }
            VStack(alignment: .leading, spacing: 8) {
                if let row = selected {
                    HStack {
                        Text(row.title).fontWeight(.medium)
                        Text(row.detail).foregroundStyle(PawTheme.secondary)
                        Spacer()
                        if let count = row.count { Text("\(count) 个实例").foregroundStyle(PawTheme.secondary) }
                    }
                    Text(detail(row)).foregroundStyle(PawTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    if row.pending != nil {
                        HStack {
                            Button("撤销更改") { tools.cancel(row.id) }
                                .accessibilityIdentifier("cancel-tool-change").disabled(tools.busy)
                            if row.manageable && row.pending?.status != .waiting {
                                Button("重新确认…") {
                                    let key = row.id
                                    tools.scan {
                                        if selectedID == key, selected?.manageable == true, selected?.pending != nil { confirming = true }
                                    }
                                }.disabled(tools.busy)
                            }
                        }
                    }
                } else {
                    Text("开启需要的工具，关闭暂时不用的工具。").fontWeight(.medium)
                    Text("更改会在 Codex 全部退出后应用，不会打断正在执行的任务。内存显示为 — 时，表示尚未关联到本地进程。")
                        .foregroundStyle(PawTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            if !tools.notice.isEmpty { Text(tools.notice).font(.system(size: 11)).foregroundStyle(PawTheme.lavender).lineLimit(2) }
            if !tools.error.isEmpty { Text(tools.error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2).help(tools.error) }
            HStack {
                Text(tools.updated.map { "检查于 " + DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "正在读取…")
                    .font(.system(size: 11)).foregroundStyle(PawTheme.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 660, height: 540).foregroundStyle(PawTheme.text).background(PawTheme.background)
            .onAppear { tools.scan() }
            .alert("重新确认更改？", isPresented: $confirming) {
                Button("取消", role: .cancel) { }
                Button("确认") { if let row = selected, let pending = row.pending { tools.request(row.id, enabled: pending.targetEnabled, reconfirm: true) } }
            } message: {
                Text("当前自动加载为\(selected?.enabled == true ? "开启" : "关闭")。将按现在的配置，重新预约\(selected?.pending?.targetEnabled == true ? "开启" : "关闭")「\(selected?.title ?? "此工具")」。仍会等 Codex 完全退出后才应用。")
            }
    }
    private func detail(_ row: CodexToolRow) -> String {
        if let pending = row.pending {
            if pending.status == .conflict { return "配置在预约后发生了变化。请刷新核对；可撤销，或重新确认此项。" }
            if pending.status == .failed { return "上次未能应用，配置未确认改变。请刷新后重试，也可撤销。" }
            return "已预约\(pending.targetEnabled ? "开启" : "关闭")。退出所有 Codex 窗口及命令行任务后自动应用；当前连接保持，尚未释放内存。"
        }
        if row.manageable {
            if row.enabled == false, (row.count ?? 0) > 0 {
                return "自动加载已关闭，旧会话仍有连接。它们会随 Codex 退出而结束；这里不会打断当前任务。"
            }
            return "可管理此工具的自动加载。更改可撤销，应用前会备份原配置；不会结束当前进程。"
        }
        if row.reason == "由 Codex 管理" { return "这是 Codex 的共享基础工具，可能供多个任务使用，连接与退出由 Codex 管理。" }
        if row.reason == "受其他配置控制" { return "插件的实际开关与用户配置不一致，可能受其他配置层控制；暂不在这里修改。" }
        return "尚未核实配置来源，暂不能安全更改。这里保留占用信息，不按 Node 名称结束进程。"
    }
}
