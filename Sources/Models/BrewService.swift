import AppKit
import CryptoKit
import Darwin
import Foundation

struct BrewUninstallPlan {
    let token: String
    let appPath: String
    let bundleID: String
    let preview: String
    let requiresAdministrator: Bool
    let scriptReviewRequired: Bool
    /// Complete installed Ruby/text sources and exact external program identities.
    /// This is evidence for review, not an exhaustive prediction of script effects.
    let scriptReviewSource: String?
    let unsupportedReason: String?
    var canExecute: Bool { unsupportedReason == nil }
    fileprivate let owner: UUID
    fileprivate let created: Date
    fileprivate let record: [String: Any]
    fileprivate let fingerprint: String
    fileprivate let executionTarget: String
}

enum BrewServiceError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let reason): return reason }
    }
}

/// Owns one brew invocation. Alternate paths are for local fixture tests only.
/// Production uses fixed /opt/homebrew paths; the UI never accepts a command/token.
final class BrewService {
    private let bridge: MoleBridge
    private let brewURL: URL
    private let caskroom: URL
    private let prefix: URL
    private let home: URL
    private let owner = UUID()
    private var preparing = false
    private var preparationCancelled = false
    var isRunning: Bool { preparing || bridge.isRunning }
    private let fm = FileManager.default
    private static let protectedIDs: Set<String> = ["com.openai.codex", "local.codex.memorywatch"]
    private static let environment = ["HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_AUTO_UPDATE": "1",
                                     "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1"]

    init(brewURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
         caskroomURL: URL = URL(fileURLWithPath: "/opt/homebrew/Caskroom"),
         prefixURL: URL = URL(fileURLWithPath: "/opt/homebrew"),
         homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
         guardianURL: URL? = nil) {
        self.brewURL = brewURL; caskroom = caskroomURL; prefix = prefixURL; home = homeURL
        bridge = MoleBridge(executableURL: brewURL, guardianURL: guardianURL)
    }

    /// Authoritative source classification, independent of Mole's application
    /// list. Fail closed if ANY installed cask cannot be decoded: returning a
    /// partial set could send an omitted cask into Mole's autoremove branch.
    func installedAppPaths(completion: @escaping (Result<Set<String>, Error>) -> Void) throws {
        guard !isRunning else { throw failure("已有 Homebrew 操作正在运行。") }
        readInstalledRecords { [weak self] result in
            guard let self else { return }
            do {
                let records = try result.get()
                var paths = Set<String>()
                for record in records {
                    do { paths.formUnion(try self.snapshot(record, reviewScripts: false).appPaths) }
                    catch {
                        let token = record["token"] as? String ?? "未知 cask"
                        throw self.failure("无法核对已安装 cask \(token) 的应用来源：\(error.localizedDescription)\n来源核对不完整，不能把未识别条目视为普通应用。")
                    }
                }
                completion(.success(paths))
            } catch { completion(.failure(error)) }
        }
    }

    func prepare(appPath: String, bundleID: String, onOutput: @escaping (String) -> Void,
                 completion: @escaping (Result<BrewUninstallPlan, Error>) -> Void) throws {
        guard !isRunning else { throw failure("已有 Homebrew 操作正在运行。") }
        try validateSelectedApp(appPath, bundleID: bundleID)
        readInstalledRecords { [weak self] result in
            guard let self else { return }
            do {
                let records = try result.get()
                let plan = try self.makePlan(records: records, appPath: appPath, bundleID: bundleID)
                onOutput("已核对安装时的 Homebrew 元数据：\(plan.token)\n")
                completion(.success(plan))
            } catch { completion(.failure(error)) }
        }
    }

    func uninstall(_ plan: BrewUninstallPlan, scriptReviewConfirmed: Bool = false, onOutput: @escaping (String) -> Void,
                   completion: @escaping (MoleCommandResult) -> Void) throws {
        guard !isRunning else { throw failure("已有 Homebrew 操作正在运行。") }
        guard plan.owner == owner, plan.canExecute, Date().timeIntervalSince(plan.created) < 600 else {
            throw failure(plan.unsupportedReason ?? "卸载预览已失效，请重新检查。")
        }
        guard !plan.scriptReviewRequired || scriptReviewConfirmed else {
            throw failure("请先审阅完整卸载脚本，并明确确认其内部行为无法逐项枚举。")
        }
        try validateSelectedApp(plan.appPath, bundleID: plan.bundleID)
        let current = try snapshot(plan.record)
        let reviewed = try describe(current, selectedPath: plan.appPath, bundleID: plan.bundleID)
        guard current.fingerprint == plan.fingerprint else {
            throw failure("应用或 Homebrew 安装记录已变化，请重新预览后确认。")
        }
        guard reviewed.reason == nil else { throw failure(reviewed.reason!) }
        // Never use Mole's cask branch, --zap, --force, --ignore-dependencies, or autoremove.
        try bridge.start(arguments: ["uninstall", "--cask", plan.executionTarget], timeout: 900,
                         environment: Self.environment, allowAdministratorPrompt: plan.requiresAdministrator,
                         onOutput: onOutput, onCompletion: completion)
    }

