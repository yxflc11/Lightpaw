import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var model: CareModel
    let onOpen: () -> Void
    let onNavigate: (CarePage) -> Void
    let onScan: () -> Void
    @ViewState private var showHealthInfo = false

    private var pressure: Pressure { model.latest?.pressure ?? .unknown }
    private var statusTitle: String {
        switch pressure {
        case .critical: return "内存压力严重"
        case .warning: return "内存压力警告"
        default: return model.healthTitle
        }
    }
    private var healthColor: Color {
        if pressure == .critical { return .red }
        if pressure == .warning { return .orange }
        guard model.healthScore != nil, !model.systemIsStale else { return PawTheme.secondary }
        switch model.healthTitle {
        case "需要处理": return .red
        case "需要留意": return .orange
        default: return PawTheme.accent
        }
    }
    private var freeSpace: Double? {
        let disks = model.system["disks"] as? [[String: Any]] ?? []
        guard let disk = disks.first(where: { safeString($0["mount"]) == "/" }) ?? disks.first,
              let total = number(disk["total"]), let used = number(disk["used"]), total >= used, used >= 0 else { return nil }
        return total - used
    }
    private var pressureColor: Color {
        switch pressure {
        case .normal: return PawTheme.text
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return PawTheme.secondary
        }
    }
    private var codexMemory: String {
        guard let reading = model.latest else { return "采集中" }
        return reading.totalFootprintBytes.map { String(format: "%.2f GiB", Double($0) / GiB) } ?? "数据不完整"
    }
    private var updateText: String {
        guard let updated = model.systemUpdatedAt else { return model.systemRefreshing ? "正在读取状态…" : "暂无系统采样" }
        let time = updated.formatted(date: .omitted, time: .standard)
        if model.systemRefreshing { return "\(time) 更新 · 刷新中" }
        if model.systemIsStale { return "\(time) 更新 · 已过期" }
        if !model.systemError.isEmpty { return "\(time) 更新 · 采集有提示" }
        return "\(time) 更新"
    }
    private var hasCurrentScan: Bool {
        if case .ready = model.cleanupScanState { return model.previewValid("clean") }
        return false
    }
    private var scanTitle: String {
        switch model.cleanupScanState {
        case .running: return "正在扫描…"
        case .ready: return hasCurrentScan ? "查看 \(model.cleanEntries.count) 个扫描项目" : "重新扫描"
        case .cancelled: return "重新扫描"
        case .failed: return "重试扫描"
        case .idle: return "扫描可清理项目"
        }
    }
    private var scanDetail: String {
        switch model.cleanupScanState {
        case .running: return model.jobPhase
        case .ready: return hasCurrentScan ? "选择项目后，再确认清理" : "扫描结果已失效，请重新扫描"
        case .cancelled: return "扫描已取消，文件未改动"
        case .failed: return "扫描未完成，可到清理页查看详情"
        case .idle: return model.jobBusy ? "当前维护任务进行中" : "只读扫描，完成后逐项选择"
        }
    }
    private var scanDisabled: Bool {
        if hasCurrentScan { return false }
        return model.jobBusy || !model.mutationSupported
    }
    private func scanAction() {
        if hasCurrentScan { onNavigate(.clean) }
        else { onScan() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                CatLogo(size: 18)
                Text("Lightpaw").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: model.refreshSystem) {
                    if model.systemRefreshing {
                        ProgressView().controlSize(.mini).frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                    }
                }.buttonStyle(.plain).foregroundStyle(PawTheme.secondary)
                    .disabled(model.jobBusy || model.systemRefreshing)
                    .help(model.jobBusy ? "维护任务结束后再刷新" : "立即刷新状态")
                    .accessibilityLabel("立即刷新状态").accessibilityIdentifier("popover-refresh")
            }
            HStack(spacing: 10) {
                Circle().fill(healthColor).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(model.healthScore.map(String.init) ?? "—")
                            .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(model.systemIsStale ? PawTheme.secondary : PawTheme.text)
                        if model.healthScore != nil { Text("分").font(.system(size: 11)).foregroundStyle(PawTheme.secondary) }
                        Text(statusTitle).font(.system(size: 14, weight: .medium)).foregroundStyle(healthColor).lineLimit(1)
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("popover-health")
                    Button { showHealthInfo.toggle() } label: {
                        HStack(spacing: 4) { Text("Mole 健康评分"); Image(systemName: showHealthInfo ? "chevron.up" : "info.circle") }
                            .font(.system(size: 11)).foregroundStyle(PawTheme.secondary)
                            .padding(.vertical, 3).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(showHealthInfo ? "收起评分说明" : "查看评分说明")
                        .accessibilityIdentifier("popover-health-info")
                }
            }
            if showHealthInfo {
                Text("分数由 Mole 提供，反映整体状态；内存压力单独监测，出现警告时优先提示。分数不会因界面调整而改变。")
                    .font(.system(size: 11)).foregroundStyle(PawTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 3)
            }
            separator
            VStack(spacing: 1) {
                metric("可用空间", symbol: "externaldrive", value: bytesText(freeSpace), page: .disk)
                metric("内存压力", symbol: "memorychip", value: pressure.title, tint: pressureColor, page: .codex)
                metric("Codex", symbol: "terminal", value: codexMemory, page: .codex)
            }
            separator
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Button(action: scanAction) {
                        HStack(spacing: 8) {
                            if model.cleanupScanState == .running { ProgressView().controlSize(.mini).frame(width: 18) }
                            else { Image(systemName: "paintbrush").frame(width: 18) }
                            Text(scanTitle).fontWeight(.medium)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 9))
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(PawTheme.accent)
                        .disabled(scanDisabled)
                        .accessibilityIdentifier("popover-scan")
                    if model.cleanupScanState == .running {
                        Button("取消", action: model.cancelOperation).buttonStyle(.plain)
                            .foregroundStyle(PawTheme.secondary).accessibilityIdentifier("popover-cancel-scan")
                    }
                }
                Text(model.mutationSupported ? scanDetail : "Mole 版本未验证，扫描暂不可用")
                    .font(.system(size: 10)).foregroundStyle(PawTheme.secondary).lineLimit(1).help(scanDetail)
            }.frame(height: 48)
            Button(action: onOpen) { Text("打开 Lightpaw").frame(maxWidth: .infinity).padding(.vertical, 3) }
                .buttonStyle(.bordered).controlSize(.regular).accessibilityIdentifier("popover-open-main")
            Text(updateText).font(.system(size: 10)).foregroundStyle(PawTheme.secondary)
                .frame(maxWidth: .infinity).lineLimit(1).help(model.systemError).accessibilityIdentifier("popover-freshness")
        }
        .font(.system(size: 12)).foregroundStyle(PawTheme.text)
        .padding(16).frame(width: 320).fixedSize(horizontal: false, vertical: true)
        .background(PawTheme.background)
    }
    private var separator: some View { Rectangle().fill(PawTheme.separator).frame(height: 1) }
    private func metric(_ title: String, symbol: String, value: String, tint: Color? = nil, page: CarePage) -> some View {
        Button { onNavigate(page) } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(PawTheme.secondary)
                Text(title).foregroundStyle(PawTheme.secondary)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(tint ?? PawTheme.text)
                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(PawTheme.secondary)
            }.frame(height: 27).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(title)，\(value)，查看详情")
            .accessibilityIdentifier("popover-metric-\(title)")
    }
}
