import Foundation
import AppKit

enum CarePage: String, CaseIterable, Identifiable {
    case overview = "总览", codex = "Codex", disk = "磁盘空间", clean = "清理", apps = "应用卸载", optimize = "系统优化", history = "操作历史"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "house"
        case .codex: return "terminal"
        case .disk: return "cylinder.split.1x2"
        case .clean: return "paintbrush"
        case .apps: return "square.grid.2x2"
        case .optimize: return "slider.horizontal.3"
        case .history: return "clock.arrow.circlepath"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "看清 Mac 当前的状态，再决定需要做什么。"
        case .codex: return "持续记录内存与进程变化，保留自动退出前后的线索。"
        case .disk: return "用 Mole 分析目录，逐层找到空间占用。"
        case .clean: return "先查看 Mole 的清理预览，再决定是否执行。"
        case .apps: return "查看真实卸载范围，保留个人数据。"
        case .optimize: return "预览系统维护项目，按需执行一次。"
        case .history: return "查看 Mole 在本机记录的操作结果。"
        }
    }
}

func bytesText(_ n: Double?) -> String {
    guard let n, n.isFinite, n >= 0 else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(min(n, Double(Int64.max)-2048)), countStyle: .binary)
}
func percentText(_ n: Double?) -> String { n.map { String(format: "%.1f%%", $0) } ?? "—" }
func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
func number(_ value: Any?) -> Double? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
    return n.doubleValue
}
func safeString(_ value: Any?) -> String { value as? String ?? "" }
func shortPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

struct MoleApplication: Identifiable {
    let name: String; let bundleID: String; var source: String; let path: String; let size: String
    var id: String { path }
    var query: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
    var isManaged: Bool { source == "Homebrew" }
    init?(_ json: [String: Any]) {
        guard let name = json["name"] as? String, let path = json["path"] as? String,
              path.hasPrefix("/"), path.lowercased().hasSuffix(".app") else { return nil }
        self.name = name; self.path = path; bundleID = safeString(json["bundle_id"])
        source = safeString(json["source"]); size = safeString(json["size"])
    }
}
struct DiskEntry: Identifiable {
    let name: String; let path: String; let size: Double?; let isDirectory: Bool; let scanStatus: String
    var id: String { path }
    init?(_ j: [String: Any]) {
        guard let path = j["path"] as? String, path.hasPrefix("/"), let name = j["name"] as? String else { return nil }
        self.name = name; self.path = path; self.size = number(j["size"]); isDirectory = j["is_dir"] as? Bool ?? false
        scanStatus = safeString(j["scan_status"])
    }
    var sizeLabel: String {
        if scanStatus == "unavailable" { return "无法读取" }
        return bytesText(size) + (scanStatus == "partial" ? " +" : "")
    }
}
struct CleanupEntry: Identifiable {
    let id: Int; let section: String; let path: String; let detail: String
}

enum MoleText {
    static func plain(_ source: String) -> String {
        source.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\][^\x07]*(?:\x07|\x1B\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
    }
    static func cleanupEntries(_ text: String) -> [CleanupEntry] {
        var section = "清理项目"; var rows: [CleanupEntry] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("=== "), line.hasSuffix(" ===") { section = String(line.dropFirst(4).dropLast(4)); continue }
            guard line.hasPrefix("/"), let split = line.range(of: "  # ") else { continue }
            rows.append(CleanupEntry(id: rows.count, section: section, path: String(line[..<split.lowerBound]), detail: String(line[split.upperBound...])))
        }
        return rows
    }
}

// This state machine only authorizes the discovery step. The final Enter is exclusively a UI action.
struct UninstallProtocol {
    enum Event { case none, advanceDiscovery, review(String), reject(String) }
    let expected: MoleApplication
    var firstAnswered = false
    var reviewPresented = false
    mutating func receive(_ output: String) -> Event {
        let text = MoleText.plain(output)
        if !firstAnswered && text.contains("Proceed with uninstallation? [y/N] ") {
            guard text.contains("Matched 1 app(s):"),
                  text.contains("1. \(expected.name)  ") else { return .reject("Mole 匹配结果与所选应用不一致，已中止。") }
            firstAnswered = true
            return .advanceDiscovery
        }
        if firstAnswered && !reviewPresented && text.contains("Enter confirm, ESC cancel:") {
            guard let review = verifiedReview(in: text) else {
                return .reject("无法核对实际卸载路径，已中止。")
            }
            reviewPresented = true
            return .review(review)
        }
        return .none
    }

    // Mole 1.61.0 emits the app title, optional indented warnings, then the
    // main bundle as the FIRST checkmarked row. Later rows can describe related
    // files or retained data, and must never establish the selected app's identity.
    private func verifiedReview(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(of: "Files to be removed:") else { return nil }
        let review = Array(lines.dropFirst(start + 1))
        guard let confirmation = review.firstIndex(where: { $0.hasPrefix("➤ Remove ") }),
              review[confirmation].hasPrefix("➤ Remove 1 app, "),
              review[confirmation].trimmingCharacters(in: .whitespaces).hasSuffix("Enter confirm, ESC cancel:") else { return nil }
        let rows = review.prefix(confirmation).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let titlePrefix = "◎ \(expected.name)\(expected.isManaged ? " [Brew]" : "") , "
        guard let title = rows.first, title.hasPrefix(titlePrefix) else { return nil }
        let titleSize = String(title.dropFirst(titlePrefix.count))
        guard Self.isMeasuredSize(titleSize) || titleSize == "N/A (Steam-managed)" else { return nil }
        // A second top-level app title is inconsistent with the one-app plan.
        guard rows.dropFirst().allSatisfy({ !$0.hasPrefix("◎ ") }) else { return nil }
        for row in rows.dropFirst() {
            if row.hasPrefix("  ◎ ") { continue }
            guard row.hasPrefix("  ✓ ") else { return nil }
            let displayedPath = String(row.dropFirst("  ✓ ".count))
            let matched = [expected.path, shortPath(expected.path)].contains { path in
                if displayedPath == path { return true }
                let measuredPrefix = path + " , "
                return displayedPath.hasPrefix(measuredPrefix) &&
                    Self.isMeasuredSize(String(displayedPath.dropFirst(measuredPrefix.count)))
            }
            return matched ? lines.dropFirst(start).joined(separator: "\n") : nil
        }
        return nil
    }

    private static func isMeasuredSize(_ text: String) -> Bool {
        text.range(of: #"^[0-9]+(?:\.[0-9]+)?(?:B|KB|MB|GB)$"#, options: .regularExpression) != nil
    }
}

struct BundleIdentity: Equatable {
    let device: UInt64; let inode: UInt64; let bundleID: String
    init?(path: String) {
        let url = URL(fileURLWithPath: path)
        guard !url.lastPathComponent.contains("\n"), !url.lastPathComponent.contains("\r"),
              url.resolvingSymlinksInPath().path == url.standardizedFileURL.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeDirectory,
              let inode = attrs[.systemFileNumber] as? NSNumber,
              let device = attrs[.systemNumber] as? NSNumber,
              let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let id = info["CFBundleIdentifier"] as? String else { return nil }
        self.device = device.uint64Value; self.inode = inode.uint64Value; self.bundleID = id
    }
}
