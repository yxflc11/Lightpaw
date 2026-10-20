import AppKit
import CryptoKit
import Darwin
import Foundation

enum BrewUpdateStatus: String {
    case notChecked, current, updateAvailable, automaticUpdates, latest, pinned, disabled, protectedApp, unsupported
    var label: String {
        switch self {
        case .notChecked: return "未检查更新"
        case .current: return "与已刷新配方一致"
        case .updateAvailable: return "有可用更新"
        case .automaticUpdates: return "应用自行更新"
        case .latest: return "版本为 latest，无法比较"
        case .pinned: return "已固定版本"
        case .disabled: return "配方已停用"
        case .protectedApp: return "受保护应用"
        case .unsupported: return "需在 Homebrew 处理"
        }
    }
}

struct BrewUpdateItem: Identifiable {
    let token: String
    let name: String
    let appPaths: [String]
    let installedVersion: String
    let bundleVersion: String?
    let availableVersion: String?
    let source: String
    let status: BrewUpdateStatus
    let autoUpdates: Bool
    let pinned: Bool
    let disabled: Bool
    let hasUpdate: Bool
    let unsupportedReason: String?
    var id: String { token }
    var canPrepare: Bool { hasUpdate && unsupportedReason == nil }
}

struct BrewUpdateSnapshot {
    let items: [BrewUpdateItem]
    let checkedAt: Date
    let metadataRefreshedAt: Date?
    var isFresh: Bool { metadataRefreshedAt.map { Date().timeIntervalSince($0) < 600 } ?? false }
}

struct BrewUpdatePlan {
    let token: String
    let name: String
    let appPaths: [String]
    let installedVersion: String
    let targetVersion: String
    let preview: String
    let requiresAdministrator: Bool
    let unsupportedReason: String?
    var canExecute: Bool { unsupportedReason == nil }
    fileprivate let owner: UUID
    fileprivate let id: UUID
    fileprivate let created: Date
    fileprivate let fingerprint: String
    fileprivate let sourceReference: String
}

enum BrewUpdateError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { switch self { case .unavailable(let reason): return reason } }
}

/// Cask-only, one confirmation per upgrade. Merely opening Applications reads
/// installed receipts; it never evaluates installed Ruby or starts networking.
/// The fixed CLI performs explicit metadata refresh and current-recipe queries.
final class BrewUpdates {
    private let bridge: MoleBridge
    private let brewURL: URL
    private let prefix: URL
    private let caskroom: URL
    private let home: URL
    private let owner = UUID()
    private var busy = false
    private var cancelled = false
    private var usedPlans = Set<UUID>()
    private var snapshot: BrewUpdateSnapshot?
    private var checkedRecords: [String: [String: Any]] = [:]
    private let fm = FileManager.default
    private static let protectedIDs: Set<String> = ["com.openai.codex", "local.codex.memorywatch"]
    private static let protectedTokens: Set<String> = ["codex", "codex-app", "lightpaw", "codex-memory-watch"]
    private static let environment = ["HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_AUTO_UPDATE": "1",
                                      "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1",
                                      "HOMEBREW_NO_INSTALL_CLEANUP": "1"]
    var isRunning: Bool { busy || bridge.isRunning }

    init(brewURL: URL? = nil, caskroomURL: URL? = nil, prefixURL: URL? = nil,
         homeURL: URL = FileManager.default.homeDirectoryForCurrentUser, guardianURL: URL? = nil) {
        let executable = brewURL ?? URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew")
        self.brewURL = executable
        let root = prefixURL ?? executable.deletingLastPathComponent().deletingLastPathComponent()
        prefix = root; caskroom = caskroomURL ?? root.appendingPathComponent("Caskroom"); home = homeURL
        bridge = MoleBridge(executableURL: executable, guardianURL: guardianURL)
    }

    /// Local receipts only. A previous successful check is deliberately not
    /// promoted to a new check time when reloading the application list.
    func loadInstalled(completion: @escaping (Result<BrewUpdateSnapshot, Error>) -> Void) throws {
        try begin()
        do {
            let installed = try discoverInstalled()
            let result = try makeSnapshot(installed, records: [:], refreshedAt: nil)
            snapshot = result; checkedRecords = [:]; busy = false
            DispatchQueue.main.async { completion(.success(result)) }
        } catch { busy = false; DispatchQueue.main.async { completion(.failure(error)) } }
    }

