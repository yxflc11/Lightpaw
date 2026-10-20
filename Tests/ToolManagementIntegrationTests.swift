// All default checks use private temporary fixtures. Opt in to the final
// read-only local configuration/process check with --local-compatibility.
// No argv, configuration values, reloads or signals are emitted.
import Foundation
import Darwin

private final class ManagementFixture {
    static let mcpKey = "mcp:fixture_notes"
    static let pluginKey = "plugin:fixture-palette@fixture-market"
    static let source = "# retained fixture bytes\nmodel = 'fixture'\n[mcp_servers.fixture_notes]\nenabled = true # preserve MCP comment\ncommand = '/fixture/never-opened'\n[mcp_servers.fixture_notes.env]\nSECRET = 'FIXTURE_SECRET_SENTINEL'\n[plugins.\"fixture-palette@fixture-market\"]\nenabled = true # preserve plugin comment\n[features]\nother = false\n"
    let directory: URL
    let config: URL
    let storage: URL
    var activity = ToolChangeActivity.running
    var now = Date(timeIntervalSince1970: 1_000)
    var processOperations = 0, writesAttempted = 0, commitChecks = 0
    var commits: [(key: String, before: String, after: String)] = []
    var beforeCommit: (() throws -> Void)?
    var afterWrite: (() throws -> Void)?

    init(root: URL, name: String) throws {
        directory = root.appendingPathComponent(name)
        config = directory.appendingPathComponent("config.toml")
        storage = directory.appendingPathComponent("pending.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(Self.source.utf8).write(to: config)
        guard chmod(config.path, 0o600) == 0 else { throw CodexToolsError.io("fixture chmod") }
    }

    func service(_ key: String) throws -> CodexTools {
        var runtime = CodexToolsRuntime()
        runtime.list = { [unowned self] in processOperations += 1; return ([], 0, EACCES) }
        runtime.targets = { [unowned self] in processOperations += 1; return [] }
        runtime.validate = { [unowned self] _ in processOperations += 1; return false }
        runtime.kind = { [unowned self] _ in processOperations += 1; return nil }
        runtime.footprint = { [unowned self] _ in processOperations += 1; return nil }
        runtime.identityStatus = { [unowned self] _ in processOperations += 1; return EACCES }
        runtime.terminate = { [unowned self] _ in processOperations += 1; return EPERM }
        runtime.sleep = { [unowned self] _ in processOperations += 1 }
        switch key {
        case Self.mcpKey: return CodexTools(configURL: config, serverID: "fixture_notes", runtime: runtime)
        case Self.pluginKey: return CodexTools(configURL: config, pluginID: "fixture-palette@fixture-market", runtime: runtime)
        default: throw ToolChangeQueueError.invalidKey
        }
    }

    func makeQueue() throws -> ToolChangeQueue {
        let runtime = ToolChangeRuntime(read: { [self] key in
            let snapshot = try service(key).snapshot()
            return ToolConfigurationState(enabled: snapshot.enabled, fingerprint: snapshot.configurationFingerprint)
        }, write: { [self] key, enabled, expected in
            writesAttempted += 1
            let writer = try service(key), snapshot = try writer.snapshot()
            guard snapshot.configurationFingerprint == expected else { throw CodexToolsError.configurationChanged }
            let resultingFingerprint = try snapshot.fingerprintAfterSetting(enabled)
            guard activity == .stopped else { throw ToolChangeQueueError.configurationUnavailable }
            try writer.setEnabled(enabled, snapshot, beforeCommit: {
                self.commitChecks += 1
                try self.beforeCommit?()
                guard self.activity == .stopped else { throw ToolChangeQueueError.configurationUnavailable }
            })
            commits.append((key, expected, resultingFingerprint))
            try afterWrite?()
            // Use the precise planned bytes, not a subsequent read that could
            // silently adopt an unrelated external edit as our own revision.
            return ToolConfigurationState(enabled: enabled, fingerprint: resultingFingerprint)
        }, activity: { [self] in activity }, now: { [self] in now })
        return try ToolChangeQueue(runtime: runtime, load: { [self] in
            FileManager.default.fileExists(atPath: storage.path) ? try Data(contentsOf: storage) : nil
        }, save: { [self] bytes in
            try bytes.write(to: storage, options: .atomic)
            guard chmod(storage.path, 0o600) == 0 else { throw ToolChangeQueueError.persistence }
        })
    }

    func applyAfterStopped(_ queue: ToolChangeQueue) throws -> [String] {
        activity = .stopped
        _ = try queue.applyWhenStopped()
        now += 2
        return try queue.applyWhenStopped()
    }

    func sourceBytes() throws -> Data { try Data(contentsOf: config) }
    func backupURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("config.toml.mcp-before-") }
    }
    func appendExternalComment() throws {
        var data = try sourceBytes(); data.append(Data("# EXTERNAL_FIXTURE_EDIT\n".utf8)); try data.write(to: config)
    }
}