    func cancel() { preparationCancelled = true; bridge.cancel() }

    /// `brew info --installed` evaluates installed Ruby casks. Preview must never
    /// execute them, so inventory comes solely from durable Caskroom receipts.
    private func readInstalledRecords(completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        preparing = true
        preparationCancelled = false
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { () throws -> [[String: Any]] in
                guard fm.fileExists(atPath: caskroom.path) else { return [] }
                var records: [[String: Any]] = []
                for directory in try children(caskroom) where isDirectory(directory) && !isLink(directory) && !directory.lastPathComponent.hasPrefix(".") {
                    let token = directory.lastPathComponent
                    guard Self.validToken(token) else { throw failure("已安装 cask 的目录名称无效，无法完整核对来源。") }
                    do {
                        let receipt = try dictionary(boundedRead(directory.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")))
                        guard let source = receipt["source"] as? [String: Any], let version = source["version"] as? String, !version.isEmpty else {
                            throw failure("安装 receipt 缺少版本。")
                        }
                        records.append(["token": token, "installed": version])
                    } catch {
                        throw failure("无法核对已安装 cask \(token) 的应用来源：\(error.localizedDescription)\n来源核对不完整，不能把未识别条目视为普通应用。")
                    }
                }
                return records
            }
            DispatchQueue.main.async { [self] in
                preparing = false
                completion(preparationCancelled ? .failure(failure("已取消 Homebrew 安装记录核对。")) : result)
            }
        }
    }

    // Compatibility/fixture seam. Production preview uses file-only inventory.
    static func inventory(_ data: Data) throws -> [[String: Any]] {
        guard data.count <= 16 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["casks"] as? [[String: Any]], records.count <= 4096 else {
            throw BrewServiceError.unavailable("Homebrew 清单格式不受支持。")
        }
        var tokens = Set<String>()
        for record in records {
            guard let token = record["token"] as? String, validToken(token),
                  let installed = record["installed"] as? String, !installed.isEmpty,
                  tokens.insert(token).inserted else {
                throw BrewServiceError.unavailable("Homebrew 清单包含无效、重复或未安装的 cask，已停止。")
            }
        }
        return records
    }

    func makePlan(records: [[String: Any]], appPath: String, bundleID: String) throws -> BrewUninstallPlan {
        try validateSelectedApp(appPath, bundleID: bundleID)
        var matches: [Snapshot] = []
        var relevantError: Error?
        for record in records {
            do {
                let item = try snapshot(record, reviewScripts: false)
                if item.appPaths.contains(appPath) { matches.append(item) }
            } catch {
                // A broken unrelated cask must not prevent an otherwise exact match.
                let artifacts = record["artifacts"] as? [[String: Any]] ?? []
                if artifacts.contains(where: { $0["app"] != nil && $0["target"] as? String == appPath }) {
                    relevantError = error
                }
            }
        }
        guard matches.count == 1 else {
            if matches.isEmpty, let relevantError { throw relevantError }
            throw failure(matches.isEmpty ? "无法从已安装工件把所选应用唯一绑定到 Homebrew cask。" : "多个 cask 指向所选应用，无法安全绑定卸载目标。")
        }
        let item = try snapshot(matches[0].record)
        let description = try describe(item, selectedPath: appPath, bundleID: bundleID)
        return BrewUninstallPlan(token: item.token, appPath: appPath, bundleID: bundleID,
                                 preview: description.text, requiresAdministrator: description.admin,
                                 scriptReviewRequired: item.scriptReviewRequired, scriptReviewSource: item.scriptReviewSource,
                                 unsupportedReason: description.reason, owner: owner, created: Date(),
                                 record: item.record, fingerprint: item.fingerprint,
                                 executionTarget: item.rubyManifest ? item.manifestPath : item.token)
    }

    private struct Snapshot {
        let token: String
        let record: [String: Any]
        let artifacts: [[String: Any]]
        let config: [String: Any]
        let appPaths: [String]
        let manifestPath: String
        let receiptPath: String
        let version: String
        let flightBlocks: Bool
        let rubyManifest: Bool
        let scriptReviewRequired: Bool
        let scriptReviewSource: String?
        let scriptIssues: [String]
        let fingerprint: String
    }

    private func snapshot(_ record: [String: Any], reviewScripts: Bool = true) throws -> Snapshot {
        guard let token = record["token"] as? String, Self.validToken(token),
              let installed = record["installed"] as? String, !installed.isEmpty else {
            throw failure("无效的 Homebrew cask 身份。")
        }
        let directory = caskroom.appendingPathComponent(token)
        let metadata = directory.appendingPathComponent(".metadata")
        guard !isLink(directory), directory.resolvingSymlinksInPath().deletingLastPathComponent().path == caskroom.resolvingSymlinksInPath().path,
              !isLink(metadata) else { throw failure("cask 安装目录为别名或已迁移，请先在 Homebrew 核对安装状态。") }
        let receiptURL = metadata.appendingPathComponent("INSTALL_RECEIPT.json")
        let configURL = metadata.appendingPathComponent("config.json")
        let receiptData = try boundedRead(receiptURL), configData = try boundedRead(configURL)
        let receipt = try dictionary(receiptData), config = try dictionary(configData)
        guard let source = receipt["source"] as? [String: Any], let sourceVersion = source["version"] as? String,
              sourceVersion == installed, !sourceVersion.contains("/"), !sourceVersion.contains("\0"),
              sourceVersion != ".", sourceVersion != ".." else { throw failure("Homebrew 清单与安装 receipt 的版本不一致，请重新读取应用列表。") }
        let manifest = try installedManifest(metadata, token: token)
        let manifestData = try boundedRead(manifest)
        let ruby = manifest.pathExtension == "rb"
        let stored = ruby ? [:] : try dictionary(manifestData)
        let manifestVersion = stored["version"] as? String ?? manifest.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        guard manifestVersion == sourceVersion else { throw failure("配方快照与安装 receipt 的版本不一致，请先核对 Homebrew 安装状态。") }
        let rawArtifacts = stored["artifacts"] ?? receipt["uninstall_artifacts"]
        guard let artifacts = rawArtifacts as? [[String: Any]], !artifacts.isEmpty else {
            throw failure("安装时的卸载工件记录缺失，不能用在线新版配方代替预览。")
        }
        var paths: [String] = []
        for artifact in artifacts where artifact["app"] != nil {
            paths.append(try artifactTarget("app", artifact: artifact, config: config))
        }
        let stamps = try ([directory, metadata, manifest, receiptURL, configURL, brewURL] + paths.map(URL.init(fileURLWithPath:)))
            .map { try identity($0) }
        let appInfo = try paths.map { try boundedRead(URL(fileURLWithPath: $0).appendingPathComponent("Contents/Info.plist")) }
        var digest = SHA256()
        for value in stamps { digest.update(data: Data(value.utf8)) }
        for value in [receiptData, configData, manifestData] + appInfo { digest.update(data: value) }
        var review: [String] = [], issues: [String] = []
        let complexRuby = ruby && !simpleRubyManifest(manifestData, token: token, version: sourceVersion, artifacts: artifacts)
        if complexRuby && reviewScripts {
            if let source = String(data: manifestData, encoding: .utf8), !source.contains("\0") {
                let meaningful = source.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                if meaningful.first != "cask \"\(token)\" do" || meaningful.last != "end" {
                    issues.append("Ruby 配方缺少与安装 token 一致的完整 cask 外层，不能绑定执行目标。")
                }
                review += ["已安装 Ruby 配方（完整源代码）：\(manifest.path)",
                           "SHA256：\(Self.hex(SHA256.hash(data: manifestData)))", "", source]
            } else { issues.append("已安装 Ruby 配方不能完整显示为 UTF-8 源代码。") }
        }
        for artifact in artifacts where reviewScripts {
            guard let groups = artifact["uninstall"] as? [[String: Any]] else { continue }
            for group in groups {
                for kind in ["early_script", "script"] {
                    guard let value = group[kind] else { continue }
                    do {
                        let evidence = try scriptEvidence(value, kind: kind, staged: directory.appendingPathComponent(sourceVersion))
                        review.append(evidence.text)
                        digest.update(data: Data(evidence.fingerprint.utf8))
                    } catch { issues.append(error.localizedDescription) }
                }
            }
        }
        let scriptDeclared = artifacts.contains { artifact in
            (artifact["uninstall"] as? [[String: Any]] ?? []).contains { $0["script"] != nil || $0["early_script"] != nil }
        }
        return Snapshot(token: token, record: record, artifacts: artifacts, config: config, appPaths: paths,
                        manifestPath: manifest.path, receiptPath: receiptURL.path, version: sourceVersion,
                        flightBlocks: receipt["uninstall_flight_blocks"] as? Bool ?? true,
                        rubyManifest: ruby, scriptReviewRequired: complexRuby || scriptDeclared,
                        scriptReviewSource: review.isEmpty ? nil : review.joined(separator: "\n\n"), scriptIssues: issues,
                        fingerprint: Self.hex(digest.finalize()))
    }

    // Mirrors installed Homebrew 7.0.9: newest timestamp across versions, then
    // .json, .internal.json, .rb. Does not evaluate arbitrary Ruby during preview.
    private func installedManifest(_ metadata: URL, token: String) throws -> URL {
        var timestamps: [URL] = []
        for version in try children(metadata) where !version.lastPathComponent.hasPrefix(".") && isDirectory(version) {
            guard !isLink(version) else { throw failure("安装版本目录为符号链接，无法核对实际配方。") }
            for stamp in try children(version) where !stamp.lastPathComponent.hasPrefix(".") {
                guard !isLink(stamp), isDirectory(stamp),
                      stamp.lastPathComponent.range(of: #"^[0-9]{14}\.[0-9]+$"#, options: .regularExpression) != nil else {
                    throw failure("安装时间戳目录不符合 Homebrew 元数据格式，不能跳过它选择旧配方。")
                }
                timestamps.append(stamp)
            }
        }
        guard let latest = timestamps.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            throw failure("找不到已安装 cask 的时间戳配方快照。")
        }
        let folder = latest.appendingPathComponent("Casks")
        guard !isLink(folder) else { throw failure("配方快照目录是符号链接，无法核对。") }
        for suffix in ["json", "internal.json", "rb"] {
            let candidate = folder.appendingPathComponent(token + "." + suffix)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        throw failure("最新的安装元数据缺少配方快照。")
    }

    private func describe(_ item: Snapshot, selectedPath: String, bundleID: String) throws -> (text: String, admin: Bool, reason: String?) {
        var reasons = item.scriptIssues
        var lines = ["来源：Homebrew · \(item.token)", "已安装版本：\(item.version)", "安装快照：\(item.manifestPath)", "",
                     item.scriptReviewRequired ? "安装记录中已知的卸载组件与调用（脚本影响可能超出下列范围）：" : "将移除以下内容："]
        var admin = false
        var zapEntries: [[String: Any]] = []
        let moved: Set<String> = ["app", "font", "suite", "qlplugin", "mdimporter", "prefpane", "dictionary", "colorpicker", "keyboard_layout", "service", "input_method", "internet_plugin", "audio_unit_plugin", "vst_plugin", "vst3_plugin", "screen_saver"]
        let linked: Set<String> = ["binary", "bash_completion", "zsh_completion", "fish_completion"]
        let uninstallKeys: Set<String> = ["early_script", "launchctl", "quit", "signal", "on_upgrade", "login_item", "kext", "script", "pkgutil", "delete", "trash", "rmdir"]
        for artifact in item.artifacts {
            let keys = artifact.keys.filter { $0 != "target" }
            guard keys.count == 1, let key = keys.first else {
                reasons.append("安装工件记录格式不明确。")
                continue
            }
            if key == "zap" { zapEntries.append(artifact); continue }
            if moved.contains(key) || linked.contains(key) {
                do {
                    let path = try artifactTarget(key, artifact: artifact, config: item.config)
                    guard !dangerousRoot(path) else { throw failure("工件指向宽泛系统目录：\(path)") }
                    lines.append("• \(linked.contains(key) ? "移除链接" : key == "app" ? "移除应用" : "移除组件")：\(path)")
                    if !fm.isWritableFile(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) { admin = true }
                    if key == "app" {
                        let id = try readBundleID(path)
                        if Self.protectedIDs.contains(id) { reasons.append("cask 同时包含受保护的 Codex 或维护台应用。") }
                        if runningApp(path, bundleID: id) { reasons.append("应用仍在运行：\(URL(fileURLWithPath: path).lastPathComponent)。请先正常退出并重新预览。") }
                    }
                } catch { reasons.append(error.localizedDescription) }
            } else if key == "uninstall" {
                guard let groups = artifact[key] as? [[String: Any]] else { reasons.append("uninstall 声明无法解析。"); continue }
                for group in groups {
                    let unknown = Set(group.keys).subtracting(uninstallKeys)
                    if !unknown.isEmpty { reasons.append("不支持的 uninstall 指令：" + unknown.sorted().joined(separator: "、")) }
                    if !Set(group.keys).isDisjoint(with: ["launchctl", "kext", "pkgutil", "delete", "trash", "rmdir", "login_item"]) { admin = true }
                    for kind in ["early_script", "script"] {
                        if (group[kind] as? [String: Any])?["sudo"] as? Bool == true { admin = true }
                    }
                    for key in ["delete", "trash", "rmdir"] {
                        for raw in strings(group[key]) where dangerousRoot(expand(raw)) {
                            reasons.append("卸载声明包含宽泛目录：\(raw)")
                        }
                    }
                    for id in strings(group["quit"]) where Self.protectedIDs.contains(id) { reasons.append("卸载声明会退出受保护应用：\(id)") }
                    lines += group.keys.sorted().map { "• " + declarationLabel($0) + "：" + declarationValue(group[$0]!) }
                    if group["script"] != nil || group["early_script"] != nil {
                        lines.append("脚本将按以上 executable / args 执行；执行前须单独确认脚本审阅。")
                    }
                    if group["pkgutil"] != nil { lines.append("pkgutil 将按以上包 ID / 匹配式读取系统收据并卸载包文件，实际文件范围由已安装收据决定。") }
                }
            } else if ["uninstall_preflight", "uninstall_postflight"].contains(key) {
                lines.append("• Ruby 卸载钩子：\(key)（完整配方见下方）")
                if !item.rubyManifest { reasons.append("JSON 中的 \(key) 只有占位，缺少实际执行的已安装 Ruby 源码，不能用在线新版配方补足。") }
            } else if ["pkg", "installer", "preflight", "postflight"].contains(key) {
                // Installation-only declarations are not executed during uninstall.
                lines.append("• 安装声明 [\(key)]；卸载时不重新安装。")
            } else {
                lines += ["", "需审阅的额外工件 [\(key)]：", try pretty(artifact)]
                reasons.append("尚不能安全展开卸载工件 \(key)。")
            }
        }
        if item.flightBlocks && !item.rubyManifest { reasons.append("安装记录含 Ruby 卸载钩子，但实际快照不是 Ruby 源码；不能确认该钩子的实际执行内容。") }
        if item.scriptReviewRequired {
            if item.rubyManifest { admin = true }
            lines += ["", "脚本审阅与范围说明：",
                      "以下为安装时保存的完整 Ruby 配方，以及声明中可定位的外部脚本或程序。预览只读取文件，不执行 Ruby 或卸载脚本。",
                      "Ruby 在加载配方时即可运行代码；脚本也可能读取其他文件、调用程序、联网或动态决定操作。上述组件不是完整影响清单，内部行为、间接依赖及运行时目标无法静态穷举。",
                      "执行前将重新核对安装记录、源码、已定位程序与应用身份；任何变化都需重新预览。",
                      item.scriptReviewSource ?? "无法读取完整脚本证据。"]
        }
        guard item.appPaths.contains(selectedPath), try readBundleID(selectedPath) == bundleID else {
            throw failure("安装工件与所选应用身份不一致。")
        }
        if !zapEntries.isEmpty {
            lines += ["", item.scriptReviewRequired ? "以下 zap 额外清理声明不会单独执行：" : "以下额外清理不会执行，相关数据保留："]
            for artifact in zapEntries {
                if let groups = artifact["zap"] as? [[String: Any]] {
                    for group in groups { for key in group.keys.sorted() { lines.append("• " + declarationValue(group[key]!)) } }
                } else { lines.append(declarationValue(artifact)) }
            }
            lines.append(item.scriptReviewRequired ? "脚本内部仍可能操作相同位置，不能据此保证这些位置不会受脚本影响。" : "如与上方卸载操作重叠，以上方实际卸载清单为准。")
        }
        if admin { lines += ["", "卸载声明或 Ruby 脚本可能请求管理员权限；只有实际需要时才会弹出密码输入窗口。"] }
        if !reasons.isEmpty { lines += ["", "暂不支持直接执行：", Array(Set(reasons)).sorted().joined(separator: "\n")] }
        let text = lines.joined(separator: "\n")
        guard text.utf8.count <= 256 * 1024 else { throw failure("卸载声明过大，无法完整展示，不允许执行。") }
        return (text, admin, reasons.isEmpty ? nil : Array(Set(reasons)).sorted().joined(separator: "\n"))
    }

    private func scriptEvidence(_ value: Any, kind: String, staged: URL) throws -> (text: String, fingerprint: String) {
        let options: [String: Any]
        if let path = value as? String { options = ["executable": path] }
        else if let map = value as? [String: Any] { options = map }
        else { throw failure("\(kind) 必须是完整程序路径或 executable / args 声明。") }
        let allowed: Set<String> = ["executable", "args", "input", "must_succeed", "sudo", "print_stdout", "print_stderr"]
        guard Set(options.keys).isSubset(of: allowed), let executable = options["executable"] as? String,
              !executable.isEmpty, !executable.contains("\0"), !executable.contains("#{"), !executable.contains("{{"),
              options["args"] == nil || options["args"] is [String],
              options["input"] == nil || options["input"] is String else {
            throw failure("\(kind) 声明存在无法完整解析的路径、参数或选项。")
        }
        for key in ["must_succeed", "sudo", "print_stdout", "print_stderr"] where options[key] != nil {
            guard options[key] is Bool else { throw failure("\(kind) 的 \(key) 选项格式无效。") }
        }
        let args = options["args"] as? [String] ?? []
        guard !args.contains(where: { $0.contains("\0") }) else { throw failure("卸载脚本参数包含无效字符。") }
        let url: URL
        if executable.hasPrefix("/") || executable.hasPrefix("~/") { url = URL(fileURLWithPath: expand(executable)) }
        else {
            let candidate = staged.appendingPathComponent(executable).standardizedFileURL
            if fm.fileExists(atPath: candidate.path) { url = candidate }
            else if !executable.contains("/"), let found = ([prefix.appendingPathComponent("bin"), prefix.appendingPathComponent("sbin")]
                + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].map(URL.init(fileURLWithPath:)))
                .map({ $0.appendingPathComponent(executable) }).first(where: { fm.isExecutableFile(atPath: $0.path) }) { url = found }
            else { throw failure("找不到可绑定的卸载脚本：\(executable)。必须保留安装时的实际程序。") }
        }
        var evidence = try reviewedFile(url)
        var lines = ["\(kind) 完整调用声明：", try pretty(options), evidence.text]
        // Bind a directly supplied interpreter source too. Inline -c/-e/input
        // content is already displayed verbatim above; indirect loads remain unknown.
        let interpreters: Set<String> = ["sh", "bash", "zsh", "fish", "python", "python3", "ruby", "perl", "osascript"]
        if interpreters.contains(url.lastPathComponent), !args.contains(where: { ["-c", "-e", "-m"].contains($0) }),
           let script = args.first(where: { !$0.hasPrefix("-") }) {
            guard script.hasPrefix("/") else { throw failure("解释器的脚本参数必须是可核对的绝对路径：\(script)") }
            let source = try reviewedFile(URL(fileURLWithPath: script))
            lines.append(source.text)
            evidence.fingerprint += "\n" + source.fingerprint
        }
        return (lines.joined(separator: "\n"), evidence.fingerprint)
    }

