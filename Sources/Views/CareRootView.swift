import SwiftUI

struct CareRootView: View {
    @ObservedObject var model: CareModel
    @ViewState private var showMore = false
    private let primaryPages: [CarePage] = [.overview, .clean, .apps, .codex, .disk]
    private var operationPresented: Binding<Bool> {
        Binding(get: { model.showDetails || model.uninstallReview != nil || model.pendingBrewUpdate != nil }, set: { presented in
            if !presented {
                model.showDetails = false
                if model.uninstallReview != nil || model.pendingBrewUpdate != nil { model.cancelOperation() }
            }
        })
    }
    private var pageTitle: String {
        switch model.page {
        case .clean: return "清理空间"
        case .apps: return "应用"
        case .optimize: return "系统维护"
        default: return model.page.rawValue
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(PawTheme.separator).frame(width: 1)
            VStack(spacing: 0) {
                if model.page != .overview {
                    HStack {
                        Text(pageTitle).font(.system(size: 21, weight: .semibold)).foregroundStyle(PawTheme.lavender)
                        Spacer()
                        AnimatedCat(active: model.mainWindowVisible, compact: true)
                    }.padding(.horizontal, 20).padding(.vertical, 9)
                }
                if !model.mutationSupported {
                    Notice(text: "Mole 版本未验证，写入操作暂不可用。", symbol: "exclamationmark.triangle", tint: .orange)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                }
                Group {
                    switch model.page {
                    case .overview: OverviewPage(model: model)
                    case .codex: CodexPage(model: model)
                    case .disk: DiskPage(model: model)
                    case .clean: CleanPage(model: model)
                    case .apps: AppsPage(model: model)
                    case .optimize: OptimizePage(model: model)
                    case .history: HistoryPage(model: model)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                JobStatusBar(model: model)
            }.frame(minWidth: 600).background(PawTheme.background)
        }
        .font(.system(size: 13)).foregroundStyle(PawTheme.text)
        .controlSize(.small).tint(PawTheme.accent).preferredColorScheme(.dark)
        .onChange(of: model.page) { _ in showMore = false; model.pageChanged() }
        .sheet(isPresented: operationPresented) {
            if model.uninstallReview != nil {
                UninstallReviewSheet(model: model).interactiveDismissDisabled()
            } else if model.pendingBrewUpdate != nil {
                BrewUpdateReviewSheet(model: model).interactiveDismissDisabled()
            } else { JobDetailsSheet(model: model) }
        }
        .sheet(isPresented: $model.showProtection) {
            VStack(alignment: .leading, spacing: 14) {
                Text("保护规则").font(.system(size: 16, weight: .semibold))
                Text("当前自定义规则；Mole 的内置保护同时生效。").foregroundStyle(PawTheme.secondary)
                ReadableOutput(text: model.protectionText, height: 330)
                HStack { Spacer(); Button("关闭") { model.showProtection = false }.keyboardShortcut(.defaultAction) }
            }.padding(20).frame(width: 580)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                CatLogo(size: 27)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lightpaw").font(.system(size: 16, weight: .semibold))
                    Text("本地维护").font(.system(size: 10)).foregroundStyle(PawTheme.secondary)
                }
            }.padding(.horizontal, 17).padding(.top, 23).padding(.bottom, 25)
            ForEach(Array(primaryPages.enumerated()), id: \.element.id) { index, page in
                Button { model.page = page } label: {
                    HStack(spacing: 11) {
                        Image(systemName: page.symbol).font(.system(size: 16, weight: .regular)).frame(width: 21)
                        Text(sidebarTitle(page)).font(.system(size: 13, weight: model.page == page ? .medium : .regular))
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 12).frame(height: 39)
                        .foregroundStyle(model.page == page ? PawTheme.accent : PawTheme.text)
                        .background(model.page == page ? PawTheme.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 4)
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .accessibilityIdentifier("nav-\(page.id)")
            }
            Spacer(minLength: 20)
            Rectangle().fill(PawTheme.separator).frame(height: 1).padding(.horizontal, 16)
            Button { showMore.toggle() } label: {
                HStack(spacing: 11) {
                    Text("更多").font(.system(size: 13, weight: moreSelected ? .medium : .regular))
                    Spacer(minLength: 0)
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .regular)).frame(width: 21)
                }.padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 39)
                    .foregroundStyle(moreSelected || showMore ? PawTheme.accent : PawTheme.text)
                    .background(moreSelected || showMore ? PawTheme.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).controlSize(.regular)
                .padding(8).padding(.bottom, 5).accessibilityIdentifier("nav-more")
                .accessibilityValue(moreSelected ? "已选中" : "")
                .accessibilityHint("打开系统维护与操作历史")
                .popover(isPresented: $showMore, arrowEdge: .trailing) {
                    VStack(spacing: 3) {
                        moreDestination(.optimize, title: "系统维护", shortcut: "6")
                        moreDestination(.history, title: "操作历史", shortcut: "7")
                    }.padding(6).frame(width: 190).background(PawTheme.sidebar)
                        .onExitCommand { showMore = false }
                }
        }.frame(width: 156).frame(maxHeight: .infinity).background(PawTheme.sidebar)
    }
    private var moreSelected: Bool { [CarePage.optimize, .history].contains(model.page) }
    private func moreDestination(_ page: CarePage, title: String, shortcut: KeyEquivalent) -> some View {
        Button { showMore = false; model.page = page } label: {
            HStack(spacing: 9) {
                Image(systemName: page.symbol).frame(width: 18)
                Text(title)
                Spacer(minLength: 4)
                if model.page == page { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
            }.font(.system(size: 13)).padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 36)
                .foregroundStyle(model.page == page ? PawTheme.accent : PawTheme.text)
                .background(model.page == page ? PawTheme.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).controlSize(.regular).keyboardShortcut(shortcut, modifiers: .command)
            .accessibilityValue(model.page == page ? "已选中" : "")
    }
    private func sidebarTitle(_ page: CarePage) -> String {
        switch page { case .apps: return "应用"; case .disk: return "磁盘"; default: return page.rawValue }
    }
}