@main enum ToolManagementIntegrationTests {
    static var failures = 0, checks = 0
    static func check(_ condition: Bool, _ name: String) {
        checks += 1
        print("\(condition ? "PASS" : "FAIL") \(name)")
        if !condition { failures += 1 }
    }
    static func run(_ name: String, _ body: () throws -> Void) {
        do { try body() }
        catch { check(false, name + " threw " + String(describing: type(of: error))) }
    }
    static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body(); check(false, name) } catch { check(true, name) }
    }
    static func mode(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("lightpaw-tool-management-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        run("two target real-writer integration") {
            let f = try ManagementFixture(root: root, name: "sequential"), q = try f.makeQueue()
            let original = try f.sourceBytes()
            try q.request(key: ManagementFixture.mcpKey, desired: false)
            try q.request(key: ManagementFixture.pluginKey, desired: false)
            let originalFingerprint = q.changes[0].fingerprint
            check(q.changes.count == 2 && q.changes.allSatisfy { $0.fingerprint == originalFingerprint }, "both reviewed targets start from the same source fingerprint")
            for _ in 0..<3 { f.now += 10; _ = try q.applyWhenStopped() }
            check(try f.writesAttempted == 0 && f.sourceBytes() == original && f.backupURLs().isEmpty, "running activity prevents config writes and backups")
            f.activity = .unknown; f.now += 10; _ = try q.applyWhenStopped()
            check(try f.writesAttempted == 0 && f.sourceBytes() == original, "unknown activity also prevents real writer invocation")
            f.activity = .stopped
            check(try q.applyWhenStopped().isEmpty && f.sourceBytes() == original, "first stopped observation never changes fixture config")
            f.now += 2
            check(try q.applyWhenStopped() == [ManagementFixture.mcpKey, ManagementFixture.pluginKey] && q.changes.isEmpty, "two targets apply sequentially after stopped evidence")
            check(f.commits.count == 2 && f.commits[0].before == originalFingerprint && f.commits[1].before == f.commits[0].after,
                  "second real writer uses the first exact committed fingerprint")
            let mcp = try f.service(ManagementFixture.mcpKey).snapshot(), plugin = try f.service(ManagementFixture.pluginKey).snapshot()
            check(!mcp.enabled && !plugin.enabled && plugin.configurationFingerprint == f.commits.last?.after, "final actual config matches both requested states and precise final hash")
            let expected = ManagementFixture.source.replacingOccurrences(of: "enabled = true", with: "enabled = false")
            check(try f.sourceBytes() == Data(expected.utf8), "combined writes preserve every unrelated byte and comment")
            let backups = try f.backupURLs()
            check(try backups.count == 2 && backups.allSatisfy { try mode($0) == 0o600 } && mode(f.config) == 0o600, "real writer keeps source and both private backups at 0600")
            let saved = try Data(contentsOf: f.storage)
            check(!String(decoding: saved, as: UTF8.self).contains("FIXTURE_SECRET_SENTINEL"), "persisted queue never includes configuration secret bytes")
            check(f.commitChecks == 2 && f.processOperations == 0, "MCP and plugin changes use commit gates without process inspection or signals")
        }

        run("restart between targets") {
            let f = try ManagementFixture(root: root, name: "between-targets"), q = try f.makeQueue()
            try q.request(key: ManagementFixture.mcpKey, desired: false)
            try q.request(key: ManagementFixture.pluginKey, desired: false)
            f.afterWrite = { f.activity = .running }
            check(try f.applyAfterStopped(q) == [ManagementFixture.mcpKey], "process restart after first commit defers second target")
            check(q.changes.count == 1 && q.changes[0].key == ManagementFixture.pluginKey && q.changes[0].fingerprint == f.commits[0].after,
                  "remaining target persists our own exact fingerprint advancement")
            f.afterWrite = nil
            let restored = try f.makeQueue()
            f.activity = .stopped; f.now += 20
            check(try restored.applyWhenStopped().isEmpty && f.commits.count == 1, "restored queue never persists stopped evidence")
            f.now += 2
            check(try restored.applyWhenStopped() == [ManagementFixture.pluginKey] && restored.changes.isEmpty, "restored advanced fingerprint applies remaining target safely")
            check(try !f.service(ManagementFixture.pluginKey).snapshot().enabled && f.processOperations == 0, "resumed plugin configuration matches requested state without signals")
        }

        run("start during final commit gate") {
            let f = try ManagementFixture(root: root, name: "commit-start"), q = try f.makeQueue()
            let original = try f.sourceBytes()
            try q.request(key: ManagementFixture.mcpKey, desired: false)
            f.beforeCommit = { f.activity = .running }
            check(try f.applyAfterStopped(q).isEmpty && f.writesAttempted == 1 && f.commitChecks == 1, "start inside beforeCommit blocks atomic replacement")
            check(try f.commits.isEmpty && f.sourceBytes() == original, "late process start leaves original configuration unchanged")
            check(q.changes.count == 1 && q.changes[0].status == .failed, "blocked commit remains visible as failed rather than applied")
            let names = try FileManager.default.contentsOfDirectory(atPath: f.directory.path)
            check(!names.contains { $0.hasPrefix(".mcp-config-") }, "blocked commit removes its temporary replacement")
            f.beforeCommit = nil
            check(try f.applyAfterStopped(q).isEmpty && f.writesAttempted == 1, "failed gate is not automatically retried")
            let restored = try f.makeQueue()
            check(restored.changes == q.changes, "failed commit status survives queue restore")
            try restored.cancel(key: ManagementFixture.mcpKey)
            check(try restored.changes.isEmpty && f.sourceBytes() == original && f.makeQueue().changes.isEmpty, "cancelled failed request persists cancellation without touching config")
        }

        run("persist waiting queue and cancel") {
            let f = try ManagementFixture(root: root, name: "restore-cancel"), q = try f.makeQueue()
            let original = try f.sourceBytes()
            try q.request(key: ManagementFixture.mcpKey, desired: false)
            try q.request(key: ManagementFixture.pluginKey, desired: false)
            let restored = try f.makeQueue()
            check(restored.changes == q.changes && restored.changes.count == 2, "both pending intentions restore from private persisted queue")
            check(try mode(f.storage) == 0o600, "fixture queue persistence stays private")
            try restored.cancel(key: ManagementFixture.pluginKey)
            let again = try f.makeQueue()
            check(again.changes.map(\.key) == [ManagementFixture.mcpKey], "cancel removes only selected target from restored queue")
            try again.cancel(key: ManagementFixture.mcpKey)
            check(try f.sourceBytes() == original && f.writesAttempted == 0 && f.makeQueue().changes.isEmpty, "cancel all never invokes the writer and persists empty queue")
        }

        run("external configuration conflicts") {
            let f = try ManagementFixture(root: root, name: "external-conflict"), q = try f.makeQueue()
            try q.request(key: ManagementFixture.mcpKey, desired: false)
            try q.request(key: ManagementFixture.pluginKey, desired: false)
            try f.appendExternalComment()
            let external = try f.sourceBytes()
            check(try f.applyAfterStopped(q).isEmpty && q.changes.allSatisfy { $0.status == .conflict }, "external byte edit conflicts both reviewed target fingerprints")
            check(try f.writesAttempted == 0 && f.sourceBytes() == external && f.backupURLs().isEmpty, "conflict does not overwrite external bytes or create writer backups")
            rejects("conflict requires explicit reviewed reconfirmation") { try q.request(key: ManagementFixture.mcpKey, desired: false) }
            check(try f.makeQueue().changes.allSatisfy { $0.status == .conflict }, "external conflict statuses survive restore")
        }

        run("external edit after own successful write") {
            let f = try ManagementFixture(root: root, name: "post-write-edit"), q = try f.makeQueue()
            try q.request(key: ManagementFixture.mcpKey, desired: false)
            try q.request(key: ManagementFixture.pluginKey, desired: false)
            f.afterWrite = { try f.appendExternalComment() }
            check(try f.applyAfterStopped(q) == [ManagementFixture.mcpKey], "own successful write applies only first target when external edit follows")
            let plugin = try f.service(ManagementFixture.pluginKey).snapshot()
            check(q.changes.count == 1 && q.changes[0].status == .conflict && q.changes[0].fingerprint == f.commits[0].after,
                  "queue advances only to planned committed hash rather than external readback")
            check(plugin.enabled && plugin.configurationFingerprint != q.changes[0].fingerprint && f.commits.count == 1,
                  "external post-write edit preserves second target and is not silently rebased")
        }

        if CommandLine.arguments.contains("--local-compatibility") {
            run("read-only live compatibility") {
                // Never hand a default-path service to a queue or call its setter.
                var readOnlyRuntime = CodexToolsRuntime()
                var forbiddenProcessCalls = 0
                readOnlyRuntime.list = { forbiddenProcessCalls += 1; return ([], 0, 0) }
                let liveConfig = CodexTools(runtime: readOnlyRuntime)
                let ids = try liveConfig.configuredServerIDs()
                for id in ids { _ = try CodexTools(serverID: id, runtime: readOnlyRuntime).snapshot() }
                // The same strict scanner also validates plugin syntax without
                // invoking CLI, argv inspection or any configuration setter.
                _ = try CodexTools(pluginID: "record-and-replay@openai-bundled", runtime: readOnlyRuntime).snapshot()
                check(true, "default configuration is parser-compatible (read-only; no values logged)")
                let processes = listProcesses(), targets = targetExecutables()
                let activity: ToolChangeActivity = processes.error != 0 ? .unknown :
                    processes.items.contains(where: { targets.contains($0.path) || isEngine($0) }) ? .running :
                    processes.skipped == 0 ? .stopped : .unknown
                check(activity == .running, "actual Codex activity is running using executable identities only")
                check(forbiddenProcessCalls <= 1, "live config read never uses argv or process control")
            }
        }

        print("Tool management integration: \(failures == 0 ? "PASS" : "FAIL"), checks=\(checks), failures=\(failures)")
        try FileManager.default.removeItem(at: root)
        exit(failures == 0 ? 0 : 1)
    }
}