    /// `brew update` refreshes Homebrew and tapped recipe metadata. It does not
    /// upgrade applications. Any failed/cancelled refresh invalidates old plans.
    func checkForUpdates(onOutput: @escaping (String) -> Void,
                         completion: @escaping (Result<BrewUpdateSnapshot, Error>) -> Void) throws {
        try begin(); snapshot = nil; checkedRecords = [:]
        do {
            _ = try discoverInstalled()
            try run(["update"], timeout: 300, label: "刷新 Homebrew 配方", onOutput: onOutput) { [weak self] update in
                guard let self else { return }
                do {
                    _ = try update.get()
                    let refreshed = Date(), installed = try self.discoverInstalled()
                    let refs = installed.compactMap { $0.sourceReference }.sorted()
                    if refs.isEmpty {
                        let result = try self.makeSnapshot(installed, records: [:], refreshedAt: refreshed)
                        self.snapshot = result; self.busy = false; completion(.success(result)); return
                    }
                    try self.run(["info", "--cask", "--json=v2"] + refs, timeout: 120,
                                 label: "读取已刷新 cask 配方", onOutput: { _ in }) { result in
                        do {
                            let output = try result.get()
                            let records = try Self.inventory(Data(output.stdout.utf8))
                            let byToken = Dictionary(uniqueKeysWithValues: records.map { ($0["token"] as! String, $0) })
                            let requested = Set(installed.filter { $0.sourceReference != nil }.map { $0.token })
                            guard Set(byToken.keys) == requested else { throw self.failure("Homebrew 返回的配方与请求的已安装 cask 不一致。") }
                            let result = try self.makeSnapshot(installed, records: byToken, refreshedAt: refreshed)
                            self.checkedRecords = byToken; self.snapshot = result; self.busy = false
                            completion(.success(result))
                        } catch { self.busy = false; completion(.failure(error)) }
                    }
                } catch { self.busy = false; completion(.failure(error)) }
            }
        } catch { busy = false; throw error }
    }

    func prepare(token: String, expectedVersion: String, onOutput: @escaping (String) -> Void,
                 completion: @escaping (Result<BrewUpdatePlan, Error>) -> Void) throws {
        guard let snapshot, snapshot.isFresh,
              let item = snapshot.items.first(where: { $0.token == token }), item.canPrepare,
              item.availableVersion == expectedVersion, let prior = checkedRecords[token] else {
            throw failure("检查结果已过期、目标版本已变化或该应用不支持直接更新，请重新检查。")
        }
        try begin()
        do {
            let installed = try installedRecord(token)
            guard let reference = installed.sourceReference else { throw failure(installed.reason ?? "无法绑定当前配方来源。") }
            try readCurrent(reference: reference) { [weak self] result in
                guard let self else { return }
                do {
                    let record = try result.get()
                    guard try Self.recipeDigest(record) == Self.recipeDigest(prior) else { throw self.failure("配方或安装版本在检查后发生变化，请重新检查。") }
                    let plan = try self.makePlan(token: token, expectedVersion: expectedVersion, record: record)
                    onOutput("已核对 \(plan.name)：\(plan.installedVersion) → \(plan.targetVersion)\n")
                    self.busy = false; completion(.success(plan))
                } catch { self.busy = false; completion(.failure(error)) }
            }
        } catch { busy = false; throw error }
    }

