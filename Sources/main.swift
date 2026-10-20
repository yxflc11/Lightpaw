import AppKit
import SwiftUI
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let model = CareModel()
    var window: NSWindow!
    var statusItem: NSStatusItem!
    private let statusPopover = NSPopover()
    private var localPopoverMonitor: Any?
    private var globalPopoverMonitor: Any?
    private var isPresentingStatusPopover = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(900, screen.width-60), height: min(640, screen.height-70)), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Lightpaw"; window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(PawTheme.background)
        window.minSize = NSSize(width: 800, height: 540); window.isReleasedWhenClosed = false; window.delegate = self
        window.setFrameAutosaveName("MacCareWindowV3")
        let hosting = NSHostingView(rootView: CareRootView(model: model).preferredColorScheme(.dark))
        hosting.sizingOptions = []
        window.contentView = hosting; window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let cat = BrandIcon.image(size: 18)
        statusItem.button?.image = cat; statusItem.button?.title = ""
        statusItem.button?.setAccessibilityLabel("Lightpaw 状态")
        statusItem.button?.toolTip = "Lightpaw · 正在读取状态"
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // One dismissal policy avoids a transient mouse-down close followed by a
        // status-button mouse-up reopening the same panel.
        statusPopover.behavior = .applicationDefined
        statusPopover.animates = true
        statusPopover.delegate = self
        statusPopover.appearance = NSAppearance(named: .darkAqua)
        statusPopover.contentSize = NSSize(width: 320, height: 375)
        statusPopover.contentViewController = NSHostingController(rootView: StatusPopoverView(
            model: model,
            onOpen: { [weak self] in self?.showWindow(nil) },
            onNavigate: { [weak self] page in self?.model.page = page; self?.showWindow(nil) },
            onScan: { [weak self] in self?.model.previewMaintenance("clean") }
        ).preferredColorScheme(.dark))
        model.onMemoryUpdate = { [weak self] r in
            let value = r.totalFootprintBytes.map { String(format: "%.2f GiB", Double($0)/GiB) } ?? "数据不完整"
            self?.statusItem.button?.toolTip = "Lightpaw · Codex \(value) · 内存压力\(r.pressure.title)"
        }
        let menu = NSMenu(); let appMenu = NSMenuItem(); menu.addItem(appMenu)
        let submenu = NSMenu(); submenu.addItem(withTitle: "打开 Lightpaw", action: #selector(showWindow(_:)), keyEquivalent: "1").target = self
        let panelItem = submenu.addItem(withTitle: "显示状态面板", action: #selector(showStatusPanel(_:)), keyEquivalent: "s")
        panelItem.target = self; panelItem.keyEquivalentModifierMask = [.command, .shift]
        submenu.addItem(NSMenuItem.separator()); submenu.addItem(withTitle: "退出 Lightpaw", action: #selector(quit(_:)), keyEquivalent: "q").target = self
        appMenu.submenu = submenu
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); let edits = NSMenu(title: "编辑")
        edits.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edits.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edits.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = edits; menu.addItem(edit); NSApp.mainMenu = menu
        model.start(); showWindow(nil)
    }
    @objc func showWindow(_ sender: Any?) {
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateWindowVisibility()
        dismissStatusPopover()
    }
    @objc func statusClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            dismissStatusPopover()
            let menu = NSMenu(); menu.addItem(withTitle: "打开 Lightpaw", action: #selector(showWindow(_:)), keyEquivalent: "").target = self
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "退出 Lightpaw", action: #selector(quit(_:)), keyEquivalent: "").target = self
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else if statusPopover.isShown {
            dismissStatusPopover()
        } else { showStatusPanel(nil) }
    }
    @objc func showStatusPanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if statusPopover.isShown {
            statusPopover.contentViewController?.view.window?.makeKey()
            return
        }
        isPresentingStatusPopover = true
        defer { isPresentingStatusPopover = false }
        NSApp.activate(ignoringOtherApps: true)
        statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A crowded menu bar can hide the status item. Keep the menu command usable.
        if !statusPopover.isShown, let content = window.contentView {
            showWindow(nil)
            let anchor = NSRect(x: content.bounds.maxX - 24, y: content.isFlipped ? 8 : content.bounds.maxY - 8, width: 1, height: 1)
            statusPopover.show(relativeTo: anchor, of: content, preferredEdge: .minY)
        }
        statusPopover.contentViewController?.view.window?.makeKey()
    }
    private func dismissStatusPopover() {
        removePopoverMonitors()
        if statusPopover.isShown { statusPopover.close() }
        else { model.setPopoverVisible(false) }
    }
    private func installPopoverMonitors() {
        removePopoverMonitors()
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localPopoverMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents.union(.keyDown)) { [weak self] event in
            guard let self, self.statusPopover.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.dismissStatusPopover()
                    return nil
                }
            } else if !self.isInsideStatusPopoverOrButton(event) {
                self.dismissStatusPopover()
            }
            // Outside clicks still reach their original control or window.
            return event
        }
        globalPopoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            self?.dismissStatusPopover()
        }
    }
    private func isInsideStatusPopoverOrButton(_ event: NSEvent) -> Bool {
        if let popoverWindow = statusPopover.contentViewController?.view.window {
            var eventWindow = event.window
            while let candidate = eventWindow {
                if candidate === popoverWindow { return true }
                eventWindow = candidate.parent
            }
        }
        if let button = statusItem.button, let buttonWindow = button.window, event.window === buttonWindow {
            return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
        }
        return false
    }
    private func removePopoverMonitors() {
        if let localPopoverMonitor { NSEvent.removeMonitor(localPopoverMonitor) }
        if let globalPopoverMonitor { NSEvent.removeMonitor(globalPopoverMonitor) }
        localPopoverMonitor = nil
        globalPopoverMonitor = nil
    }
    @objc func quit(_ sender: Any?) { dismissStatusPopover(); NSApp.terminate(nil) }
    func popoverWillShow(_ notification: Notification) {
        model.setPopoverVisible(true)
        installPopoverMonitors()
    }
    func popoverWillClose(_ notification: Notification) { removePopoverMonitors() }
    func popoverDidClose(_ notification: Notification) { model.setPopoverVisible(false) }
    private func updateWindowVisibility() {
        guard let window else { return }
        model.setVisible(window.isVisible && !window.isMiniaturized && !NSApp.isHidden && window.occlusionState.contains(.visible))
    }
    func windowWillClose(_ notification: Notification) { model.setVisible(false) }
    func windowDidBecomeKey(_ notification: Notification) { updateWindowVisibility() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateWindowVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { model.setVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { updateWindowVisibility(); dismissStatusPopover() }
    func applicationDidHide(_ notification: Notification) { model.setVisible(false); dismissStatusPopover() }
    func applicationDidResignActive(_ notification: Notification) { dismissStatusPopover() }
    func applicationDidUnhide(_ notification: Notification) { updateWindowVisibility() }
    func applicationWillTerminate(_ notification: Notification) { removePopoverMonitors() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(nil); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.jobBusy {
            let alert = NSAlert(); alert.messageText = "取消当前操作并退出？"; alert.informativeText = "Lightpaw 将先停止本次维护任务。已经执行的步骤不会自动撤销。"; alert.addButton(withTitle: "取消操作并退出"); alert.addButton(withTitle: "继续运行")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            model.onAllOperationsStopped = { [weak self] in
                self?.model.onAllOperationsStopped = nil
                DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            model.stopAll(); return .terminateLater
        }
        model.stopAll(); return .terminateNow
    }
}

func integrationSelfTest() throws {
    enum Failure: Error { case check(String) }
    func check(_ condition: Bool, _ why: String) throws { if !condition { throw Failure.check(why) } }
    let app = MoleApplication(["name": "Example", "path": "/Applications/Example.app", "bundle_id": "org.example.app", "source": "App", "size": "1MB"])!
    var p = UninstallProtocol(expected: app)
    if case .advanceDiscovery = p.receive("Matched 2 app(s):\nProceed with uninstallation? [y/N] ") { throw Failure.check("ambiguous match advanced") }
    p = UninstallProtocol(expected: app)
    if case .advanceDiscovery = p.receive("Matched 1 app(s):\n1. Example  1MB\nProceed with uninstallation? [y/N] ") {} else { throw Failure.check("expected discovery refused") }
    if case .review = p.receive("Files to be removed:\n/Applications/Other.app\nRemove 1 app, 1MB Enter confirm, ESC cancel:") { throw Failure.check("wrong target reviewed") }
    p = UninstallProtocol(expected: app); _ = p.receive("Matched 1 app(s):\n1. Example  1MB\nProceed with uninstallation? [y/N] ")
    let validReview = "Files to be removed:\n◎ Example , 1MB\n  ✓ /Applications/Example.app , 1MB\n➤ Remove 1 app, 1MB Enter confirm, ESC cancel:"
    if case .review = p.receive(validReview) {} else { throw Failure.check("valid review missing") }
    if case .none = p.receive(validReview) {} else { throw Failure.check("review duplicated") }
    for invalidReview in [
        validReview.replacingOccurrences(of: "/Applications/Example.app ,", with: "/Applications/Example.app Backup.app ,"),
        "Files to be removed:\n◎ Example , 1MB\n  ✓ /Applications/Other.app , 1MB\nPersonal data kept:\n  /Applications/Example.app\n➤ Remove 1 app, 1MB Enter confirm, ESC cancel:",
        validReview.replacingOccurrences(of: "◎ Example ,", with: "◎ Other ,")
    ] {
        var rejected = UninstallProtocol(expected: app)
        _ = rejected.receive("Matched 1 app(s):\n1. Example  1MB\nProceed with uninstallation? [y/N] ")
        if case .reject = rejected.receive(invalidReview) {} else { throw Failure.check("unsafe review not rejected") }
    }
    let entries = MoleText.cleanupEntries("# comment\n=== User ===\n/one  # 4 MB\n/two  # size unknown\n")
    try check(entries.count == 2 && entries[1].detail == "size unknown", "cleanup parser changed unknown to zero")
    try check(DiskEntry(["name":"x", "path":"/x", "size":0, "scan_status":"unavailable"])?.sizeLabel == "无法读取", "unavailable disk became empty")
    let status = CareModel()
    try check(status.healthScore == nil && status.systemIsStale, "missing health is not a score")
    for invalid: Any in [true, -1, 101, 95.5, "96"] {
        status.system = ["health_score": invalid]
        try check(status.healthScore == nil, "invalid score accepted")
    }
    status.system = ["health_score": 96, "health_score_msg": "Excellent"]
    status.systemUpdatedAt = Date()
    try check(status.healthScore == 96 && status.healthTitle == "状态良好" && !status.systemIsStale, "valid health rejected")
    status.systemUpdatedAt = Date().addingTimeInterval(-90)
    try check(status.systemIsStale && status.healthScore == 96, "old reading must be retained but marked stale")
    status.system = ["health_score": 90, "health_score_msg": "Warning: high load"]
    try check(status.healthTitle == "需要留意", "warning message hidden")
    let selection = CareModel()
    let testRoot = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Caches/dev.fixture.selection"
    selection.cleanEntries = [
        CleanupEntry(id: 0, section: "parent-only", path: testRoot, detail: "1MB"),
        CleanupEntry(id: 1, section: "leaf-a", path: testRoot + "/a", detail: "1MB"),
        CleanupEntry(id: 2, section: "leaf-b", path: testRoot + "/b", detail: "1MB"),
        CleanupEntry(id: 3, section: "independent", path: testRoot + "-other", detail: "1MB"),
        CleanupEntry(id: 4, section: "protected", path: testRoot + "/models", detail: "1MB")
    ]
    selection.cleanSearch = "parent-only"; selection.selectAllClean(true)
    try check(selection.selectedCleanIDs == [0, 1, 2], "filtered parent selection must include eligible descendants, exclude protected data")
    selection.toggleCleanSelection(selection.cleanEntries[3])
    selection.cleanSearch = "leaf-a"; selection.selectAllClean(false)
    try check(selection.selectedCleanIDs == [2, 3], "filtered deselect must clear selected ancestor and preserve unrelated selections")
    selection.cleanSearch = "does-not-match"; selection.selectAllClean(false)
    try check(selection.selectedCleanIDs == [2, 3], "empty filter cannot clear hidden selections")
    selection.jobBusy = true; selection.cleanSearch = ""; selection.selectAllClean(false)
    try check(selection.selectedCleanIDs == [2, 3], "busy selection is locked")
    let listRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lightpaw-list-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: listRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: listRoot) }
    let kept = listRoot.appendingPathComponent("Kept.app")
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
    selection.apps = ["Removed A", "Removed B", "Kept"].map { name in
        MoleApplication(["name": name, "path": listRoot.appendingPathComponent(name + ".app").path,
                         "bundle_id": "dev.fixture." + name, "source": "Homebrew", "size": "1KB"])!
    }
    selection.selectedApp = selection.apps[1].id
    selection.removeMissingAppsAfterUninstall()
    try check(selection.apps.count == 1 && selection.apps[0].path == kept.path && selection.selectedApp == nil,
              "multi-app uninstall must remove all disappeared rows and clear stale selection")
    print("PASS: filtered parent/child selection, protected and unrelated entries, busy selection lock, multi-app uninstall list reconciliation.")
    print("PASS: exact uninstall review, cleanup preview, missing/invalid/fresh/stale health and warning classification.")
}

if CommandLine.arguments.contains("--self-test") {
    do { try monitorSelfTest(); try integrationSelfTest() } catch { fputs("SELF-TEST FAILED: \(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--sample-once") {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do { FileHandle.standardOutput.write(try encoder.encode(Sampler().sample())); print("") } catch { exit(1) }
} else {
    let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate
    app.setActivationPolicy(.regular); app.run()
}
