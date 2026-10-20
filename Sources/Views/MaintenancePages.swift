import SwiftUI
import AppKit

struct DiskPage: View {
    @ObservedObject var model: CareModel
    var body: some View {
        VStack(spacing: 0) {
            PageToolbar {
                Button("选择文件夹…", action: model.chooseDirectory).disabled(model.jobBusy)
                Menu("常用位置") {
                    Button("主目录") { model.scanDisk(FileManager.default.homeDirectoryForCurrentUser.path) }
                    Button("应用程序") { model.scanDisk("/Applications") }
                }.disabled(model.jobBusy)
                Spacer()
                Button { model.scanDisk() } label: { Label("重新分析", systemImage: "arrow.clockwise") }.disabled(model.jobBusy)
            }
            HStack(spacing: 10) {
                Button { model.scanDisk(URL(fileURLWithPath: model.diskPath).deletingLastPathComponent().path) } label: {
                    Image(systemName: "arrow.up")
                }.disabled(model.jobBusy || model.diskPath == "/").help("上一级目录").accessibilityLabel("上一级目录")
                VStack(alignment: .leading, spacing: 3) {
                    Text(shortPath(model.diskPath)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(model.diskPath)
                    Text(model.diskStatus).font(.system(size: 11)).foregroundStyle(PawTheme.secondary)
                }
                Spacer(minLength: 8)
                Text(bytesText(model.diskTotal)).font(.system(size: 14, weight: .medium)).monospacedDigit()
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if model.diskEntries.isEmpty {
                EmptyCare(symbol: "folder", title: model.jobBusy ? "正在分析目录" : "查找空间占用", detail: "选择文件夹，逐层查看实际占用。")
            } else {
                Table(model.diskEntries, selection: $model.selectedDisk) {
                    TableColumn("名称") { item in
                        HStack(spacing: 7) {
                            Image(systemName: item.isDirectory ? "folder" : "doc").foregroundStyle(PawTheme.secondary).frame(width: 16)
                            Text(item.name).lineLimit(1)
                            if item.isDirectory {
                                Spacer(minLength: 4)
                                Button { model.scanDisk(item.path) } label: { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                                    .buttonStyle(.borderless).disabled(model.jobBusy).help("进入 \(item.name)").accessibilityLabel("进入 \(item.name)")
                            }
                        }
                    }.width(min: 220, ideal: 320)
                    TableColumn("占用") { item in Text(item.sizeLabel).monospacedDigit() }.width(min: 85, ideal: 105)
                    TableColumn("比例") { item in
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(PawTheme.separator)
                                Capsule().fill(PawTheme.accent).frame(width: geometry.size.width * min(1, max(0, (item.size ?? 0) / max(model.diskTotal ?? 1, 1))))
                            }.frame(height: 5).frame(maxHeight: .infinity)
                        }
                    }.width(min: 85, ideal: 120)
                }.font(.system(size: 13)).scrollContentBackground(.hidden).background(Color.clear).frame(maxHeight: .infinity)
            }
            PageFooter {
                Text("\(model.diskEntries.count) 个条目 · + 表示部分测量").font(.system(size: 11)).foregroundStyle(PawTheme.secondary)
                Spacer()
                Button("在 Finder 中显示") { if let path = model.selectedDisk { model.reveal(path) } }.disabled(model.selectedDisk == nil)
            }
        }.foregroundStyle(PawTheme.text).background(PawTheme.background)
    }
}

struct CleanPage: View {
    @ObservedObject var model: CareModel
    @ViewState private var showScanOutput = false
    @ViewState private var detailEntry: CleanupEntry?
    @ViewState private var showProtected = false