    private func reviewedFile(_ url: URL) throws -> (text: String, fingerprint: String) {
        let real = url.resolvingSymlinksInPath()
        guard let attributes = try? fm.attributesOfItem(atPath: real.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 64 * 1024 * 1024 else {
            throw failure("卸载脚本缺失、不是普通文件或超过 64 MiB：\(url.path)")
        }
        let before = try identity(url) + "\n" + identity(real)
        let handle = try FileHandle(forReadingFrom: real)
        defer { try? handle.close() }
        var digest = SHA256(), sample = Data(), count = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            count += chunk.count
            guard count <= 64 * 1024 * 1024 else { throw failure("卸载脚本在读取时超过大小上限。") }
            digest.update(data: chunk)
            if sample.count < 256 * 1024 { sample.append(chunk.prefix(256 * 1024 - sample.count)) }
        }
        guard before == (try identity(url) + "\n" + identity(real)), count == size.intValue else {
            throw failure("卸载脚本在读取时发生变化，请重新预览。")
        }
        let checksum = Self.hex(digest.finalize())
        var lines = ["实际程序：\(url.path)", "解析后路径：\(real.path)", "SHA256：\(checksum)（\(count) bytes）"]
        if !sample.contains(0), let source = String(data: sample, encoding: .utf8) {
            guard count <= sample.count else { throw failure("脚本文本过大，无法完整展示：\(url.path)") }
            lines += ["完整文件内容：", source]
        } else { lines.append("该文件为二进制程序，无法展示源代码；其行为及间接加载内容无法静态枚举。") }
        return (lines.joined(separator: "\n"), before + "\n" + checksum)
    }

