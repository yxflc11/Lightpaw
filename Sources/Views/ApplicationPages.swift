import SwiftUI
import AppKit

struct AppsPage: View {
    @ObservedObject var model: CareModel
    var body: some View {
        VStack(spacing: 0) {
            PageToolbar {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(PawTheme.secondary)
                    TextField("搜索应用", text: $model.appSearch).textFieldStyle(.plain).help("搜索应用名称或 Homebrew 标识")
                }.padding(.horizontal, 9).padding(.vertical, 7)
                    .background(PawTheme.sidebar.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                Button(action: model.refreshApplicationList) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).frame(width: 24, height: 26)
                    .disabled(model.jobBusy).help("重新读取本机安装列表").accessibilityLabel("刷新应用列表")
                    .accessibilityIdentifier("load-apps")
                Button("检查更新", action: model.checkBrewUpdates)
                    .disabled(model.jobBusy).help("刷新 Homebrew 与配方元数据，检查已安装应用的新版本")
                    .accessibilityIdentifier("check-brew-updates")
            }
            HStack {
                Picker("应用来源", selection: $model.applicationFilter) {
                    ForEach(ApplicationFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 278).disabled(model.jobBusy)
                Spacer(minLength: 10)
                if model.applicationFilter != .all {
                    Text(model.brewStatusText).font(.system(size: 11)).foregroundStyle(PawTheme.secondary)
                        .lineLimit(1).help(model.brewStatusText)
                }
            }.padding(.horizontal, 20).padding(.bottom, 10)
            if model.applicationFilter == .all { ordinaryList } else { homebrewList }
            PageFooter {
                if model.applicationFilter == .all { ordinaryFooter } else { homebrewFooter }
            }
        }.font(.system(size: 13)).foregroundStyle(PawTheme.text).tint(PawTheme.accent).background(PawTheme.background)
            .onChange(of: model.applicationFilter) { _ in model.applicationFilterChanged() }
    }
    @ViewBuilder private var ordinaryList: some View {
        if model.apps.isEmpty {
            EmptyCare(symbol: "square.stack.3d.up", title: model.jobBusy ? "正在读取应用" : "整理不再使用的应用", detail: "点击右上角读取列表，再选择应用检查卸载内容。")
        } else if model.filteredApps.isEmpty {
            EmptyCare(symbol: "magnifyingglass", title: "没有匹配应用", detail: "尝试其他名称或应用标识。")
        } else {
            List(selection: $model.selectedApp) {
                ForEach(model.filteredApps) { app in
                    appRow(app).tag(app.id)
                        .listRowBackground(model.selectedApp == app.id ? PawTheme.accent.opacity(0.13) : Color.clear)
                        .listRowSeparatorTint(PawTheme.separator)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).background(Color.clear)
                .environment(\.defaultMinListRowHeight, 46).frame(maxHeight: .infinity)
        }
    }
    @ViewBuilder private var homebrewList: some View {
        if model.brewSnapshot == nil {
            EmptyCare(symbol: "shippingbox", title: model.jobBusy ? "正在读取 Homebrew" : model.brewCatalogError.isEmpty ? "你的 Homebrew 应用" : "暂时无法读取", detail: model.brewCatalogError.isEmpty ? "读取本机安装记录，即可查看应用和版本。" : "点击刷新重试，详情中保留了失败原因。")
        } else if model.filteredBrewApps.isEmpty {
            EmptyCare(symbol: "shippingbox", title: brewEmptyTitle, detail: brewEmptyDetail)
        } else {
            List(selection: $model.selectedBrewToken) {
                ForEach(model.filteredBrewApps) { item in
                    brewRow(item).tag(item.token)
                        .listRowBackground(model.selectedBrewToken == item.token ? PawTheme.accent.opacity(0.13) : Color.clear)
                        .listRowSeparatorTint(PawTheme.separator)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).background(Color.clear)
                .environment(\.defaultMinListRowHeight, 56).frame(maxHeight: .infinity)
        }
    }
    private var brewEmptyTitle: String {
        if !model.appSearch.isEmpty { return "没有匹配应用" }
        if model.applicationFilter == .updates { return model.brewResultsFresh ? "没有发现可用更新" : "先检查应用更新" }
        return "尚未安装 Homebrew 应用"
    }
    private var brewEmptyDetail: String {
        if !model.appSearch.isEmpty { return "尝试其他应用名称或 Homebrew 标识。" }
        if model.applicationFilter == .updates { return model.brewResultsFresh ? "本次检查的版本信息已更新，固定版本和特殊配方可在 Homebrew 列表查看。" : "点击“检查更新”，读取最新配方后再决定是否更新。" }
        return "这里只显示通过 Homebrew 安装的应用，不包含命令行工具。"
    }
    @ViewBuilder private var ordinaryFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.chosenApp == nil ? "已选 0 个应用" : "已选 1 个应用").font(.system(size: 13, weight: .medium))
            if let app = model.chosenApp, let reason = model.appRestriction(app) {
                Label(reason, systemImage: "lock").font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1).help(reason)
            }
        }
        Spacer(minLength: 8)
        Button("检查卸载内容…") { model.prepareUninstall() }
            .buttonStyle(.borderedProminent).tint(PawTheme.accent).foregroundStyle(PawTheme.background)
            .disabled(model.chosenApp == nil || model.jobBusy || model.chosenApp.map { model.appRestriction($0) != nil } == true)
            .accessibilityIdentifier("prepare-uninstall")
    }
    @ViewBuilder private var homebrewFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.chosenBrewApp?.name ?? "选择一个应用").font(.system(size: 13, weight: .medium)).lineLimit(1)
            if let item = model.chosenBrewApp {
                Text(item.unsupportedReason ?? item.status.label).font(.system(size: 11))
                    .foregroundStyle(item.unsupportedReason == nil ? PawTheme.secondary : Color.orange)
                    .lineLimit(2).help(item.unsupportedReason ?? item.status.label)
            } else {
                Text("更新前会显示版本与变更范围").font(.system(size: 11)).foregroundStyle(PawTheme.secondary)
            }
        }
        Spacer(minLength: 8)
        Button("卸载…", action: model.prepareSelectedBrewUninstall)
            .disabled(model.jobBusy || model.chosenBrewApp?.appPaths.isEmpty != false)
            .accessibilityIdentifier("prepare-brew-uninstall")
        Button("更新…", action: model.prepareBrewUpdate)
            .buttonStyle(.borderedProminent).tint(PawTheme.accent).foregroundStyle(PawTheme.background)
            .disabled(model.jobBusy || !model.brewResultsFresh || model.chosenBrewApp?.canPrepare != true)
            .accessibilityIdentifier("prepare-brew-update")
    }
    private func appRow(_ app: MoleApplication) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 26, height: 26)
            Text(app.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(app.isManaged ? "Homebrew" : "普通应用").font(.system(size: 12)).foregroundStyle(PawTheme.secondary).frame(width: 80, alignment: .leading)
            Text(app.size).monospacedDigit().foregroundStyle(PawTheme.secondary).lineLimit(1).frame(width: 76, alignment: .trailing)
        }.frame(minHeight: 42).contentShape(Rectangle()).help(app.path)
            .contextMenu { Button("在 Finder 中显示") { model.reveal(app.path) } }
    }
    private func brewRow(_ item: BrewUpdateItem) -> some View {
        HStack(spacing: 10) {
            if let path = item.appPaths.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 28, height: 28)
            } else { Image(systemName: "shippingbox").frame(width: 28, height: 28).foregroundStyle(PawTheme.secondary) }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1)
                Text(item.token).font(.system(size: 11)).foregroundStyle(PawTheme.secondary).lineLimit(1)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.hasUpdate ? item.installedVersion + " → " + (item.availableVersion ?? "—") : item.installedVersion)
                    .monospacedDigit().lineLimit(1).truncationMode(.middle)
                Text(item.status.label).font(.system(size: 11)).foregroundStyle(item.hasUpdate ? PawTheme.accent : PawTheme.secondary)
            }.frame(maxWidth: 240, alignment: .trailing)
        }.frame(minHeight: 50).contentShape(Rectangle())
            .help(item.source + (item.bundleVersion.map { " · 应用自身版本 " + $0 } ?? "") + (item.unsupportedReason.map { "\n" + $0 } ?? ""))
    }
}