    func upgrade(_ plan: BrewUpdatePlan, onOutput: @escaping (String) -> Void,
                 completion: @escaping (MoleCommandResult) -> Void) throws {
        guard plan.owner == owner, plan.canExecute, !usedPlans.contains(plan.id),
              Self.confirmationIsFresh(created: plan.created),
              snapshot?.isFresh == true else { throw failure("更新确认已失效，请重新检查并确认目标版本。") }
        try begin(); usedPlans.insert(plan.id)
        do {
            try readCurrent(reference: plan.sourceReference) { [weak self] result in
                guard let self else { return }
                do {
                    let record = try result.get()
                    let current = try self.makePlan(token: plan.token, expectedVersion: plan.targetVersion, record: record)
                    guard current.canExecute, current.fingerprint == plan.fingerprint,
                          current.installedVersion == plan.installedVersion else {
                        throw self.failure(current.unsupportedReason ?? "应用、安装记录或配方来源已变化，请重新确认。")
                    }
                    guard !self.cancelled else { throw self.failure("已取消更新。") }
                    // No shell, formulae, greedy-all, force, zap or autoremove.
                    try self.bridge.start(arguments: ["upgrade", "--cask", plan.token], timeout: 1800,
                                          environment: Self.environment, allowAdministratorPrompt: plan.requiresAdministrator,
                                          administratorOperation: "更新",
                                          onOutput: onOutput) { result in
                        self.busy = false; self.snapshot = nil; self.checkedRecords = [:]
                        if result.exitCode == 0 && !result.cancelled && !result.truncated {
                            do {
                                let installed = try self.installedRecord(plan.token)
                                guard installed.version == plan.targetVersion, installed.appPaths == plan.appPaths,
                                      installed.sourceReference == plan.sourceReference else {
                                    throw self.failure("Homebrew 命令已结束，但安装记录未达到确认的目标版本；请重新检查。")
                                }
                                completion(result)
                            } catch {
                                completion(MoleCommandResult(exitCode: 1, stdout: result.stdout,
                                                             stderr: result.stderr + "\n" + error.localizedDescription,
                                                             cancelled: false, truncated: false))
                            }
                        } else { completion(result) }
                    }
                } catch {
                    self.busy = false
                    completion(MoleCommandResult(exitCode: self.cancelled ? 130 : 1, stdout: "", stderr: error.localizedDescription,
                                                 cancelled: self.cancelled, truncated: false))
                }
            }
        } catch { busy = false; throw error }
    }

    func cancel() { cancelled = true; bridge.cancel() }

    private func begin() throws {
        guard !isRunning else { throw failure("已有 Homebrew 操作正在运行。") }
        busy = true; cancelled = false
    }
    private func run(_ args: [String], timeout: TimeInterval, label: String, onOutput: @escaping (String) -> Void,
                     completion: @escaping (Result<MoleCommandResult, Error>) -> Void) throws {
        guard !cancelled else { throw failure("已取消\(label)。") }
        try bridge.start(arguments: args, timeout: timeout, environment: Self.environment, onOutput: onOutput) { [weak self] result in
            guard let self else { return }
            if result.cancelled || self.cancelled { self.cancelled = true; completion(.failure(self.failure("已取消\(label)。"))) }
            else if result.exitCode != 0 || result.truncated {
                completion(.failure(self.failure("\(label)失败，不能将缓存当作最新结果。\n" + String(result.stderr.suffix(1500)))))
            } else { completion(.success(result)) }
        }
    }
    private func readCurrent(reference: String, completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        try run(["info", "--cask", "--json=v2", reference], timeout: 90, label: "复核更新配方", onOutput: { _ in }) { result in
            do {
                let records = try Self.inventory(Data(result.get().stdout.utf8))
                guard records.count == 1 else { throw self.failure("所选 cask 未返回唯一配方。") }
                completion(.success(records[0]))
            } catch { completion(.failure(error)) }
        }
    }

    // Strict JSON root and required fields; no extraction from mixed output and
    // no accepting numeric 0/1 as JSON booleans. Also used by fixture tests.
    static func inventory(_ data: Data) throws -> [[String: Any]] {
        let root = try dictionary(data)
        guard let formulae = root["formulae"] as? [Any], formulae.isEmpty,
              let records = root["casks"] as? [[String: Any]], records.count <= 4096 else {
            throw BrewUpdateError.unavailable("Homebrew cask JSON 格式不受支持。")
        }
        var seen = Set<String>()
        for record in records {
            guard let token = record["token"] as? String, validToken(token), seen.insert(token).inserted,
                  let installed = record["installed"] as? String, validVersion(installed),
                  (record["version"] is NSNull || (record["version"] as? String).map(validVersion) == true),
                  let names = record["name"] as? [String], !names.isEmpty, names.allSatisfy({ validText($0, limit: 500) }),
                  bool(record["pinned"]) != nil, bool(record["disabled"]) != nil, bool(record["outdated"]) != nil,
                  (record["auto_updates"] is NSNull || bool(record["auto_updates"]) != nil),
                  record["artifacts"] is [[String: Any]] else {
                throw BrewUpdateError.unavailable("Homebrew JSON 包含无效、重复或缺少状态字段的 cask。")
            }
        }
        return records
    }

