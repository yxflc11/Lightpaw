import Foundation
import Combine

/// All configuration work is serialized. The app's existing 10-second sample
/// drives pending changes; an empty queue does not inspect processes or plugins.
final class CodexToolsModel: ObservableObject {
    @Published private(set) var configurations: [String: ChatCutToolSnapshot] = [:]
    @Published private(set) var groups: [CodexHelperGroup] = []
    @Published private(set) var plugins: [CodexManagedPlugin] = []
    @Published private(set) var changes: [ToolChangeState] = []
    @Published private(set) var busy = false
    @Published private(set) var error = ""
    @Published private(set) var notice = ""
    @Published private(set) var updated: Date?
    @Published private(set) var queueReady = false
    private let worker = DispatchQueue(label: "Lightpaw.tools", qos: .utility)
    private var pending: ToolChangeQueue?
    private var writeGeneration = 0
    private var permittedPlugins: [String: Bool] = [:]
    private static let storageKey = "backgroundToolChanges.v1"

    init() {
        worker.async { [weak self] in
            guard let self else { return }
            do {
                self.pending = try ToolChangeQueue(runtime: ToolChangeRuntime(
                    read: { [unowned self] key in
                        if key.hasPrefix("plugin:") { _ = try self.refreshPluginPermissions() }
                        let snapshot = try self.service(key).snapshot()
                        return ToolConfigurationState(enabled: snapshot.enabled, fingerprint: snapshot.configurationFingerprint)
                    },
                    write: { [unowned self] key, enabled, expected in
                        let service = try self.service(key), reviewed = try service.snapshot()
                        guard reviewed.configurationFingerprint == expected else { throw CodexToolsError.configurationChanged }
                        let resultingFingerprint = try reviewed.fingerprintAfterSetting(enabled)
                        guard Self.activity() == .stopped else { throw ToolChangeQueueError.configurationUnavailable }
                        try service.setEnabled(enabled, reviewed, beforeCommit: {
                            guard Self.activity() == .stopped else { throw ToolChangeQueueError.configurationUnavailable }
                        })
                        self.writeGeneration += 1
                        return ToolConfigurationState(enabled: enabled, fingerprint: resultingFingerprint)
                    }, activity: Self.activity), load: {
                        UserDefaults.standard.data(forKey: Self.storageKey)
                    }, save: { data in
                        let defaults = UserDefaults.standard
                        let previous = defaults.data(forKey: Self.storageKey)
                        defaults.set(data, forKey: Self.storageKey)
                        guard defaults.synchronize(), defaults.data(forKey: Self.storageKey) == data else {
                            defaults.set(previous, forKey: Self.storageKey)
                            _ = defaults.synchronize()
                            throw ToolChangeQueueError.persistence
                        }
                    })
                self.publishChanges()
                DispatchQueue.main.async { self.queueReady = true }
            } catch { self.publishError(error) }
        }
    }

    static func activity() -> ToolChangeActivity {
        let result = listProcesses()
        guard result.error == 0 else { return .unknown }
        let targets = targetExecutables()
        if result.items.contains(where: { targets.contains($0.path) || isEngine($0) }) { return .running }
        return result.skipped == 0 ? .stopped : .unknown
    }

    private func service(_ key: String) throws -> CodexTools {
        guard !CodexTools.isProtectedTargetKey(key) else { throw CodexToolsError.protectedIntegration }
        if key.hasPrefix("mcp:") { return CodexTools(serverID: String(key.dropFirst(4))) }
        if key.hasPrefix("plugin:"), let effective = permittedPlugins[String(key.dropFirst(7))] {
            let service = CodexTools(pluginID: String(key.dropFirst(7)))
            guard try service.snapshot().enabled == effective else { throw ToolChangeQueueError.configurationUnavailable }
            return service
        }
        throw ToolChangeQueueError.configurationUnavailable
    }