    // Keep this predicate identical to CareModel.selectAllClean, including its scope.
    private var visibleEntries: [CleanupEntry] {
        model.cleanEntries.filter { model.cleanSearch.isEmpty || ($0.path + " " + $0.section).localizedCaseInsensitiveContains(model.cleanSearch) }
    }
    private var selectableEntries: [CleanupEntry] { visibleEntries.filter { model.cleanupRestriction($0) == nil } }
    private var protectedEntries: [CleanupEntry] { visibleEntries.filter { model.cleanupRestriction($0) != nil } }
    private var categories: [String] {
        var seen = Set<String>()
        return selectableEntries.compactMap { seen.insert(category($0)).inserted ? category($0) : nil }
    }
    private var allVisibleSelected: Bool {
        !selectableEntries.isEmpty && selectableEntries.allSatisfy { model.selectedCleanIDs.contains($0.id) }
    }
    private var emptyScanMessage: (title: String, detail: String) {
        switch model.cleanupScanState {
        case .idle:
            return ("选择需要清理的内容", "先扫描，再勾选需要处理的项目。")
        case .running:
            return ("正在扫描可清理项目", "扫描完成后可选择项目；可在底部取消扫描。")
        case .ready:
            return ("未发现可清理项目", "本次扫描已完成，可稍后重新扫描。")
        case .cancelled:
            return ("扫描已取消", "文件未改动。重新扫描后可选择清理项目。")
        case .failed:
            return ("扫描未完成", "请查看底部“详情”了解原因，然后重新扫描。")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(PawTheme.secondary)
                    TextField("搜索项目", text: $model.cleanSearch).textFieldStyle(.plain)
                        .help("搜索项目路径或扫描分类")
                }.padding(.horizontal, 9).padding(.vertical, 7)
                    .background(PawTheme.sidebar.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                Button { model.previewMaintenance("clean") } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).frame(width: 24, height: 26)
                    .disabled(model.jobBusy).help("重新扫描").accessibilityLabel("重新扫描")
                    .accessibilityIdentifier("preview-clean")
                Menu {
                    Button(allVisibleSelected ? "取消选择当前项目" : "全选当前可清理项目") { model.selectAllClean(!allVisibleSelected) }
                        .disabled(selectableEntries.isEmpty || model.jobBusy)
                    Divider()
                    Toggle("永久删除（无法撤销）", isOn: $model.permanentCleanup).disabled(model.jobBusy)
                    Divider()
                    Button("查看保护规则", action: model.viewProtection)
                    Button("完整扫描结果") { showScanOutput = true }.disabled(model.cleanPreview.isEmpty)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 24).help("更多清理选项")
                    .accessibilityLabel("更多清理选项")
            }
            if model.cleanEntries.isEmpty {
                EmptyCare(symbol: "paintbrush", title: emptyScanMessage.title, detail: emptyScanMessage.detail)
            } else if visibleEntries.isEmpty {
                EmptyCare(symbol: "magnifyingglass", title: "没有匹配项目", detail: "尝试其他路径或分类。")
            } else {
                List {
                    ForEach(categories, id: \.self) { title in
                        Section {
                            ForEach(selectableEntries.filter { category($0) == title }) { entry in
                                cleanRow(entry).listRowBackground(Color.clear).listRowSeparatorTint(PawTheme.separator)
                            }
                        } header: {
                            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(PawTheme.lavender)
                        }
                    }
                    if !protectedEntries.isEmpty {
                        DisclosureGroup(isExpanded: $showProtected) {
                            ForEach(protectedEntries) { entry in
                                protectedRow(entry).listRowBackground(Color.clear).listRowSeparatorTint(PawTheme.separator)
                            }
                        } label: {
                            Text("已保护 \(protectedEntries.count) 项").font(.system(size: 12)).foregroundStyle(PawTheme.secondary)
                        }.padding(.vertical, 4).listRowBackground(Color.clear)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden).background(Color.clear)
                    .environment(\.defaultMinListRowHeight, 42)
            }
            PageFooter {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.cleanSelectionSummary).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !model.cleanEntries.isEmpty && !model.previewValid("clean") && !model.jobBusy {
                        Text("扫描已过期或保护规则已变化，请重新扫描。")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    } else {
                        Text(model.permanentCleanup ? "永久删除无法撤销，执行前仍会核对项目。" : "清空废纸篓后释放空间")
                            .font(.system(size: 11)).foregroundStyle(model.permanentCleanup ? Color.orange : PawTheme.secondary)
                    }
                }
                Spacer(minLength: 8)
                if model.cleanEntries.isEmpty || !model.previewValid("clean") {
                    Button(model.cleanEntries.isEmpty ? "扫描可清理项目" : "重新扫描") { model.previewMaintenance("clean") }
                        .buttonStyle(.borderedProminent).tint(PawTheme.accent).foregroundStyle(PawTheme.background)
                        .disabled(model.jobBusy).accessibilityIdentifier("preview-clean-primary")
                } else {
                    Button(model.permanentCleanup ? "永久删除…" : "移到废纸篓…", action: model.executeSelectedCleanup)
                        .buttonStyle(.borderedProminent).tint(model.permanentCleanup ? .red : PawTheme.accent)
                        .foregroundStyle(model.permanentCleanup ? Color.white : PawTheme.background)
                        .disabled(model.selectedCleanIDs.isEmpty || model.jobBusy || !model.mutationSupported)
                        .accessibilityIdentifier("execute-clean")
                }
            }
        }.font(.system(size: 13)).foregroundStyle(PawTheme.text).tint(PawTheme.accent).background(PawTheme.background)
        .sheet(isPresented: $showScanOutput) {
            VStack(alignment: .leading, spacing: 14) {
                Text("扫描结果").font(.system(size: 16, weight: .semibold))
                ReadableOutput(text: model.cleanPreview, height: 340)
                HStack { Spacer(); Button("关闭") { showScanOutput = false }.keyboardShortcut(.defaultAction) }
            }.padding(20).frame(width: 580).foregroundStyle(PawTheme.text).background(PawTheme.background)
        }
        .sheet(item: $detailEntry) { entry in
            VStack(alignment: .leading, spacing: 12) {
                Text(friendlyName(entry)).font(.system(size: 16, weight: .semibold))
                Text(entry.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Text(entry.section + " · " + entry.detail).font(.system(size: 12)).foregroundStyle(PawTheme.secondary)
                if let reason = model.cleanupRestriction(entry) { Notice(text: reason, symbol: "lock", tint: .orange) }
                HStack {
                    Button("在 Finder 中显示") { model.reveal(entry.path) }
                    Spacer()
                    Button("关闭") { detailEntry = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 540).foregroundStyle(PawTheme.text).background(PawTheme.background)
        }
    }

    private func cleanRow(_ entry: CleanupEntry) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.selectedCleanIDs.contains(entry.id) }, set: { _ in model.toggleCleanSelection(entry) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(model.jobBusy)
                .accessibilityLabel("选择 " + rowName(entry))
            Text(rowName(entry)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(sizeLabel(entry)).monospacedDigit().foregroundStyle(PawTheme.secondary).lineLimit(1)
        }.frame(minHeight: 38).help(entry.path + "\n" + entry.detail)
            .contextMenu {
                Button("查看项目详情") { detailEntry = entry }
                Button("在 Finder 中显示") { model.reveal(entry.path) }
            }
    }
    private func protectedRow(_ entry: CleanupEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock").frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(rowName(entry)).lineLimit(1).truncationMode(.middle)
                Text(model.cleanupRestriction(entry) ?? "受保护项目").font(.system(size: 11)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(sizeLabel(entry)).monospacedDigit().lineLimit(1)
        }.foregroundStyle(PawTheme.secondary).frame(minHeight: 42)
            .help(entry.path + "\n" + (model.cleanupRestriction(entry) ?? "") + "\n" + entry.detail)
            .contextMenu {
                Button("查看项目详情") { detailEntry = entry }
                Button("在 Finder 中显示") { model.reveal(entry.path) }
            }
    }
    private func category(_ entry: CleanupEntry) -> String {
        let value = entry.section.lowercased()
        if value.contains("developer") || value.contains("开发") { return "开发工具" }
        if ["user", "app", "browser", "cloud", "office"].contains(where: value.contains) { return "应用缓存" }
        return "其他项目"
    }
    private func friendlyName(_ entry: CleanupEntry) -> String {
        let name = URL(fileURLWithPath: entry.path).lastPathComponent
        let labels = ["Caches": "缓存", "Cache": "缓存", "cache": "缓存", "Logs": "日志", "logs": "日志", "tmp": "临时文件", "CrashReporter": "崩溃报告", "DiagnosticReports": "诊断报告", "DerivedData": "Xcode 构建缓存", "Homebrew": "Homebrew 缓存", "QuickLook": "快速预览缓存"]
        return labels[name] ?? (name.isEmpty ? entry.path : name)
    }
    private func rowName(_ entry: CleanupEntry) -> String {
        let name = friendlyName(entry)
        let peers = model.cleanEntries.filter { friendlyName($0) == name && $0.path != entry.path }
        guard !peers.isEmpty else { return name }
        let parent = URL(fileURLWithPath: entry.path).deletingLastPathComponent().pathComponents
        // Add only the shortest distinct parent suffix when names would otherwise collide.
        for count in 1...max(1, parent.count) {
            let suffix = parent.suffix(count).joined(separator: "/")
            if !peers.contains(where: { URL(fileURLWithPath: $0.path).deletingLastPathComponent().pathComponents.suffix(count).joined(separator: "/") == suffix }) {
                return name + " · " + suffix
            }
        }
        return name + " · " + shortPath(entry.path)
    }
    private func sizeLabel(_ entry: CleanupEntry) -> String {
        guard let range = entry.detail.range(of: #"^[0-9]+(?:\.[0-9]+)?\s*(?:GB|MB|KB|B)"#, options: .regularExpression) else { return "大小未知" }
        return String(entry.detail[range])
    }
}

struct OptimizePage: View {
    @ObservedObject var model: CareModel
    private let topics = [
        ("doc", "Quick Look 与图标", "检查预览与图标缓存"),
        ("network", "DNS 与网络", "检查网络相关维护项"),
        ("externaldrive", "索引与磁盘", "检查数据库、索引与磁盘状态")
    ]
    var body: some View {
        VStack(spacing: 0) {
            PageToolbar {
                Text(model.optimizePreview.isEmpty ? "维护范围 · 尚未预览" : "维护预览")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(PawTheme.lavender)
                Spacer()
                Button { model.previewMaintenance("optimize") } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).frame(width: 24, height: 26)
                    .disabled(model.jobBusy).help("重新预览").accessibilityLabel("重新预览")
                    .accessibilityIdentifier("preview-optimize")
                Menu {
                    Button("查看保护规则", action: model.viewProtection)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 24).help("维护选项")
            }
            if model.optimizePreview.isEmpty {
                VStack(spacing: 0) {
                    ForEach(topics, id: \.1) { topic in
                        HStack(spacing: 14) {
                            Image(systemName: topic.0).font(.system(size: 20, weight: .light)).foregroundStyle(PawTheme.lavender).frame(width: 26)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(topic.1).foregroundStyle(PawTheme.lavender)
                                Text(topic.2).font(.system(size: 12)).foregroundStyle(PawTheme.secondary)
                            }
                            Spacer()
                        }.frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                        Rectangle().fill(PawTheme.separator).frame(height: 1)
                    }
                    Spacer(minLength: 12)
                }.padding(.horizontal, 20).padding(.top, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(model.optimizePreview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
                }.background(Color.clear).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            PageFooter {
                Label("可能短暂影响网络或重启 Finder，请在空闲时执行。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.previewValid("optimize") {
                    Button("检查并继续…") { model.executeMaintenance("optimize") }
                        .buttonStyle(.borderedProminent).tint(PawTheme.accent).foregroundStyle(PawTheme.background)
                        .disabled(model.jobBusy || !model.mutationSupported)
                        .accessibilityIdentifier("execute-optimize")
                } else {
                    Button("预览维护项目") { model.previewMaintenance("optimize") }
                        .buttonStyle(.borderedProminent).tint(PawTheme.accent).foregroundStyle(PawTheme.background)
                        .disabled(model.jobBusy).accessibilityIdentifier("preview-optimize-primary")
                }
            }
        }.font(.system(size: 13)).foregroundStyle(PawTheme.text).background(PawTheme.background)
    }
}