    private struct Installed {
        let token: String
        let version: String
        let tap: String
        let name: String
        let appPaths: [String]
        let bundleIDs: [String]
        let bundleVersion: String?
        let artifacts: [[String: Any]]
        let config: [String: Any]
        let sourceReference: String?
        let fingerprint: String
        let reason: String?
    }
    private func discoverInstalled() throws -> [Installed] {
        guard fm.isExecutableFile(atPath: brewURL.path) else { throw failure("未找到 Homebrew。") }
        guard fm.fileExists(atPath: caskroom.path) else { return [] }
        guard !isLink(caskroom) else { throw failure("Caskroom 是符号链接，无法核对安装来源。") }
        return try children(caskroom).filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
            .map { try installedRecord($0.lastPathComponent) }
    }
    private func installedRecord(_ token: String) throws -> Installed {
        guard Self.validToken(token) else { throw failure("无效的 cask 名称。") }
        let directory = caskroom.appendingPathComponent(token), metadata = directory.appendingPathComponent(".metadata")
        guard !isLink(directory), !isLink(metadata) else { throw failure("cask 安装目录或元数据为符号链接。") }
        let receiptURL = metadata.appendingPathComponent("INSTALL_RECEIPT.json"), configURL = metadata.appendingPathComponent("config.json")
        let receiptData = try read(receiptURL), configData = try read(configURL)
        let receipt = try Self.dictionary(receiptData), config = try Self.dictionary(configData)
        guard let source = receipt["source"] as? [String: Any], let version = source["version"] as? String, Self.validVersion(version),
              let artifacts = receipt["uninstall_artifacts"] as? [[String: Any]], !artifacts.isEmpty else {
            throw failure("\(token) 的安装收据缺少版本或工件，无法完整核对应用列表。")
        }
        let tap = source["tap"] as? String ?? ""
        let manifest = try installedManifest(metadata, token: token), manifestData = try read(manifest)
        guard manifest.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == version else {
            throw failure("\(token) 的安装配方版本与收据版本不一致。")
        }
        var reasons: [String] = []
        if Self.bool(receipt["uninstall_flight_blocks"]) != false { reasons.append("已安装版本含卸载 Ruby 钩子，当前更新入口暂不执行。") }
        if manifest.pathExtension == "rb" && !Self.simpleRuby(manifestData, token: token, version: version, installedArtifacts: artifacts) {
            reasons.append("已安装 Ruby 配方包含无法静态核对的操作。")
        }
        var paths: [String] = [], ids: [String] = [], bundleVersion: String?, name: String?
        var digest = SHA256()
        for value in [receiptData, configData, manifestData] { digest.update(data: value) }
        for url in [directory, metadata, receiptURL, configURL, manifest, brewURL] { digest.update(data: Data(try identity(url).utf8)) }
        for artifact in artifacts where artifact["app"] != nil {
            let path = try appTarget(artifact, config: config)
            guard !paths.contains(path), !isLink(URL(fileURLWithPath: path)) else { throw failure("\(token) 的应用目标重复或为符号链接。") }
            paths.append(path)
            do {
                let url = URL(fileURLWithPath: path), data = try read(url.appendingPathComponent("Contents/Info.plist"))
                guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty else { throw failure("无法读取应用身份。") }
                ids.append(id); name = name ?? (plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String)
                bundleVersion = bundleVersion ?? (plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String)
                digest.update(data: data); digest.update(data: Data(try identity(url).utf8))
                if Self.protectedIDs.contains(id) { reasons.append("Codex 与 Lightpaw 受保护，请使用各自的更新入口。") }
            } catch { reasons.append("应用工件缺失或身份无法核对：\(path)") }
        }
        if paths.isEmpty { reasons.append("该 cask 未提供可识别的桌面应用。") }
        if Self.protectedTokens.contains(token) { reasons.append("Codex 与 Lightpaw 受保护，请使用各自的更新入口。") }
        var reference: String?
        if tap == "homebrew/cask" { reference = "homebrew/cask/" + token }
        else if validTap(tap), let path = source["path"] as? String {
            let parts = tap.split(separator: "/"), tapRoot = prefix.appendingPathComponent("Library/Taps/\(parts[0])/homebrew-\(parts[1])")
            let sourceURL = URL(fileURLWithPath: path)
            if path.hasPrefix(tapRoot.path + "/Casks/"), sourceURL.pathExtension == "rb",
               sourceURL.resolvingSymlinksInPath().path == path,
               let data = try? read(sourceURL), Self.simpleRuby(data, token: token, version: nil) {
                reference = tap + "/" + token
                digest.update(data: data)
            } else { reasons.append("第三方 tap 当前配方无法静态核对；请在 Homebrew 审阅后更新。") }
        } else { reasons.append("安装收据没有可核对的 tap 来源；请在 Homebrew 处理。") }
        return Installed(token: token, version: version, tap: tap, name: name ?? URL(fileURLWithPath: paths.first ?? token).deletingPathExtension().lastPathComponent,
                         appPaths: paths.sorted(), bundleIDs: ids, bundleVersion: bundleVersion, artifacts: artifacts, config: config,
                         sourceReference: reference, fingerprint: Self.hex(digest.finalize()), reason: reasons.isEmpty ? nil : reasons.joined(separator: "\n"))
    }

