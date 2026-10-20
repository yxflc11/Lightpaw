import Foundation
import Darwin
import CryptoKit

enum CodexToolKind: String { case chatcutMCP = "ChatCut MCP" }

struct CodexToolProcess {
    let identity: Identity
    let kind: CodexToolKind
    let footprintBytes: UInt64?
    var pid: Int32 { identity.pid }
}

struct ChatCutToolSnapshot {
    let serverID: String
    let pluginID: String?
    var targetKey: String { pluginID.map { "plugin:" + $0 } ?? "mcp:" + serverID }
    let enabled: Bool
    let processInspectionSupported: Bool
    let processes: [CodexToolProcess]
    let unverifiedPIDs: [Int32]
    fileprivate let configuration: ChatCutConfiguration
    var configurationFingerprint: String { SHA256.hash(data: configuration.bytes).map { String(format: "%02x", $0) }.joined() }
    func fingerprintAfterSetting(_ enabled: Bool) throws -> String {
        let bytes = try pluginID.map { try ChatCutConfigEditor.setEnabled(enabled, in: configuration.bytes, pluginID: $0) }
            ?? ChatCutConfigEditor.setEnabled(enabled, in: configuration.bytes, serverID: serverID)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    var totalFootprintBytes: UInt64? {
        guard processInspectionSupported, unverifiedPIDs.isEmpty, processes.allSatisfy({ $0.footprintBytes != nil }) else { return nil }
        return processes.reduce(0) { $0 + ($1.footprintBytes ?? 0) }
    }
}

struct ChatCutStopResult {
    enum State { case exited, stillRunning, refused, failed }
    let identity: Identity
    let state: State
    let message: String
    var pid: Int32 { identity.pid }
}

enum CodexToolsError: LocalizedError {
    case unsafeConfiguration, unsupportedConfiguration, configurationChanged, processDiscovery
    case processControlUnsupported, protectedIntegration
    case unsupportedLine(Int)
    case io(String)
    var errorDescription: String? {
        switch self {
        case .unsafeConfiguration: return "配置文件身份或权限无法安全核实，未作更改。"
        case .unsupportedConfiguration: return "集成配置缺失、重复或使用复杂 TOML；请在 Codex 中处理。"
        case .unsupportedLine(let line): return "配置第 \(line) 行不在安全编辑支持范围内；请在 Codex 中处理。"
        case .configurationChanged: return "配置已变化，请重新读取后再操作。"
        case .processDiscovery: return "进程列表读取失败，无法核实后台工具。"
        case .processControlUnsupported: return "此集成仅支持管理自动加载，未提供进程终止。"
        case .protectedIntegration: return "此内置工具由 Codex 管理，不能在这里更改自动加载。"
        case .io(let action): return action + "失败，未继续操作。"
        }
    }
}

// A deliberately small editor, not a general TOML implementation. All accepted
// input is single-line and unambiguous; unsupported syntax fails closed.
enum ChatCutConfigEditor {
    private struct Layout { let enabled: Bool; let replacement: Range<String.Index>?; let insertion: String.Index; let newline: String; let missingTable: Bool }
    private enum Target {
        case mcp(String), plugin(String)
        var path: [String] { switch self { case .mcp(let id): return ["mcp_servers", id]; case .plugin(let id): return ["plugins", id] } }
        var header: String { switch self { case .mcp(let id): return "[mcp_servers.\(id)]"; case .plugin(let id): return "[plugins.\"\(id)\"]" } }
        var isPlugin: Bool { if case .plugin = self { return true }; return false }
    }
    private static let builtinIDs: Set<String> = ["node_repl", "cua", "cua_repl", "artifact", "artifact_tool", "artifact_session", "codex_app_tools", "code_review"]
    private static let builtinPluginIDs: Set<String> = ["codex-app-tools@openai-bundled", "unified-computer-use@openai-bundled", "code-review@openai-bundled"]