struct BrewUpdateReviewSheet: View {
    @ObservedObject var model: CareModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("更新 " + (model.pendingBrewUpdate?.name ?? "应用")).font(.system(size: 16, weight: .semibold))
            ScrollView {
                Text(model.pendingBrewUpdate?.preview ?? "").font(.system(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.frame(height: 250).background(PawTheme.sidebar.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            Text("仅更新所选应用。更新会替换旧版本；取消不能撤回已经完成的步骤。")
                .font(.system(size: 12)).foregroundStyle(PawTheme.secondary)
            HStack {
                Button("取消", action: model.cancelOperation).keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认更新", action: model.confirmBrewUpdate)
                    .buttonStyle(.borderedProminent).tint(PawTheme.accent).foregroundStyle(PawTheme.background)
                    .disabled(model.pendingBrewUpdate?.canExecute != true).accessibilityIdentifier("confirm-brew-update")
            }
        }.padding(20).frame(width: 580).foregroundStyle(PawTheme.text).background(PawTheme.background)
    }
}

struct UninstallReviewSheet: View {
    @ObservedObject var model: CareModel
    @ViewState private var showScript = false
    private var reviewText: String {
        let review = model.uninstallReview ?? "正在准备清单…"
        guard let source = model.uninstallScriptSource, !source.isEmpty else { return review }
        return review.replacingOccurrences(of: source, with: "完整源码与程序校验见“脚本与来源”页。")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let app = model.pendingApp {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("卸载 \(model.pendingApp?.name ?? "应用")")
                        .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text("请核对将移除的内容").font(.system(size: 12)).foregroundStyle(PawTheme.secondary)
                }
                Spacer()
            }
            if model.uninstallScriptSource != nil {
                Picker("查看内容", selection: $showScript) {
                    Text("卸载清单").tag(false)
                    Text("脚本与来源").tag(true)
                }.pickerStyle(.segmented).frame(width: 240)
            }
            ScrollView {
                Text(showScript ? (model.uninstallScriptSource ?? "") : reviewText)
                    .font(.system(size: 12, design: showScript ? .monospaced : .default)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.frame(height: 250).background(PawTheme.sidebar.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            if model.uninstallScriptRequired {
                Toggle("我已核对脚本与来源，同意执行其中的卸载操作", isOn: $model.uninstallScriptAcknowledged)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .accessibilityIdentifier("acknowledge-uninstall-script")
            }
            if model.pendingApp?.isManaged == true {
                Notice(text: model.uninstallScriptRequired
                    ? "Homebrew 会执行上方脚本与卸载操作，脚本影响以完整源码为准。不会额外执行 zap 或自动清理依赖；已删除内容不保证可恢复。"
                    : "Homebrew 将移除清单内的应用、链接及卸载组件，不执行额外的个人数据清除，也不自动清理依赖。移除内容不保证可从废纸篓恢复。", symbol: "exclamationmark.triangle", tint: .orange)
            } else {
                Notice(text: "应用及列出的关联项目默认移到废纸篓，个人数据按清单保留。正在运行的应用会先退出。", symbol: "trash", tint: .secondary)
            }
            HStack {
                Button("取消", action: model.cancelOperation).keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认卸载", action: model.confirmUninstall)
                    .buttonStyle(.borderedProminent).tint(.red).disabled(!model.uninstallCanExecute)
                    .accessibilityIdentifier("confirm-uninstall")
            }
        }.padding(20).frame(width: 600).foregroundStyle(PawTheme.text).background(PawTheme.background)
    }
}

struct HistoryPage: View {
    @ObservedObject var model: CareModel
    var body: some View {
        VStack(spacing: 0) {
            PageToolbar {
                Text("最近 20 次操作").font(.system(size: 12)).foregroundStyle(PawTheme.secondary)
                Spacer()
                Button(action: model.refreshHistory) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.jobBusy).help("刷新记录").accessibilityLabel("刷新记录")
            }
            if model.sessions.isEmpty {
                EmptyCare(symbol: "clock.arrow.circlepath", title: "暂无操作记录", detail: "扫描、预览与实际执行均可能记录在此。")
            } else {
                List {
                    ForEach(Array(model.sessions.enumerated()), id: \.offset) { _, session in
                        historyRow(session).listRowBackground(Color.clear).listRowSeparatorTint(PawTheme.separator)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden).background(Color.clear)
            }
            PageFooter {
                Text("来源：维护台与 Mole 的本机记录").font(.system(size: 11)).foregroundStyle(PawTheme.secondary)
                Spacer()
            }
        }.font(.system(size: 13)).foregroundStyle(PawTheme.text).background(PawTheme.background)
    }
    private func historyRow(_ session: [String: Any]) -> some View {
        let actions = dict(session["actions"])
        let unfinished = safeString(session["ended_at"]).isEmpty
        let failed = Int(number(actions["failed"]) ?? 0)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: unfinished || failed > 0 ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(unfinished || failed > 0 ? Color.orange : PawTheme.secondary).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(safeString(session["command"])).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(safeString(session["size"])).monospacedDigit()
                }
                Text(safeString(session["started_at"])).font(.system(size: 11)).foregroundStyle(PawTheme.secondary)
                Text("移到废纸篓 \(Int(number(actions["trashed"]) ?? 0)) · 删除 \(Int(number(actions["removed"]) ?? 0)) · 跳过 \(Int(number(actions["skipped"]) ?? 0)) · 失败 \(failed)")
                    .font(.system(size: 11)).foregroundStyle(PawTheme.secondary)
                if unfinished { Text("缺少结束标记，完成状态未确认").font(.system(size: 11)).foregroundStyle(.orange) }
                if safeString(session["attribution"]) == "ambiguous" { Text("旧日志归属不明确，计数仅供参考").font(.system(size: 11)).foregroundStyle(PawTheme.secondary) }
            }
        }.padding(.vertical, 7)
    }
}