    private func makeSnapshot(_ installed: [Installed], records: [String: [String: Any]], refreshedAt: Date?) throws -> BrewUpdateSnapshot {
        let items = try installed.map { installed -> BrewUpdateItem in
            let record = records[installed.token]
            var reasons = installed.reason.map { [$0] } ?? []
            var state: BrewUpdateStatus = .notChecked
            let target = record?["version"] as? String, automatic = Self.bool(record?["auto_updates"]) ?? false
            let pinned = Self.bool(record?["pinned"]) ?? isPinned(installed.token), disabled = Self.bool(record?["disabled"]) ?? false
            let outdated = Self.bool(record?["outdated"]) ?? false
            if let record {
                reasons += try policyReasons(record, installed: installed)
                state = outdated ? .updateAvailable : automatic ? .automaticUpdates : .current
                if target == nil { state = .unsupported; reasons.append("当前平台没有可用版本。") }
                if target == "latest" { state = .latest; reasons.append("配方版本为 latest，无法确认明确的更新目标。") }
            }
            if pinned { state = .pinned; reasons.append("Homebrew 已固定该版本。请先在 Homebrew 明确解除固定。") }
            if disabled { state = .disabled; reasons.append("Homebrew 已停用该配方：\(record?["disable_reason"] as? String ?? "未说明原因")") }
            let protected = Self.protectedTokens.contains(installed.token) || !Set(installed.bundleIDs).isDisjoint(with: Self.protectedIDs)
            if protected { state = .protectedApp }
            else if !reasons.isEmpty && ![BrewUpdateStatus.latest, .pinned, .disabled].contains(state) { state = .unsupported }
            let hasUpdate = target != nil && target != "latest" && outdated
            return BrewUpdateItem(token: installed.token, name: installed.name, appPaths: installed.appPaths, installedVersion: installed.version,
                                  bundleVersion: installed.bundleVersion, availableVersion: target, source: installed.tap, status: state,
                                  autoUpdates: automatic, pinned: pinned, disabled: disabled, hasUpdate: hasUpdate,
                                  unsupportedReason: reasons.isEmpty ? nil : Array(Set(reasons)).sorted().joined(separator: "\n"))
        }
        return BrewUpdateSnapshot(items: items, checkedAt: Date(), metadataRefreshedAt: refreshedAt)
    }