    static func isProtected(serverID: String) -> Bool {
        builtinIDs.contains(serverID.lowercased().replacingOccurrences(of: "-", with: "_"))
    }
    static func isProtectedPlugin(_ pluginID: String) -> Bool { builtinPluginIDs.contains(pluginID.lowercased()) }

    static func isEnabled(_ data: Data, serverID: String = "chatcut_desktop") throws -> Bool { try parse(data, target: .mcp(serverID)).1.enabled }
    static func isEnabled(_ data: Data, pluginID: String) throws -> Bool { try parse(data, target: .plugin(pluginID)).1.enabled }
    static func disable(_ data: Data, serverID: String = "chatcut_desktop") throws -> Data {
        try setEnabled(false, in: data, serverID: serverID)
    }
    static func setEnabled(_ enabled: Bool, in data: Data, serverID: String = "chatcut_desktop") throws -> Data {
        guard !isProtected(serverID: serverID) else { throw CodexToolsError.protectedIntegration }
        return try setEnabled(enabled, in: data, target: .mcp(serverID))
    }
    static func setEnabled(_ enabled: Bool, in data: Data, pluginID: String) throws -> Data {
        guard !isProtectedPlugin(pluginID) else { throw CodexToolsError.protectedIntegration }
        return try setEnabled(enabled, in: data, target: .plugin(pluginID))
    }
    private static func setEnabled(_ enabled: Bool, in data: Data, target: Target) throws -> Data {
        var (text, layout) = try parse(data, target: target)
        guard enabled != layout.enabled else { return data }
        let literal = enabled ? "true" : "false"
        if layout.missingTable {
            let separator = text.isEmpty ? "" : text.last?.isNewline == true ? layout.newline : layout.newline + layout.newline
            text += separator + target.header + layout.newline + "enabled = " + literal + layout.newline
        } else if let range = layout.replacement { text.replaceSubrange(range, with: literal) }
        else {
            let endsInNewline = text.last?.isNewline == true
            let prefix = layout.insertion == text.endIndex && !endsInNewline ? layout.newline : ""
            let suffix = layout.insertion != text.endIndex || endsInNewline ? layout.newline : ""
            text.insert(contentsOf: prefix + "enabled = " + literal + suffix, at: layout.insertion)
        }
        return Data(text.utf8)
    }

    static func configuredServerIDs(_ data: Data) throws -> [String] {
        guard data.count <= 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw CodexToolsError.unsupportedConfiguration }
        let regex = try NSRegularExpression(pattern: #"^\[mcp_servers\.([A-Za-z0-9_-]+)\]$"#)
        var ids = Set<String>()
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line: String
            do { line = try uncomment(String(rawLine)).trimmingCharacters(in: .whitespaces) }
            catch { throw CodexToolsError.unsupportedLine(index + 1) }
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            let id = String(line[range])
            guard !isProtected(serverID: id) else { continue }
            ids.insert(id)
        }
        return ids.sorted()
    }

