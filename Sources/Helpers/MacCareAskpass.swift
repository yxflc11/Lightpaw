import AppKit
import Darwin

// Invoked only by sudo -A. The password is returned through sudo's private pipe;
// it is never retained by the main app, written to disk, or included in logs.
@main
enum MacCareAskpass {
    static func main() {
        guard isatty(STDOUT_FILENO) == 0 else { exit(1) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let operation = ProcessInfo.processInfo.environment["LIGHTPAW_BREW_OPERATION"] == "更新" ? "更新" : "卸载"
        let alert = NSAlert()
        alert.messageText = "允许 Homebrew 完成\(operation)"
        alert.informativeText = "所选应用的\(operation)需要管理员权限。请输入当前账户的管理员密码；密码仅交给 macOS 的 sudo 验证。取消将停止这一步，已完成的步骤不会自动撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续\(operation)")
        alert.addButton(withTitle: "取消")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "管理员密码"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        app.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { exit(1) }
        var value = Data((field.stringValue + "\n").utf8)
        field.stringValue = ""
        FileHandle.standardOutput.write(value)
        value.resetBytes(in: value.startIndex..<value.endIndex)
        exit(0)
    }
}