    // Fixture seam, also used immediately before execution. It cannot execute a
    // plan without an owner-bound successful refresh and the separate upgrade API.
    func makePlan(token: String, expectedVersion: String, record: [String: Any]) throws -> BrewUpdatePlan {
        let installed = try installedRecord(token)
        guard record["token"] as? String == token, record["installed"] as? String == installed.version,
              record["version"] as? String == expectedVersion, expectedVersion != "latest",
              let reference = installed.sourceReference else { throw failure("cask 身份、安装版本、目标版本或配方来源已变化。") }
        let item = try makeSnapshot([installed], records: [token: record], refreshedAt: Date()).items[0]
        var reasons = item.unsupportedReason.map { [$0] } ?? []
        if !item.hasUpdate { reasons.append("Homebrew 未报告这个明确版本可更新。") }
        for (path, id) in zip(installed.appPaths, installed.bundleIDs) {
            if NSWorkspace.shared.runningApplications.contains(where: { !$0.isTerminated && ($0.bundleIdentifier == id || $0.bundleURL?.resolvingSymlinksInPath().path == path) }) {
                reasons.append("应用仍在运行，请正常退出后重新确认：\(URL(fileURLWithPath: path).lastPathComponent)")
            }
        }
        let admin = installed.appPaths.contains { !fm.isWritableFile(atPath: URL(fileURLWithPath: $0).deletingLastPathComponent().path) }
        var digest = SHA256(); digest.update(data: Data(installed.fingerprint.utf8)); digest.update(data: Data(try Self.recipeDigest(record).utf8))
        var lines = ["应用：\(item.name)", "Homebrew cask：\(token)", "配方来源：\(installed.tap)", "Homebrew 安装记录：\(item.installedVersion)"]
        if let actual = item.bundleVersion { lines.append("应用报告版本：\(actual)") }
        lines += ["确认目标版本：\(expectedVersion)", "", "将替换以下应用："] + installed.appPaths.map { "• " + $0 }
        let dependencies = dependencyNames(record)
        if !dependencies.isEmpty { lines += ["", "配方依赖："] + dependencies.map { "• " + $0 } }
        lines += ["", "仅运行 brew upgrade --cask \(token)。个人配置不会通过 zap 清理；关闭自动依赖移除与安装后自动清理。"]
        if item.autoUpdates { lines.append("该应用可自行更新，Homebrew 的安装记录可能与应用报告版本不同。") }
        if admin { lines.append("替换应用需要管理员权限，执行时会打开密码窗口。") }
        if !reasons.isEmpty { lines += ["", reasons.joined(separator: "\n")] }
        return BrewUpdatePlan(token: token, name: item.name, appPaths: item.appPaths, installedVersion: item.installedVersion, targetVersion: expectedVersion,
                              preview: lines.joined(separator: "\n"), requiresAdministrator: admin,
                              unsupportedReason: reasons.isEmpty ? nil : reasons.joined(separator: "\n"), owner: owner, id: UUID(), created: Date(),
                              fingerprint: Self.hex(digest.finalize()), sourceReference: reference)
    }