    private static func validServerID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
    }

    private static func parse(_ data: Data, target configurationTarget: Target) throws -> (String, Layout) {
        let id = configurationTarget.path[1]
        let idParts = id.split(separator: "@", omittingEmptySubsequences: false)
        let validID = configurationTarget.isPlugin ? idParts.count == 2 && idParts.allSatisfy { validServerID(String($0)) } : validServerID(id)
        guard validID, data.count <= 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw CodexToolsError.unsupportedConfiguration }
        let target = configurationTarget.path
        var section: [String] = [], tables = Set<[String]>(), arrayTables = Set<[String]>(), keys = Set<[String]>()
        var arrayInstance = 0, keyScope: [String] = []
        var targetFound = false, enabled: Bool?, replacement: Range<String.Index>?, insertion: String.Index?
        var start = text.startIndex, lineNumber = 0
        while start < text.endIndex {
            lineNumber += 1
            let end = text[start...].firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) ?? text.endIndex
            let after = end < text.endIndex ? text.index(after: end) : end
            var line = String(text[start..<end])
            if line.hasSuffix("\r") { line.removeLast() }
            do {
            let code = try uncomment(line).trimmingCharacters(in: .whitespaces)
            if !code.isEmpty {
                if code.hasPrefix("[") {
                    let isArray = code.hasPrefix("[[")
                    guard code.hasSuffix(isArray ? "]]" : "]") else { throw CodexToolsError.unsupportedConfiguration }
                    section = try keyPath(String(code.dropFirst(isArray ? 2 : 1).dropLast(isArray ? 2 : 1)))
                    if isArray {
                        guard !section.starts(with: target), !target.starts(with: section), !tables.contains(section) else { throw CodexToolsError.unsupportedConfiguration }
                        arrayTables.insert(section); arrayInstance += 1; keyScope = section + ["\u{1}\(arrayInstance)"]
                    } else {
                        guard !arrayTables.contains(section), tables.insert(section).inserted else { throw CodexToolsError.unsupportedConfiguration }
                        keyScope = section
                    }
                    if section == target {
                        guard code == configurationTarget.header, !targetFound else { throw CodexToolsError.unsupportedConfiguration }
                        targetFound = true; insertion = after
                    } else if section.starts(with: target) {
                        guard !configurationTarget.isPlugin, section == target + ["env"], code == "[mcp_servers.\(id).env]", targetFound else { throw CodexToolsError.unsupportedConfiguration }
                    }
                } else {
                    guard let equal = code.firstIndex(of: "=") else { throw CodexToolsError.unsupportedConfiguration }
                    let key = String(code[..<equal]).trimmingCharacters(in: .whitespaces)
                    let path = try keyPath(key), full = section + path
                    guard keys.insert(keyScope + path).inserted else { throw CodexToolsError.unsupportedConfiguration }
                    guard !target.starts(with: full) else { throw CodexToolsError.unsupportedConfiguration }
                    let value = String(code[code.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty else { throw CodexToolsError.unsupportedConfiguration }
                    if full.starts(with: target) {
                        guard (section == target || (!configurationTarget.isPlugin && section == target + ["env"])), path.count == 1, key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                              simpleValue(value) else { throw CodexToolsError.unsupportedConfiguration }
                        if section == target && key == "enabled" {
                            guard enabled == nil, value == "true" || value == "false" else { throw CodexToolsError.unsupportedConfiguration }
                            enabled = value == "true"
                            let regex = try NSRegularExpression(pattern: "^\\s*enabled\\s*=\\s*(true|false)(?:\\s*(?:#.*)?)?$")
                            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                                  let local = Range(match.range(at: 1), in: line) else { throw CodexToolsError.unsupportedConfiguration }
                            let lower = text.index(start, offsetBy: line.distance(from: line.startIndex, to: local.lowerBound))
                            replacement = lower..<text.index(lower, offsetBy: value.count)
                        }
                    }
                }
            }
            } catch { throw CodexToolsError.unsupportedLine(lineNumber) }
            start = after
        }
        guard targetFound || configurationTarget.isPlugin else { throw CodexToolsError.unsupportedConfiguration }
        return (text, Layout(enabled: enabled ?? true, replacement: replacement, insertion: insertion ?? text.endIndex,
                             newline: text.contains("\r\n") ? "\r\n" : "\n", missingTable: !targetFound))
    }

    private static func keyPath(_ text: String) throws -> [String] {
        let chars = Array(text)
        var parts: [String] = [], at = 0
        func spaces() { while at < chars.count && (chars[at] == " " || chars[at] == "\t") { at += 1 } }
        while at < chars.count {
            spaces(); guard at < chars.count else { throw CodexToolsError.unsupportedConfiguration }
            var token = ""
            if chars[at] == "\"" || chars[at] == "'" {
                let quote = chars[at]; at += 1
                while at < chars.count && chars[at] != quote {
                    guard chars[at] != "\\", !chars[at].isNewline else { throw CodexToolsError.unsupportedConfiguration }
                    token.append(chars[at]); at += 1
                }
                guard at < chars.count else { throw CodexToolsError.unsupportedConfiguration }; at += 1
            } else {
                while at < chars.count && (chars[at].isASCII && (chars[at].isLetter || chars[at].isNumber || chars[at] == "_" || chars[at] == "-")) {
                    token.append(chars[at]); at += 1
                }
            }
            guard !token.isEmpty else { throw CodexToolsError.unsupportedConfiguration }
            parts.append(token); spaces()
            if at == chars.count { break }
            guard chars[at] == "." else { throw CodexToolsError.unsupportedConfiguration }; at += 1
            guard at < chars.count else { throw CodexToolsError.unsupportedConfiguration }
        }
        guard !parts.isEmpty else { throw CodexToolsError.unsupportedConfiguration }
        return parts
    }

    private static func uncomment(_ text: String) throws -> String {
        var quote: Character?, escaped = false, stack: [Character] = [], result = ""
        guard !text.contains("\"\"\"") && !text.contains("'''") else { throw CodexToolsError.unsupportedConfiguration }
        for c in text {
            if let q = quote {
                result.append(c)
                if escaped { escaped = false }
                else if q == "\"" && c == "\\" { escaped = true }
                else if c == q { quote = nil }
            } else {
                if c == "#" { break }
                result.append(c)
                if c == "\"" || c == "'" { quote = c }
                else if c == "[" || c == "{" { stack.append(c) }
                else if c == "]" || c == "}" {
                    guard stack.popLast() == (c == "]" ? "[" : "{") else { throw CodexToolsError.unsupportedConfiguration }
                }
            }
        }
        guard quote == nil, stack.isEmpty else { throw CodexToolsError.unsupportedConfiguration }
        return result
    }

    private static func simpleValue(_ value: String) -> Bool {
        let atom = #"(?:true|false|[+-]?[0-9]+|"(?:[^"\\]|\\.)*"|'[^']*')"#
        return value.range(of: "^(?:" + atom + "|\\[\\s*(?:" + atom + "(?:\\s*,\\s*" + atom + ")*\\s*,?)?\\s*\\])$", options: .regularExpression) != nil
    }
}

