import SwiftUI
import AppKit

struct OverviewPage: View {
    @ObservedObject var model: CareModel
    @ViewState private var showHealthInfo = false
    private var memory: [String: Any] { dict(model.system["memory"]) }
    private var cpu: [String: Any] { dict(model.system["cpu"]) }
    private var hardware: [String: Any] { dict(model.system["hardware"]) }
    private var battery: [String: Any] { (model.system["batteries"] as? [[String: Any]])?.first ?? [:] }
    private var disk: [String: Any] {
        let disks = model.system["disks"] as? [[String: Any]] ?? []
        return disks.first(where: { safeString($0["mount"]) == "/" }) ?? disks.first ?? [:]
    }
    private var freeDisk: Double? {
        guard let total = number(disk["total"]), let used = number(disk["used"]), total > 0, used >= 0 else { return nil }
        return max(0, total - used)
    }
    private func fraction(_ used: Double?, _ total: Double?) -> Double? {
        guard let used, let total, total > 0, used >= 0 else { return nil }
        return used / total
    }
    private var overviewStatusTitle: String {
        switch model.latest?.pressure ?? .unknown {
        case .critical: return "内存压力严重"
        case .warning: return "内存压力警告"
        default: return model.healthTitle
        }
    }
    private var healthTint: Color {
        switch model.latest?.pressure ?? .unknown {
        case .critical: return .red
        case .warning: return .orange
        default: break
        }
        guard model.healthScore != nil, !model.systemIsStale else { return PawTheme.secondary }
        switch model.healthTitle {
        case "需要处理": return .red
        case "需要留意": return .orange
        default: return PawTheme.accent
        }
    }
    private var hardwareLine: String {
        [safeString(hardware["model"]), safeString(hardware["cpu_model"]), safeString(hardware["total_ram"])]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var memoryValue: String {
        guard let used = number(memory["used"]), let total = number(memory["total"]), total > 0 else { return "—" }
        return String(format: "%.1f / %@ GiB", used / GiB, metricNumber(total / GiB))
    }
    private var loadDetail: String {
        let loads = ["load1", "load5", "load15"].map { number(cpu[$0]) }
        guard loads.contains(where: { $0 != nil }) else { return "负载暂不可用" }
        return "负载  " + loads.map { $0.map { String(format: "%.2f", $0) } ?? "—" }.joined(separator: " / ")
    }
    private var memoryDetail: String {
        "压力\(model.latest?.pressure.title ?? "未知") · Swap " + bytesText(number(memory["swap_used"]))
    }
    private var batteryDetail: String {
        guard !battery.isEmpty else { return "电池信息暂不可用" }
        let rawStatus = safeString(battery["status"])
        let status: String
        switch rawStatus.lowercased() {
        case "charging": status = "正在充电"
        case "discharging": status = "使用电池"
        case "charged", "full", "fully charged": status = "已充满"
        case "ac power", "ac", "plugged in": status = "已接电源"
        case "": status = "状态未知"
        default: status = rawStatus
        }
        let rawHealth = safeString(battery["health"])
        let health: String
        switch rawHealth.lowercased() {
        case "normal", "good": health = "正常"
        case "", "unknown": health = ""
        default: health = rawHealth
        }
        return status + (health.isEmpty ? "" : " · 健康\(health)")
    }
    private var memoryTint: Color {
        switch model.latest?.pressure ?? .unknown {
        case .critical: return .red
        case .warning: return .orange
        case .normal: return PawTheme.accent
        case .unknown: return PawTheme.secondary
        }
    }
    private var freshnessText: String {
        guard let updated = model.systemUpdatedAt else { return model.systemRefreshing ? "正在采集本机状态…" : "尚无系统采样" }
        let date = DateFormatter.localizedString(from: updated, dateStyle: model.systemIsStale ? .short : .none, timeStyle: .medium)
        return (model.systemIsStale ? "上次数据 · " : "更新于 ") + date
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    healthHeader
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible())], alignment: .leading, spacing: 24) {
                        OverviewMetric(title: "CPU", symbol: "cpu", value: percentText(number(cpu["usage"])),
                                       detail: loadDetail, fraction: number(cpu["usage"]).map { $0 / 100 })
                        OverviewMetric(title: "内存", symbol: "memorychip", value: memoryValue,
                                       detail: memoryDetail, fraction: fraction(number(memory["used"]), number(memory["total"])), tint: memoryTint)
                        OverviewMetric(title: "磁盘", symbol: "cylinder.split.1x2", value: freeDisk.map { bytesText($0) + " 可用" } ?? "—",
                                       detail: "已用 " + bytesText(number(disk["used"])) + " / " + bytesText(number(disk["total"])),
                                       fraction: fraction(number(disk["used"]), number(disk["total"])))
                        OverviewMetric(title: "电池", symbol: "battery.75percent", value: percentText(number(battery["percent"])),
                                       detail: batteryDetail, fraction: number(battery["percent"]).map { $0 / 100 })
                    }
                    codexSummary
                    if !model.systemError.isEmpty {
                        MonitorMessage(text: model.systemError, tint: .orange)
                    } else if model.system.isEmpty {
                        MonitorMessage(text: "首次采集中，暂不可用的指标显示为 —。", symbol: "info.circle", tint: PawTheme.secondary)
                    }
                }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
            }
            HStack(spacing: 10) {
                Text(freshnessText).foregroundStyle(model.systemIsStale ? Color.orange : PawTheme.secondary)
                    .lineLimit(1).help(freshnessText)
                Spacer(minLength: 4)
                if model.systemRefreshing { ProgressView().controlSize(.mini) }
                Button(action: model.refreshSystem) { Label("刷新", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless).foregroundStyle(PawTheme.lavender).disabled(model.systemRefreshing)
                    .help("重新采集本机状态").accessibilityIdentifier("refresh-overview")
            }.font(.system(size: 11)).padding(.horizontal, 24).padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(PawTheme.separator).frame(height: 1) }
        }
        .foregroundStyle(PawTheme.text).background(PawTheme.background)
        .onAppear { model.refreshSystemIfStale() }
    }

    private var healthHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Circle().fill(healthTint).frame(width: 12, height: 12).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text(model.healthScore.map(String.init) ?? "—")
                        .font(.system(size: 28, weight: .semibold, design: .monospaced)).foregroundStyle(healthTint)
                    Text("分").font(.system(size: 13))
                    Text(overviewStatusTitle).font(.system(size: 22, weight: .semibold)).foregroundStyle(healthTint).lineLimit(1).minimumScaleFactor(0.8)
                }.accessibilityElement(children: .combine)
                HStack(spacing: 7) {
                    Text("Mole 健康评分").font(.system(size: 12)).foregroundStyle(PawTheme.secondary)
                    Button { showHealthInfo.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(PawTheme.secondary).help("健康评分说明").accessibilityLabel("健康评分说明")
                        .popover(isPresented: $showHealthInfo, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Mole 健康评分").font(.system(size: 14, weight: .semibold)).foregroundStyle(PawTheme.lavender)
                                Text("分数直接来自 Mole 的本机状态采集。Lightpaw 展示分数与对应状态，不另算一套评分。")
                                Text("此评分用于概览，不能替代内存压力或故障诊断；未提供可核实的逐项扣分时，不展示扣分明细。")
                                let message = safeString(model.system["health_score_msg"])
                                if !message.isEmpty { Text("Mole 原始说明：\(message)").foregroundStyle(PawTheme.secondary).textSelection(.enabled) }
                                Text(freshnessText).font(.system(size: 11)).foregroundStyle(PawTheme.secondary)
                            }.font(.system(size: 12)).foregroundStyle(PawTheme.text).padding(16).frame(width: 320).background(PawTheme.background)
                        }
                    if model.systemIsStale && model.systemUpdatedAt != nil {
                        Text("旧数据").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                    }
                }
                Text(hardwareLine.isEmpty ? "正在读取硬件信息…" : hardwareLine)
                    .font(.system(size: 12)).foregroundStyle(PawTheme.secondary).lineLimit(1).truncationMode(.middle).help(hardwareLine)
            }.frame(maxWidth: .infinity, alignment: .leading)
            AnimatedCat(active: model.mainWindowVisible).frame(width: 100, height: 76).accessibilityHidden(true)
        }
    }

    private var codexSummary: some View {
        HStack(spacing: 12) {
            Label("Codex", systemImage: "terminal").font(.system(size: 13, weight: .medium)).foregroundStyle(PawTheme.lavender)
            Circle().fill(memoryTint).frame(width: 7, height: 7)
                .help(model.latest.map { "系统内存压力\($0.pressure.title)" } ?? "等待采样")
            Text(footprintText(model.latest?.totalFootprintBytes)).font(.system(size: 13, design: .monospaced))
                .help(model.latest?.complete == false ? "进程采集不完整，总量暂不可用" : "Codex 进程树物理内存占用合计")
            MemoryMiniBars(values: model.memoryPoints).frame(maxWidth: .infinity).frame(height: 25)
            Button { model.page = .codex } label: {
                HStack(spacing: 5) { Text("查看趋势"); Image(systemName: "arrow.right") }
            }.buttonStyle(.borderless).foregroundStyle(PawTheme.lavender).font(.system(size: 12))
        }.padding(.top, 17)
            .overlay(alignment: .top) { Rectangle().fill(PawTheme.separator).frame(height: 1) }
    }
}