    private func artifactTarget(_ kind: String, artifact: [String: Any], config: [String: Any]) throws -> String {
        guard let args = artifact[kind] as? [Any], let source = args.first as? String, !source.isEmpty else {
            throw failure("无法解析 \(kind) 工件。")
        }
        let options = args.last as? [String: Any]
        let target = options?["target"] as? String ?? URL(fileURLWithPath: source).lastPathComponent
        guard !target.isEmpty, !target.contains("\0"), !target.contains("{{"), !target.contains("#{") else { throw failure("工件路径包含未展开变量。") }
        let dirKeys = ["app": "appdir", "suite": "appdir", "font": "fontdir", "qlplugin": "qlplugindir",
                       "mdimporter": "mdimporterdir", "prefpane": "prefpanedir", "dictionary": "dictionarydir",
                       "colorpicker": "colorpickerdir", "keyboard_layout": "keyboard_layoutdir", "service": "servicedir",
                       "input_method": "input_methoddir", "internet_plugin": "internet_plugindir", "audio_unit_plugin": "audio_unit_plugindir",
                       "vst_plugin": "vst_plugindir", "vst3_plugin": "vst3_plugindir", "screen_saver": "screen_saverdir"]
        if kind == "bash_completion" || kind == "zsh_completion" || kind == "fish_completion" {
            let basename = URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent
            let folder: String, name: String
            switch kind {
            case "bash_completion": folder = "etc/bash_completion.d"; name = basename
            case "zsh_completion": folder = "share/zsh/site-functions"; name = target.hasPrefix("_") ? target : "_" + basename
            default: folder = "share/fish/vendor_completions.d"; name = target.hasSuffix(".fish") ? target : basename + ".fish"
            }
            guard !name.contains("/"), name != ".", name != ".." else { throw failure("补全脚本的目标路径格式不受支持。") }
            return prefix.appendingPathComponent(folder).appendingPathComponent(name).standardizedFileURL.path
        }
        if target.hasPrefix("/") || target.hasPrefix("~/") { return expand(target) }
        let directory: String
        if kind == "binary" { directory = prefix.appendingPathComponent("bin").path }
        else if let key = dirKeys[kind], let path = configured(key, config) { directory = path }
        else { throw failure("安装配置缺少 \(kind) 目标目录。") }
        return URL(fileURLWithPath: expand(directory)).appendingPathComponent(target).standardizedFileURL.path
    }