private struct ChatCutFileIdentity: Equatable {
    let device: dev_t, inode: ino_t, mode: mode_t, owner: uid_t, links: nlink_t, size: off_t
    let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; mode = s.st_mode; owner = s.st_uid; links = s.st_nlink; size = s.st_size
        modifiedSeconds = s.st_mtimespec.tv_sec; modifiedNanos = s.st_mtimespec.tv_nsec
        changedSeconds = s.st_ctimespec.tv_sec; changedNanos = s.st_ctimespec.tv_nsec
    }
}

fileprivate struct ChatCutConfiguration {
    let url: URL
    let bytes: Data
    fileprivate let identity: ChatCutFileIdentity
}

// Called only on demand. The default dependencies touch live processes; fixture
// tests inject all process operations and never signal a real process.
struct CodexToolsRuntime {
    var list: () -> (items: [Proc], skipped: Int, error: Int32) = listProcesses
    var targets: () -> Set<String> = targetExecutables
    var validate: (Proc) -> Bool = { p in p.path.withCString { cwm_validate_process(p.id.pid, p.id.seconds, p.id.micros, p.parent, $0) == 0 } }
    var kind: (Proc) -> CodexToolKind? = { p in
        var kind: Int32 = 0
        return cwm_tool_kind(p.id.pid, p.id.seconds, p.id.micros, p.parent, &kind) == 0 && kind == 1 ? .chatcutMCP : nil
    }
    var footprint: (Identity) -> UInt64? = { id in
        var bytes: UInt64 = 0
        return cwm_footprint(id.pid, id.seconds, id.micros, &bytes) == 0 ? bytes : nil
    }
    var identityStatus: (Identity) -> Int32 = { cwm_identity($0.pid, $0.seconds, $0.micros) }
    var terminate: (Proc) -> Int32 = { cwm_terminate_chatcut($0.id.pid, $0.id.seconds, $0.id.micros, $0.parent) }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
}