private struct OverviewMetric: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    let fraction: Double?
    var tint: Color = PawTheme.accent
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonitorRule()
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(PawTheme.lavender)
            Text(value).font(.system(size: 26, weight: .semibold, design: .monospaced))
                .foregroundStyle(PawTheme.text).lineLimit(1).minimumScaleFactor(0.75)
            DottedMeter(fraction: fraction, tint: tint, height: 9)
            Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(PawTheme.secondary)
                .lineLimit(1).minimumScaleFactor(0.85).help(detail)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

private struct ProcessTableItem: Identifiable {
    let process: ProcessReading
    var id: Int32 { process.pid }
}

struct CodexPage: View {
    @ObservedObject var model: CareModel
    @ViewState private var showEvents = false
    @ViewState private var showTools = false
    private var processes: [ProcessTableItem] {
        (model.latest?.processes ?? []).sorted { ($0.footprintBytes ?? 0) > ($1.footprintBytes ?? 0) }.map { ProcessTableItem(process: $0) }
    }
    private var validPointCount: Int { model.memoryPoints.compactMap { $0 }.count }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("当前内存占用", systemImage: "chart.bar").font(.system(size: 12, weight: .medium)).foregroundStyle(PawTheme.lavender)
                        Text(footprintText(model.latest?.totalFootprintBytes)).font(.system(size: 27, weight: .semibold, design: .monospaced))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("Codex 进程树").font(.system(size: 12)).foregroundStyle(PawTheme.lavender)
                        Text(model.latest.map { "\($0.processCount) 个进程" } ?? "—").font(.system(size: 14, weight: .medium)).monospacedDigit()
                    }
                }
                CodexMemoryTrend(values: model.memoryPoints).frame(height: 111)
                if validPointCount < 2 {
                    MonitorMessage(text: "有效采样不足 2 次，继续记录后显示趋势连线。", symbol: "info.circle", tint: PawTheme.secondary)
                }
                if model.latest?.complete == false {
                    MonitorMessage(text: "本次进程读取不完整，总量暂不可用；已读到的进程仍显示。", tint: .orange)
                }
                if model.latest?.suggestReduceParallelism == true {
                    MonitorMessage(text: "连续高占用，建议减少并行任务。", tint: .orange)
                }
                if let error = model.monitorLogError { MonitorMessage(text: error, tint: .orange) }
            }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 12)
            MonitorRule().padding(.horizontal, 22)
            if processes.isEmpty {
                EmptyCare(symbol: "waveform.path", title: model.latest == nil ? "等待进程采样" : "本次未读取到 Codex 进程",
                          detail: "每 10 秒读取一次。Codex 退出后，记录仍会保留。")
            } else {
                Table(processes) {
                    TableColumn("进程") { item in
                        HStack(spacing: 7) {
                            Circle().fill(item.process.footprintBytes == nil ? Color.orange : PawTheme.accent).frame(width: 5, height: 5)
                            Text(item.process.basename).foregroundStyle(PawTheme.text).lineLimit(1).help(item.process.basename)
                        }
                    }.width(min: 180, ideal: 240)
                    TableColumn("类型") { item in Text(item.process.category).foregroundStyle(PawTheme.secondary).lineLimit(1) }.width(min: 75, ideal: 90)
                    TableColumn("PID") { item in Text(String(item.process.pid)).monospacedDigit().foregroundStyle(PawTheme.secondary) }.width(62)
                    TableColumn("内存") { item in Text(bytesText(item.process.footprintBytes.map { Double($0) })).monospacedDigit().foregroundStyle(PawTheme.text) }.width(min: 80, ideal: 100)
                }.font(.system(size: 12)).scrollContentBackground(.hidden).background(PawTheme.background).frame(maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                Button("后台工具…") { showTools = true }
                    .foregroundStyle(PawTheme.lavender).accessibilityIdentifier("codex-tools")
                Button("进程变化\(model.memoryEvents.isEmpty ? "" : " · \(model.memoryEvents.count)")") { showEvents = true }
                    .foregroundStyle(PawTheme.lavender)
                Spacer(minLength: 4)
                Text("日志保留 7 天 / 最多 20 MiB").font(.system(size: 10)).foregroundStyle(PawTheme.secondary)
                Button("打开日志") { NSWorkspace.shared.open(model.logsURL) }.foregroundStyle(PawTheme.lavender)
            }.font(.system(size: 12)).padding(.horizontal, 22).padding(.vertical, 11)
                .overlay(alignment: .top) { Rectangle().fill(PawTheme.separator).frame(height: 1) }
        }.foregroundStyle(PawTheme.text).background(PawTheme.background)
        .sheet(isPresented: $showTools) { CodexToolsSheet(tools: model.toolManager) }
        .sheet(isPresented: $showEvents) {
            VStack(alignment: .leading, spacing: 14) {
                Text("进程变化").font(.system(size: 16, weight: .semibold)).foregroundStyle(PawTheme.lavender)
                Text("进程更换不等于崩溃，退出原因需结合系统报告判断。")
                    .font(.system(size: 12)).foregroundStyle(PawTheme.secondary)
                List {
                    if model.memoryEvents.isEmpty { Text("本次观察尚未检测到进程更换。").foregroundStyle(PawTheme.secondary) }
                    ForEach(model.memoryEvents, id: \.self) { Text($0).font(.system(size: 12)).textSelection(.enabled).padding(.vertical, 5) }
                }.scrollContentBackground(.hidden).frame(height: 240)
                HStack {
                    Text("保留 7 天 / 最多 20 MiB").font(.system(size: 11)).foregroundStyle(PawTheme.secondary)
                    Spacer()
                    Button("关闭") { showEvents = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 560).foregroundStyle(PawTheme.text).background(PawTheme.background)
        }
    }
}