    private func refreshPluginPermissions() throws -> [CodexManagedPlugin] {
        permittedPlugins = [:]
        let found = try CodexPluginCatalog.scan()
        permittedPlugins = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.enabled) })
        return found
    }

    func scan(completion: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true; error = ""
        worker.async { [weak self] in
            guard let self else { return }
            self.readInventory()
            DispatchQueue.main.async { self.busy = false; completion?() }
        }
    }

    private func readInventory() {
        var servers: [String: ChatCutToolSnapshot] = [:], failures: [String] = []
        do {
            for id in try CodexTools().configuredServerIDs() {
                do { let value = try CodexTools(serverID: id).snapshot(); servers[value.targetKey] = value }
                catch { failures.append(id + "：" + error.localizedDescription) }
            }
        } catch { failures.append(error.localizedDescription) }
        var found: [CodexManagedPlugin] = []
        do {
            found = try refreshPluginPermissions()
            for plugin in found {
                do { let value = try CodexTools(pluginID: plugin.id).snapshot(); servers[value.targetKey] = value }
                catch { failures.append(plugin.title + "：" + error.localizedDescription) }
            }
        } catch { failures.append("插件清单暂不可用。" + error.localizedDescription) }
        var nodes: [CodexHelperGroup] = []
        do { nodes = try CodexHelperInventory.scan() } catch { failures.append(error.localizedDescription) }
        publishChanges()
        DispatchQueue.main.async {
            self.configurations = servers; self.plugins = found; self.groups = nodes
            self.error = failures.joined(separator: "\n"); self.updated = Date()
        }
    }

    func request(_ key: String, enabled: Bool, reconfirm: Bool = false) {
        guard !busy, queueReady else { return }
        busy = true; error = ""; notice = ""
        worker.async { [weak self] in
            guard let self else { return }
            do {
                guard let pending = self.pending else { throw ToolChangeQueueError.invalidStorage }
                try pending.request(key: key, desired: enabled, reconfirm: reconfirm)
                let waiting = pending.changes.contains { $0.key == key }
                self.publishChanges()
                DispatchQueue.main.async {
                    self.notice = waiting ? "已保存，退出所有 Codex 窗口和命令行任务后自动应用。" : "已撤销，配置保持原状。"
                }
            } catch { self.publishError(error); self.publishChanges() }
            DispatchQueue.main.async { self.busy = false }
        }
    }

    func cancel(_ key: String) {
        guard !busy else { return }
        busy = true; error = ""
        worker.async { [weak self] in
            guard let self else { return }
            do {
                guard let pending = self.pending else { throw ToolChangeQueueError.invalidStorage }
                if pending.changes.contains(where: { $0.key == key }) {
                    try pending.cancel(key: key); self.publishChanges()
                    DispatchQueue.main.async { self.notice = "已撤销，工具配置未改变。" }
                } else {
                    self.readInventory()
                    DispatchQueue.main.async { self.notice = "这项更改已处理，请查看当前开关状态。" }
                }
            } catch { self.publishError(error) }
            DispatchQueue.main.async { self.busy = false }
        }
    }

    func poll() {
        worker.async { [weak self] in
            guard let self, let pending = self.pending,
                  !pending.changes.isEmpty || pending.persistenceNeedsRetry else { return }
            let generation = self.writeGeneration
            var failure: Error?
            do {
                _ = try pending.applyWhenStopped()
            } catch { failure = error }
            self.publishChanges()
            if self.writeGeneration != generation {
                self.readInventory()
                let count = self.writeGeneration - generation
                DispatchQueue.main.async { self.notice = "已应用 \(count) 项更改，下次打开 Codex 时使用新配置。" }
            }
            if let failure { self.publishError(failure) }

        }
    }

    private func publishChanges() {
        let value = pending?.changes ?? []
        DispatchQueue.main.async { if self.changes != value { self.changes = value } }
    }
    private func publishError(_ error: Error) {
        let text = error.localizedDescription
        DispatchQueue.main.async { self.error = text }
    }
}

extension CodexTools {
    static func isProtectedTargetKey(_ key: String) -> Bool {
        if key.hasPrefix("mcp:") { return ChatCutConfigEditor.isProtected(serverID: String(key.dropFirst(4))) }
        if key.hasPrefix("plugin:") { return ChatCutConfigEditor.isProtectedPlugin(String(key.dropFirst(7))) }
        return true
    }
}