final class CodexTools {
    static let chatcutExecutable = "/Applications/ChatCut.app/Contents/MacOS/ChatCut"
    let configURL: URL
    let serverID: String
    let pluginID: String?
    var targetKey: String { pluginID.map { "plugin:" + $0 } ?? "mcp:" + serverID }
    private let runtime: CodexToolsRuntime
    init(configURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml"), serverID: String = "chatcut_desktop", runtime: CodexToolsRuntime = CodexToolsRuntime()) {
        self.configURL = configURL; self.serverID = serverID; self.pluginID = nil; self.runtime = runtime
    }
    init(configURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml"), pluginID: String, runtime: CodexToolsRuntime = CodexToolsRuntime()) {
        self.configURL = configURL; self.serverID = pluginID; self.pluginID = pluginID; self.runtime = runtime
    }

    func classify(_ process: Proc, among processes: [Proc]) -> CodexToolKind? {
        guard process.path == Self.chatcutExecutable, Self.matchesReviewed(process.id, current: process),
              hasCodexAncestor(process, among: processes, validate: true), runtime.kind(process) == .chatcutMCP else { return nil }
        return .chatcutMCP
    }

    private func hasCodexAncestor(_ process: Proc, among processes: [Proc], validate: Bool) -> Bool {
        let lookup = Dictionary(processes.map { ($0.id.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var current = process, seen = Set<Int32>()
        let targets = runtime.targets()
        while seen.insert(current.id.pid).inserted {
            if validate && !runtime.validate(current) { return false }
            if current.id != process.id && targets.contains(current.path) { return true }
            guard let parent = lookup[current.parent] else { return false }
            current = parent
        }
        return false
    }

    static func matchesReviewed(_ identity: Identity, current: Proc) -> Bool { identity == current.id && current.path == chatcutExecutable }

    // Read-only diagnostics: one explicitly selected argv[1] or argv[2], capped
    // at 4095 bytes. No other args or environment are returned. On demand only.
    static func scriptPath(_ process: Proc, argumentIndex: Int32 = 1) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        let result = process.path.withCString { path in
            cwm_script_path(process.id.pid, process.id.seconds, process.id.micros, process.parent, path, argumentIndex, &bytes, bytes.count)
        }
        return result == 0 ? String(validatingUTF8: bytes) : nil
    }

    static func workingDirectory(_ process: Proc) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        let result = process.path.withCString { path in
            cwm_working_directory(process.id.pid, process.id.seconds, process.id.micros, process.parent, path, &bytes, bytes.count)
        }
        return result == 0 ? String(validatingUTF8: bytes) : nil
    }

    func snapshot() throws -> ChatCutToolSnapshot {
        let configuration = try readConfiguration()
        let enabled = try pluginID.map { try ChatCutConfigEditor.isEnabled(configuration.bytes, pluginID: $0) }
            ?? ChatCutConfigEditor.isEnabled(configuration.bytes, serverID: serverID)
        guard pluginID == nil, serverID == "chatcut_desktop" else {
            return ChatCutToolSnapshot(serverID: serverID, pluginID: pluginID, enabled: enabled, processInspectionSupported: false,
                                       processes: [], unverifiedPIDs: [], configuration: configuration)
        }
        let list = runtime.list()
        guard list.error == 0 else { throw CodexToolsError.processDiscovery }
        var confirmed: [CodexToolProcess] = [], unverified: [Int32] = []
        for p in list.items where p.path == Self.chatcutExecutable && hasCodexAncestor(p, among: list.items, validate: false) {
            if let kind = classify(p, among: list.items) {
                confirmed.append(CodexToolProcess(identity: p.id, kind: kind, footprintBytes: runtime.footprint(p.id)))
            } else { unverified.append(p.id.pid) }
        }
        return ChatCutToolSnapshot(serverID: serverID, pluginID: nil, enabled: enabled, processInspectionSupported: true, processes: confirmed.sorted { $0.pid < $1.pid },
                                   unverifiedPIDs: unverified.sorted(), configuration: configuration)
    }

    func configuredServerIDs() throws -> [String] { try ChatCutConfigEditor.configuredServerIDs(readConfiguration().bytes) }

    @discardableResult func disable(_ snapshot: ChatCutToolSnapshot) throws -> URL? {
        try setEnabled(false, snapshot)
    }

    @discardableResult func setEnabled(_ enabled: Bool, _ snapshot: ChatCutToolSnapshot, beforeCommit: () throws -> Void = {}) throws -> URL? {
        guard snapshot.configuration.url == configURL, snapshot.targetKey == targetKey else { throw CodexToolsError.configurationChanged }
        let desired = try pluginID.map { try ChatCutConfigEditor.setEnabled(enabled, in: snapshot.configuration.bytes, pluginID: $0) }
            ?? ChatCutConfigEditor.setEnabled(enabled, in: snapshot.configuration.bytes, serverID: serverID)
        let directory = try openDirectory(); defer { close(directory) }
        let (source, current) = try readConfiguration(directory); defer { close(source) }
        guard current.identity == snapshot.configuration.identity, current.bytes == snapshot.configuration.bytes else { throw CodexToolsError.configurationChanged }
        if desired == current.bytes { return nil }
        guard flock(source, LOCK_EX | LOCK_NB) == 0 else { throw CodexToolsError.configurationChanged }
        defer { flock(source, LOCK_UN) }
        let backupName = configURL.lastPathComponent + ".mcp-before-" + UUID().uuidString
        let backup = openat(directory, backupName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard backup >= 0 else { throw CodexToolsError.io("创建私有备份") }
        do { try write(current.bytes, to: backup); guard fsync(backup) == 0 else { throw CodexToolsError.io("保存备份") }; close(backup) }
        catch { close(backup); unlinkat(directory, backupName, 0); throw error }
        let tempName = ".mcp-config-" + UUID().uuidString
        let temp = openat(directory, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard temp >= 0 else { throw CodexToolsError.io("准备配置") }
        defer { close(temp); unlinkat(directory, tempName, 0) }
        try write(desired, to: temp)
        guard fcopyfile(source, temp, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0,
              fchmod(temp, current.identity.mode & 0o7777) == 0, fsync(temp) == 0 else { throw CodexToolsError.io("保留配置权限") }
        try beforeCommit()
        let (recheck, unchanged) = try readConfiguration(directory); defer { close(recheck) }
        guard unchanged.identity == current.identity, unchanged.bytes == current.bytes else { throw CodexToolsError.configurationChanged }
        let directoryAgain = try openDirectory(); defer { close(directoryAgain) }
        var originalDirectory = stat(), currentDirectory = stat()
        guard fstat(directory, &originalDirectory) == 0, fstat(directoryAgain, &currentDirectory) == 0,
              originalDirectory.st_dev == currentDirectory.st_dev, originalDirectory.st_ino == currentDirectory.st_ino else { throw CodexToolsError.configurationChanged }
        guard renameat(directory, tempName, directory, configURL.lastPathComponent) == 0 else { throw CodexToolsError.io("保存配置") }
        _ = fsync(directory)
        return configURL.deletingLastPathComponent().appendingPathComponent(backupName)
    }

    func stop(_ snapshot: ChatCutToolSnapshot, waitSeconds: TimeInterval = 3) throws -> [ChatCutStopResult] {
        guard pluginID == nil, snapshot.pluginID == nil, serverID == "chatcut_desktop", snapshot.serverID == serverID, snapshot.processInspectionSupported else { throw CodexToolsError.processControlUnsupported }
        guard waitSeconds.isFinite, waitSeconds >= 0, waitSeconds <= 10, snapshot.configuration.url == configURL else { throw CodexToolsError.configurationChanged }
        let expected = try ChatCutConfigEditor.disable(snapshot.configuration.bytes, serverID: serverID)
        func confirmDisabled() throws {
            let current = try readConfiguration()
            guard current.bytes == expected, try !ChatCutConfigEditor.isEnabled(current.bytes, serverID: serverID) else { throw CodexToolsError.configurationChanged }
        }
        try confirmDisabled()
        var results: [ChatCutStopResult] = []
        for reviewed in snapshot.processes {
            try confirmDisabled()
            let status = runtime.identityStatus(reviewed.identity)
            if status == ESRCH || status == EAGAIN {
                results.append(ChatCutStopResult(identity: reviewed.identity, state: .exited, message: "已审阅的工具进程已退出，未发送信号。")); continue
            }
            let list = runtime.list()
            guard status == 0, list.error == 0,
                  let current = list.items.first(where: { $0.id.pid == reviewed.pid }),
                  Self.matchesReviewed(reviewed.identity, current: current), classify(current, among: list.items) == .chatcutMCP else {
                results.append(ChatCutStopResult(identity: reviewed.identity, state: .refused, message: "进程身份或 Codex 父链无法复核，未发送信号。")); continue
            }
            let error = runtime.terminate(current)
            guard error == 0 else {
                results.append(ChatCutStopResult(identity: reviewed.identity, state: .failed, message: "终止请求未成功；进程可能已变化或无访问权限。")); continue
            }
            let deadline = Date().addingTimeInterval(waitSeconds)
            var remaining = runtime.identityStatus(reviewed.identity)
            while remaining == 0 && Date() < deadline { runtime.sleep(min(0.1, max(0, deadline.timeIntervalSinceNow))); remaining = runtime.identityStatus(reviewed.identity) }
            let exited = remaining == ESRCH || remaining == EAGAIN
            results.append(ChatCutStopResult(identity: reviewed.identity, state: exited ? .exited : remaining == 0 ? .stillRunning : .failed,
                                              message: exited ? "已退出。" : remaining == 0 ? "已请求退出，仍在运行；未强制终止。" : "已请求退出，退出状态暂时无法核实。"))
        }
        return results
    }

    private func openDirectory() throws -> Int32 {
        guard configURL.isFileURL, configURL.path.hasPrefix("/"), configURL.lastPathComponent == "config.toml",
              !configURL.pathComponents.contains(".."), !configURL.pathComponents.contains(".") else { throw CodexToolsError.unsafeConfiguration }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw CodexToolsError.unsafeConfiguration }
        for part in configURL.deletingLastPathComponent().pathComponents.dropFirst() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); close(fd)
            guard next >= 0 else { throw CodexToolsError.io("无符号链接地打开配置目录") }; fd = next
        }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == getuid(), s.st_mode & 0o022 == 0 else { close(fd); throw CodexToolsError.io("验证配置目录所有者和权限") }
        return fd
    }

    private func readConfiguration() throws -> ChatCutConfiguration {
        let dir = try openDirectory(); defer { close(dir) }
        let (fd, result) = try readConfiguration(dir); close(fd); return result
    }

    private func readConfiguration(_ directory: Int32) throws -> (Int32, ChatCutConfiguration) {
        let fd = openat(directory, configURL.lastPathComponent, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw CodexToolsError.io("无符号链接地打开配置文件") }
        do {
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1,
                  before.st_size >= 0, before.st_size <= 1024 * 1024 else { throw CodexToolsError.io("验证配置文件类型与所有者") }
            var bytes = Data(count: Int(before.st_size)), offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset)) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CodexToolsError.configurationChanged }; offset += count
            }
            guard fstat(fd, &after) == 0, ChatCutFileIdentity(before) == ChatCutFileIdentity(after) else { throw CodexToolsError.configurationChanged }
            return (fd, ChatCutConfiguration(url: configURL, bytes: bytes, identity: ChatCutFileIdentity(after)))
        } catch { close(fd); throw error }
    }

    private func write(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CodexToolsError.io("写入文件") }; offset += count
        }
    }
}
