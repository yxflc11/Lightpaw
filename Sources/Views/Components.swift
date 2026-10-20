import SwiftUI
// Use the property wrapper when the standalone CLT lacks SwiftUIMacros.
typealias ViewState<Value> = SwiftUI.State<Value>
import AppKit

struct PageToolbar<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10, content: content).padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
        }
    }
}

struct PageFooter<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10, content: content).padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
}

struct Notice: View {
    let text: String
    var symbol = "info.circle"
    var tint: Color = .secondary
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct EmptyCare: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 27, weight: .light)).foregroundStyle(.secondary).padding(.bottom, 4)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct QuietSectionTitle: View {
    let title: String
    var detail: String = ""
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(PawTheme.lavender)
            Spacer()
            if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}

struct MeterRow: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    let fraction: Double?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(title).frame(width: 64, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    if let fraction {
                        Capsule().fill(PawTheme.accent).frame(width: geometry.size.width * min(1, max(0, fraction)))
                    }
                }.frame(height: 5).frame(maxHeight: .infinity)
            }.frame(minWidth: 80, maxWidth: .infinity, minHeight: 24, maxHeight: 24)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).monospacedDigit()
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(width: 150, alignment: .trailing)
        }.padding(.vertical, 9)
    }
}

struct MemoryPlot: View {
    let values: [Double?]
    var body: some View {
        GeometryReader { geometry in
            let ceiling = max(8, (values.compactMap { $0 }.max() ?? 0) * 1.15)
            let width = max(1, geometry.size.width - 40)
            let height = max(1, geometry.size.height - 18)
            ZStack(alignment: .topLeading) {
                ForEach([0.0, 0.5, 1.0], id: \.self) { fraction in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height * fraction))
                        path.addLine(to: CGPoint(x: width, y: height * fraction))
                    }.stroke(Color.primary.opacity(0.07), lineWidth: 1)
                }
                Path { path in
                    let y = height * (1 - 8 / ceiling)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }.stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                Path { path in
                    var started = false
                    for (index, value) in values.enumerated() {
                        guard let value else { started = false; continue }
                        let point = CGPoint(x: width * Double(index) / Double(max(values.count - 1, 1)), y: height * (1 - value / ceiling))
                        if started { path.addLine(to: point) } else { path.move(to: point); started = true }
                    }
                }.stroke(PawTheme.accent, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                Text("8 GiB").font(.system(size: 10)).foregroundStyle(.secondary).offset(x: width + 6, y: max(0, height * (1 - 8 / ceiling) - 5))
                HStack { Text("最近 \(values.count) 次采样"); Spacer(); Text("现在") }.font(.system(size: 10)).foregroundStyle(.secondary).frame(width: width).offset(y: height + 5)
            }
        }.frame(height: 88).accessibilityLabel("Codex 内存趋势，共 \(values.count) 次采样，缺失采样留空；8 GiB 为提示参考线")
    }
}

struct ReadableOutput: View {
    let text: String
    var height: CGFloat = 280
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? "等待运行结果…" : text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
        }.frame(height: height).background(PawTheme.sidebar, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct JobStatusBar: View {
    @ObservedObject var model: CareModel
    var body: some View {
        if !model.jobTitle.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 9) {
                    if model.jobBusy { ProgressView().controlSize(.small).frame(width: 16) }
                    else { Image(systemName: model.jobFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(model.jobFailed ? Color.red : PawTheme.accent).frame(width: 16) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.jobTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(model.jobPhase).font(.system(size: 11)).foregroundStyle(model.jobFailed ? Color.red : .secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button("详情") { model.showDetails = true }
                    if model.jobBusy { Button("取消", action: model.cancelOperation).accessibilityIdentifier("cancel-operation") }
                    else {
                        Button { model.jobTitle = ""; model.showDetails = false } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                        }.buttonStyle(.borderless).help("收起操作结果").accessibilityLabel("收起操作结果")
                    }
                }.padding(.horizontal, 16).padding(.vertical, 9)
            }.background(PawTheme.sidebar)
        }
    }
}

struct JobDetailsSheet: View {
    @ObservedObject var model: CareModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(model.jobTitle).font(.system(size: 16, weight: .semibold)); Spacer(); if model.jobBusy { ProgressView().controlSize(.small) } }
            Text(model.jobPhase).font(.system(size: 12)).foregroundStyle(model.jobFailed ? Color.red : .secondary)
            ReadableOutput(text: model.jobText, height: 320)
            HStack {
                if model.jobBusy { Button("取消操作", action: model.cancelOperation) }
                Spacer()
                Button("关闭") { model.showDetails = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 580)
    }
}