    private func configured(_ key: String, _ config: [String: Any]) -> String? {
        for group in ["explicit", "env", "default"] {
            if let value = (config[group] as? [String: Any])?[key] as? String { return value }
        }
        return nil
    }
    /// Permit the minimal local-cask form without evaluating Ruby. Every line is
    /// whitelisted, strings cannot interpolate/escape, and all app declarations
    /// must match the installed receipt. Other Ruby requires explicit source review.
    private func simpleRubyManifest(_ data: Data, token: String, version: String, artifacts: [[String: Any]]) -> Bool {
        guard let text = String(data: data, encoding: .utf8), !text.contains("#{"),
              artifacts.allSatisfy({ Set($0.keys).subtracting(["target"]) == ["app"] }) else { return false }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard lines.first == "cask \"\(token)\" do", lines.last == "end", lines.count >= 5 else { return false }
        let statement = try! NSRegularExpression(pattern: #"^(version|sha256|url|name|desc|homepage|app) "([^"\\\r\n]*)"$"#)
        var apps: [String] = [], versions: [String] = []
        for line in lines.dropFirst().dropLast() {
            if line == "sha256 :no_check" { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = statement.firstMatch(in: line, range: range), match.range == range,
                  let keyRange = Range(match.range(at: 1), in: line), let valueRange = Range(match.range(at: 2), in: line) else { return false }
            let key = String(line[keyRange]), value = String(line[valueRange])
            if key == "app" { apps.append(value) }
            if key == "version" { versions.append(value) }
        }
        let receiptApps = artifacts.compactMap { $0["app"] as? [String] }
        return versions == [version] && receiptApps.count == artifacts.count &&
            receiptApps.allSatisfy({ $0.count == 1 }) && receiptApps.map { $0[0] }.sorted() == apps.sorted() && !apps.isEmpty
    }
    private func validateSelectedApp(_ path: String, bundleID: String) throws {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path,
              path.lowercased().hasSuffix(".app"), !bundleID.isEmpty,
              !path.hasPrefix("/System/"), !path.hasPrefix("/Library/"),
              !Self.protectedIDs.contains(bundleID), try readBundleID(path) == bundleID else {
            throw failure("所选应用路径或标识无效、已变化，或属于受保护应用。")
        }
    }
    private func readBundleID(_ path: String) throws -> String {
        let data = try boundedRead(URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty else { throw failure("无法读取应用身份：\(path)") }
        return id
    }
    private func runningApp(_ path: String, bundleID: String) -> Bool {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.contains {
            !$0.isTerminated && ($0.bundleIdentifier == bundleID || $0.bundleURL?.resolvingSymlinksInPath().path == real)
        }
    }
    private func boundedRead(_ url: URL) throws -> Data {
        guard !isLink(url), let size = try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.intValue <= 2 * 1024 * 1024 else { throw failure("元数据过大或为符号链接：\(url.lastPathComponent)") }
        let data = try Data(contentsOf: url)
        guard data.count <= 2 * 1024 * 1024 else { throw failure("元数据在读取时发生变化。") }
        return data
    }
    private func children(_ url: URL) throws -> [URL] {
        let items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        guard items.count <= 1024 else { throw failure("安装元数据层级条目过多，停止预览。") }
        return items
    }
    private func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("安装元数据不是 JSON 对象。") }
        return value
    }
    private func identity(_ url: URL) throws -> String {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw failure("无法核对路径身份：\(url.path)") }
        let link = isLink(url) ? (try fm.destinationOfSymbolicLink(atPath: url.path)) : ""
        return [url.path, String(value.st_dev), String(value.st_ino), String(value.st_mtimespec.tv_sec),
                String(value.st_mtimespec.tv_nsec), String(value.st_size), String(value.st_mode),
                String(value.st_uid), String(value.st_gid), link].joined(separator: "\u{0}")
    }
    private func isLink(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink }
    private func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    private func expand(_ path: String) -> String {
        let expanded = path == "~" ? home.path : path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))).path : path
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
    private func dangerousRoot(_ path: String) -> Bool {
        let cleaned = expand(path)
        let roots: Set<String> = ["/", "/Applications", "/System", "/Library", "/Users", home.path,
                                  home.appendingPathComponent("Library").path, prefix.path, caskroom.path]
        return roots.contains(cleaned) || roots.contains(String(cleaned.dropLast(cleaned.hasSuffix("/*") ? 2 : 0)))
    }
    private func strings(_ value: Any?) -> [String] {
        if let string = value as? String { return [string] }
        return value as? [String] ?? []
    }
    private func declarationLabel(_ key: String) -> String {
        ["quit": "退出应用", "launchctl": "停止后台服务", "login_item": "移除登录项", "kext": "卸载内核扩展",
         "pkgutil": "移除安装包组件", "delete": "删除", "trash": "移到废纸篓", "rmdir": "移除空目录",
         "script": "执行卸载程序", "early_script": "执行卸载准备程序", "signal": "向进程发送信号", "on_upgrade": "升级处理条件",
         "executable": "程序", "args": "参数", "sudo": "管理员权限", "must_succeed": "必须成功" ][key] ?? key
    }
    private func declarationValue(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let list = value as? [Any] { return list.map(declarationValue).joined(separator: "\n  ") }
        if let map = value as? [String: Any] {
            return map.keys.sorted().map { declarationLabel($0) + "：" + declarationValue(map[$0]!) }.joined(separator: "；")
        }
        return String(describing: value)
    }
    private func pretty(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    private static func validToken(_ token: String) -> Bool {
        token.range(of: #"^[a-z0-9][a-z0-9+@._-]*$"#, options: .regularExpression) != nil && !token.contains("..")
    }
    private static func hex<T: Sequence>(_ bytes: T) -> String where T.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
    private func failure(_ text: String) -> BrewServiceError { .unavailable(text) }
}