    private func policyReasons(_ record: [String: Any], installed: Installed) throws -> [String] {
        var reasons: [String] = []
        guard record["token"] as? String == installed.token, record["installed"] as? String == installed.version,
              record["tap"] as? String == installed.tap else { throw failure("\(installed.token) 的当前配方与安装收据身份不一致。") }
        guard let path = record["ruby_source_path"] as? String, path.hasPrefix("Casks/"), !path.split(separator: "/").contains(".."),
              let checksum = (record["ruby_source_checksum"] as? [String: Any])?["sha256"] as? String,
              checksum.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            return ["当前配方缺少可复核的 Ruby 来源与 SHA-256。"]
        }
        if installed.tap != "homebrew/cask", validTap(installed.tap) {
            let parts = installed.tap.split(separator: "/")
            let source = prefix.appendingPathComponent("Library/Taps/\(parts[0])/homebrew-\(parts[1])").appendingPathComponent(path)
            guard source.resolvingSymlinksInPath().path == source.path,
                  Self.hex(SHA256.hash(data: try read(source))) == checksum else {
                throw failure("第三方 tap 配方文件与 Homebrew 报告的来源校验值不同。")
            }
        }
        let dependencies = dependencyNames(record)
        if !dependencies.isEmpty { reasons.append("更新可能改变其他包，本轮不自动处理配方依赖：" + dependencies.joined(separator: "、")) }
        let artifacts = record["artifacts"] as? [[String: Any]] ?? []
        let targets = try artifacts.filter { $0["app"] != nil }.map { try appTarget($0, config: installed.config) }.sorted()
        if targets != installed.appPaths { reasons.append("新配方的应用目标与已安装应用不同，需在 Homebrew 审阅。") }
        for group in [installed.artifacts, artifacts] {
            for artifact in group {
                let keys = Set(artifact.keys).subtracting(["target"])
                guard keys.count == 1, let kind = keys.first else { reasons.append("配方工件结构不明确。"); continue }
                switch kind {
                case "app", "zap": break
                case "binary":
                    guard let args = artifact["binary"] as? [Any], let source = args.first as? String,
                          installed.appPaths.contains(where: { source.hasPrefix($0 + "/Contents/") }),
                          let target = binaryTarget(artifact), target.hasPrefix(prefix.appendingPathComponent("bin").path + "/"),
                          URL(fileURLWithPath: target).deletingLastPathComponent().path == prefix.appendingPathComponent("bin").path else {
                        reasons.append("binary 工件超出此应用内部文件及 Homebrew bin 的范围。"); continue
                    }
                case "uninstall":
                    guard let groups = artifact[kind] as? [[String: Any]], groups.allSatisfy({ Set($0.keys) == ["quit"] && !strings($0["quit"]).isEmpty && Set(strings($0["quit"])).isSubset(of: Set(installed.bundleIDs)) }) else {
                        reasons.append("更新需要执行额外卸载指令，当前入口暂不执行。"); continue
                    }
                default: reasons.append("配方包含 \(kind) 操作，当前入口暂不执行。")
                }
            }
        }
        if Self.bool(record["caveats_rosetta"]) == true { reasons.append("配方要求 Rosetta，当前入口不安装系统组件。") }
        return reasons
    }

    private func dependencyNames(_ record: [String: Any]) -> [String] {
        guard let dependencies = record["depends_on"] as? [String: Any] else { return [] }
        return dependencies.keys.sorted().filter { !["macos", "arch"].contains($0) }.flatMap { key -> [String] in
            let values = strings(dependencies[key]); return values.isEmpty ? [key + "（未知格式）"] : values.map { key + ": " + $0 }
        }
    }
    private func appTarget(_ artifact: [String: Any], config: [String: Any]) throws -> String {
        guard let args = artifact["app"] as? [Any], let source = args.first as? String, !source.isEmpty else { throw failure("app 工件缺少文件名。") }
        let options = args.last as? [String: Any]
        let target = options?["target"] as? String ?? URL(fileURLWithPath: source).lastPathComponent
        let directory = ["explicit", "env", "default"].compactMap { (config[$0] as? [String: Any])?["appdir"] as? String }.first
        guard let directory, directory.hasPrefix("/"), !target.contains(".."), !target.contains("{{"), !target.contains("#{"), !target.contains("\0") else { throw failure("app 目标目录无法核对。") }
        let path = target.hasPrefix("/") ? target : URL(fileURLWithPath: directory).appendingPathComponent(target).path
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path, path.lowercased().hasSuffix(".app"),
              !path.hasPrefix("/System/"), !path.hasPrefix("/Library/") else { throw failure("app 工件目标不受支持。") }
        if let reported = artifact["target"] as? String, reported != path { throw failure("Homebrew 报告的 app 目标与安装配置不一致。") }
        return path
    }
    private func binaryTarget(_ artifact: [String: Any]) -> String? {
        guard let args = artifact["binary"] as? [Any], let source = args.first as? String else { return nil }
        let raw = (args.last as? [String: Any])?["target"] as? String ?? URL(fileURLWithPath: source).lastPathComponent
        let path = raw.hasPrefix("/") ? raw : prefix.appendingPathComponent("bin").appendingPathComponent(raw).path
        guard !raw.contains(".."), URL(fileURLWithPath: path).standardizedFileURL.path == path else { return nil }
        return path
    }
    private func installedManifest(_ metadata: URL, token: String) throws -> URL {
        var timestamps: [URL] = []
        for version in try children(metadata) where isDirectory(version) && !isLink(version) {
            for stamp in try children(version) where isDirectory(stamp) && !isLink(stamp) && stamp.lastPathComponent.range(of: "^[0-9]{14}\\.[0-9]+$", options: .regularExpression) != nil { timestamps.append(stamp) }
        }
        guard let latest = timestamps.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else { throw failure("缺少 \(token) 的已安装配方快照。") }
        let folder = latest.appendingPathComponent("Casks")
        guard !isLink(folder) else { throw failure("安装配方目录是符号链接。") }
        for suffix in ["json", "internal.json", "rb"] {
            let file = folder.appendingPathComponent(token + "." + suffix)
            if fm.fileExists(atPath: file.path) { return file }
        }
        throw failure("缺少 \(token) 的已安装配方快照。")
    }
    static func simpleRuby(_ data: Data, token: String, version: String?, installedArtifacts: [[String: Any]]? = nil) -> Bool {
        guard let text = String(data: data, encoding: .utf8), !text.contains("#{") else { return false }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard lines.first == "cask \"\(token)\" do", lines.last == "end", lines.count >= 5 else { return false }
        var versions: [String] = [], apps: [String] = []
        let pattern = #"^(version|sha256|url|name|desc|homepage|app) "([^"\\\r\n]*)"$"#
        for line in lines.dropFirst().dropLast() {
            if line == "sha256 :no_check" { continue }
            guard line.range(of: pattern, options: .regularExpression) != nil else { return false }
            if line.hasPrefix("version ") { versions.append(String(line.dropFirst(9).dropLast())) }
            if line.hasPrefix("app ") { apps.append(String(line.dropFirst(5).dropLast())) }
        }
        if let installedArtifacts {
            let recorded = installedArtifacts.compactMap { $0["app"] as? [String] }
            guard recorded.count == installedArtifacts.count, recorded.allSatisfy({ $0.count == 1 }),
                  recorded.map({ $0[0] }).sorted() == apps.sorted() else { return false }
        }
        return versions.count == 1 && (version == nil || versions == [version!]) && !apps.isEmpty
    }
    static func confirmationIsFresh(created: Date, now: Date = Date()) -> Bool { now.timeIntervalSince(created) >= 0 && now.timeIntervalSince(created) < 300 }
    private static func recipeDigest(_ record: [String: Any]) throws -> String {
        hex(SHA256.hash(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])))
    }
    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard data.count <= 16 * 1024 * 1024, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BrewUpdateError.unavailable("Homebrew 未返回完整 JSON 对象。") }
        return value
    }
    private static func bool(_ value: Any?) -> Bool? { guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }; return n.boolValue }
    private static func validToken(_ token: String) -> Bool { token.range(of: "^[a-z0-9][a-z0-9+@._-]{0,127}$", options: .regularExpression) != nil && !token.contains("..") }
    private static func validText(_ text: String, limit: Int) -> Bool { !text.isEmpty && text.utf8.count <= limit && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    private static func validVersion(_ version: String) -> Bool { validText(version, limit: 256) && !version.contains("/") && !version.contains("\\") }
    private func validTap(_ tap: String) -> Bool { tap.range(of: "^[a-z0-9][a-z0-9_-]*/[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil }
    private func isPinned(_ token: String) -> Bool { fm.fileExists(atPath: prefix.appendingPathComponent("var/homebrew/pinned_casks/" + token).path) }
    private func strings(_ value: Any?) -> [String] { if let text = value as? String { return [text] }; return value as? [String] ?? [] }
    private func read(_ url: URL) throws -> Data {
        guard !isLink(url), let size = try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024 else { throw failure("文件过大或是符号链接：\(url.lastPathComponent)") }
        let data = try Data(contentsOf: url)
        guard data.count <= 2 * 1024 * 1024 else { throw failure("读取期间文件发生变化。") }
        return data
    }
    private func children(_ url: URL) throws -> [URL] { let files = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil); guard files.count <= 4096 else { throw failure("Homebrew 元数据条目过多。") }; return files }
    private func isLink(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink }
    private func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    private func identity(_ url: URL) throws -> String {
        var value = stat(); guard lstat(url.path, &value) == 0 else { throw failure("无法核对文件身份：\(url.lastPathComponent)") }
        return [url.path, String(value.st_dev), String(value.st_ino), String(value.st_mtimespec.tv_sec), String(value.st_mtimespec.tv_nsec), String(value.st_size)].joined(separator: "\0")
    }
    private static func hex<D: Sequence>(_ data: D) -> String where D.Element == UInt8 { data.map { String(format: "%02x", $0) }.joined() }
    private func failure(_ text: String) -> BrewUpdateError { .unavailable(text) }
}