private struct MonitorRule: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: geometry.size.width, y: 0)) }
                .stroke(PawTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        }.frame(height: 1).accessibilityHidden(true)
    }
}

private struct MonitorMessage: View {
    let text: String
    var symbol = "exclamationmark.triangle"
    var tint: Color = .orange
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).foregroundStyle(PawTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MemoryMiniBars: View {
    let values: [Double?]
    var body: some View {
        Canvas { context, size in
            let ceiling = max(1, (values.compactMap { $0 }.max() ?? 0) * 1.1)
            let step = size.width / CGFloat(max(values.count, 1))
            let width = min(4, max(1, step - 2))
            for (index, value) in values.enumerated() {
                guard let value, value.isFinite, value >= 0 else { continue }
                let height = max(1, size.height * min(1, value / ceiling))
                let x = values.count == 1 ? size.width - width : CGFloat(index + 1) * step - width
                context.fill(Path(CGRect(x: x, y: size.height - height, width: width, height: height)), with: .color(PawTheme.accent))
            }
        }.accessibilityLabel("Codex 迷你趋势，最近 \(values.count) 次采样，缺失采样留空")
    }
}

private struct CodexMemoryTrend: View {
    let values: [Double?]
    private var ceiling: Double { max(8, (values.compactMap { $0 }.max() ?? 0) * 1.15) }
    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let plotWidth = max(1, geometry.size.width - 42)
                let plotHeight = max(1, geometry.size.height - 4)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for fraction in [0.0, 0.5, 1.0] {
                            var line = Path()
                            line.move(to: CGPoint(x: 0, y: plotHeight * fraction))
                            line.addLine(to: CGPoint(x: plotWidth, y: plotHeight * fraction))
                            context.stroke(line, with: .color(PawTheme.separator), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
                        }
                        var reference = Path()
                        reference.move(to: CGPoint(x: 0, y: plotHeight * (1 - 8 / ceiling)))
                        reference.addLine(to: CGPoint(x: plotWidth, y: plotHeight * (1 - 8 / ceiling)))
                        context.stroke(reference, with: .color(PawTheme.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        var line = Path(); var started = false
                        for (index, value) in values.enumerated() {
                            guard let value, value.isFinite, value >= 0 else { started = false; continue }
                            let x = values.count == 1 ? plotWidth : plotWidth * Double(index) / Double(values.count - 1)
                            let point = CGPoint(x: x, y: plotHeight * (1 - min(1, value / ceiling)))
                            if started { line.addLine(to: point) } else { line.move(to: point); started = true }
                            context.fill(Path(ellipseIn: CGRect(x: point.x - 1.8, y: point.y - 1.8, width: 3.6, height: 3.6)), with: .color(PawTheme.accent))
                        }
                        context.stroke(line, with: .color(PawTheme.accent), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    }
                    Text("8 GiB").font(.system(size: 9)).monospacedDigit().foregroundStyle(PawTheme.secondary)
                        .offset(x: plotWidth + 6, y: max(0, plotHeight * (1 - 8 / ceiling) - 5))
                }
            }
            HStack {
                Text("最近 \(values.count) 次采样")
                Spacer()
                Text("每 10 秒记录")
            }.font(.system(size: 10)).foregroundStyle(PawTheme.secondary)
            Text("缺失采样留空 · 8 GiB 为观察参考线，非内存上限")
                .font(.system(size: 9)).foregroundStyle(PawTheme.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityLabel("Codex 内存趋势，共 \(values.count) 次实际采样；缺失采样留空；8 GiB 是观察参考线，不是内存上限")
    }
}

private func footprintText(_ bytes: UInt64?) -> String {
    bytes.map { String(format: "%.2f GiB", Double($0) / GiB) } ?? "—"
}

private func metricNumber(_ value: Double) -> String {
    value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
}
