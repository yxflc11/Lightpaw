import Foundation
import Darwin

@main
enum CodexPluginCatalogTests {
    static let fm = FileManager.default
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { print("FAIL: " + message); exit(1) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); check(false, message) } catch { check(true, message) }
    }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 3 && args[1] == "--capture-fixture" {
            switch args[2] {
            case "success": print("{\"installed\":[]}")
            case "large": FileHandle.standardOutput.write(Data(repeating: 65, count: 1024 * 1024 + 1))
            case "timeout": Thread.sleep(forTimeInterval: 30)
            default: exit(2)
            }
            return
        }
        if args.contains("--local-inventory") {
            let plugins = try CodexPluginCatalog.scan()
            for plugin in plugins { print("\(plugin.id) | \(plugin.title) | enabled=\(plugin.enabled) | remote=\(plugin.remote)") }
            check(plugins.contains { $0.id == "record-and-replay@openai-bundled" && !$0.remote }, "local event-stream plugin detected")
            check(plugins.contains { $0.id == "github@openai-curated" && $0.remote }, "HTTP GitHub plugin detected")
            print("\(checks)/\(checks) local checks passed; read-only")
            return
        }
        let temporary = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("lightpaw-plugin-tests-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let cache = temporary.appendingPathComponent("cache")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        func entry(_ name: String, market: String = "test-market", version: String = "1.0", enabled: Bool = true) -> [String: Any] {
            ["pluginId": name + "@" + market, "name": name, "marketplaceName": market, "version": version,
             "installed": true, "enabled": enabled, "source": ["source": "local", "path": "/not-the-installed-copy"], "installPolicy": "AVAILABLE"]
        }
        @discardableResult func install(_ record: [String: Any], declaration: Any? = "./.mcp.json", servers: [String: Any]? = nil,
                                      manifestExtra: [String: Any] = [:]) throws -> URL {
            let root = cache.appendingPathComponent(record["marketplaceName"] as! String).appendingPathComponent(record["name"] as! String).appendingPathComponent(record["version"] as! String)
            try fm.createDirectory(at: root.appendingPathComponent(".codex-plugin"), withIntermediateDirectories: true)
            var manifest: [String: Any] = ["name": record["name"]!, "version": "0.1.6", "interface": ["displayName": "Fixture Tool"]]
            if let declaration { manifest["mcpServers"] = declaration }
            manifest.merge(manifestExtra) { _, value in value }
            try json(manifest).write(to: root.appendingPathComponent(".codex-plugin/plugin.json"))
            try json(["mcpServers": servers ?? ["fixture": ["command": "/fixture/server", "args": ["not-retained"], "env": ["FIXTURE": "not-retained"]]]]).write(to: root.appendingPathComponent(".mcp.json"))
            return root
        }
        func decode(_ records: [[String: Any]]) throws -> [CodexManagedPlugin] {
            try CodexPluginCatalog.decode(json(["installed": records, "available": []]), cacheRoot: cache)
        }
        let local = entry("record-and-replay", market: "openai-bundled", version: "1.0.1001501")
        let remote = entry("github", market: "openai-curated", version: "bd2122cb", enabled: false)
        try install(local, servers: ["event-stream": ["command": "node"]])
        try install(remote, servers: ["github": ["url": "https://fixture.invalid/mcp"]])
        let valid = try decode([local, remote])
        check(valid.map(\.id) == ["github@openai-curated", "record-and-replay@openai-bundled"], "exact IDs and hash-version cache are resolved")
        check(valid[0].remote && !valid[0].enabled && !valid[1].remote && valid[1].enabled, "transport and enabled state preserved")
        check(valid.allSatisfy { $0.title == "Fixture Tool" }, "display title read without retaining server configuration")
        check(try decode([local, local, remote, remote]).map(\.id) == valid.map(\.id), "identical registrations are accepted exactly once")
        var otherSourcePath = local
        otherSourcePath["source"] = ["source": "local", "path": "/different-source-not-installed-cache"]
        check(try decode([local, otherSourcePath]).map(\.id) == [local["pluginId"] as! String], "source path differences do not change eligibility")
        for (key, value) in [("version", "another-version" as Any), ("installPolicy", "REQUIRED" as Any), ("enabled", false as Any)] {
            var conflicting = local; conflicting[key] = value
            check(try decode([local, conflicting]).isEmpty && decode([conflicting, local]).isEmpty,
                  "conflicting duplicate rejected regardless of order: " + key)
        }

        for name in ["codex-app-tools", "unified-computer-use", "code-review"] {
            let record = entry(name, market: "openai-bundled"); try install(record)
            check(try decode([record]).isEmpty, "protected built-in excluded: " + name)
        }
        for (key, value) in [("installed", false as Any), ("installPolicy", "REQUIRED" as Any), ("userUninstallable", false as Any), ("nonUserUninstallable", true as Any), ("source", ["source": "remote"] as Any)] {
            var record = local; record[key] = value
            check(try decode([record]).isEmpty, "metadata exclusion: " + key)
        }
        for flag in ["userUninstallable": false, "nonUserUninstallable": true] {
            let record = entry("manifest-" + flag.key)
            try install(record, manifestExtra: [flag.key: flag.value])
            check(try decode([record]).isEmpty, "manifest uninstall restriction")
        }
        let skill = entry("skills-only"); try install(skill, declaration: nil)
        check(try decode([skill]).isEmpty, "pure skill plugin excluded")
        let inline = entry("inline"); try install(inline, declaration: ["fixture": ["command": "node"]])
        check(try decode([inline]).isEmpty, "unverified inline manifest form excluded")
        let mismatch = entry("mismatch"); try install(mismatch, manifestExtra: ["name": "different"])
        check(try decode([mismatch]).isEmpty, "manifest identity mismatch excluded")
        for path in ["../.mcp.json", "/tmp/.mcp.json", "./a/../../.mcp.json", "a//b", "a\\b", "././.mcp.json", "${PLUGIN_ROOT}/.mcp.json"] {
            let record = entry("unsafe-path"); try install(record, declaration: path)
            check(try decode([record]).isEmpty, "unsafe declared path excluded")
        }
        for key in ["name", "marketplaceName", "version"] {
            var record = local; record[key] = "../outside"
            check(try decode([record]).isEmpty, "unsafe cache component excluded")
        }
        var forged = local; forged["pluginId"] = "different@openai-bundled"
        check(try decode([forged]).isEmpty, "forged registration ID excluded")

        let linked = entry("linked"), linkedRoot = try install(linked)
        let outside = temporary.appendingPathComponent("outside.json")
        try json(["mcpServers": ["fixture": ["command": "node"]]]).write(to: outside)
        try fm.removeItem(at: linkedRoot.appendingPathComponent(".mcp.json"))
        try fm.createSymbolicLink(at: linkedRoot.appendingPathComponent(".mcp.json"), withDestinationURL: outside)
        check(try decode([linked]).isEmpty, "MCP symlink cannot escape installed root")
        let linkedDir = entry("linked-directory"), linkedDirRoot = try install(linkedDir)
        let moved = temporary.appendingPathComponent("moved-plugin")
        try fm.moveItem(at: linkedDirRoot, to: moved); try fm.createSymbolicLink(at: linkedDirRoot, withDestinationURL: moved)
        check(try decode([linkedDir]).isEmpty, "directory symlink cannot redirect cache traversal")
        let fifo = entry("fifo"), fifoRoot = try install(fifo)
        try fm.removeItem(at: fifoRoot.appendingPathComponent(".mcp.json"))
        check(mkfifo(fifoRoot.appendingPathComponent(".mcp.json").path, 0o600) == 0, "FIFO fixture created")
        check(try decode([fifo]).isEmpty, "special file rejected without blocking")
        for servers in [[:], ["fixture": ["command": "node", "url": "https://fixture.invalid"]], ["fixture": ["url": "file:///tmp/mcp"]], ["fixture": ["args": []]]] as [[String: Any]] {
            let record = entry("bad-transport"); try install(record, servers: servers)
            check(try decode([record]).isEmpty, "unknown or ambiguous transport excluded")
        }
        rejects("malformed JSON rejected") { _ = try CodexPluginCatalog.decode(Data("bad".utf8), cacheRoot: cache) }
        rejects("oversize metadata rejected") { _ = try CodexPluginCatalog.decode(Data(repeating: 32, count: 1024 * 1024 + 1), cacheRoot: cache) }
        var wrongBoolean = local; wrongBoolean["enabled"] = 1
        rejects("numeric enabled does not become Boolean") { _ = try decode([wrongBoolean]) }

        let executable = URL(fileURLWithPath: args[0]).standardizedFileURL
        let captured = try CodexPluginCatalog.capture(executable: executable, arguments: ["--capture-fixture", "success"])
        check(try CodexPluginCatalog.decode(captured, cacheRoot: cache).isEmpty, "bounded subprocess success")
        rejects("nonzero subprocess fails closed") { _ = try CodexPluginCatalog.capture(executable: executable, arguments: ["--capture-fixture", "failure"]) }
        rejects("subprocess output capped at 1 MiB") { _ = try CodexPluginCatalog.capture(executable: executable, arguments: ["--capture-fixture", "large"]) }
        let start = ProcessInfo.processInfo.systemUptime
        rejects("hanging subprocess times out") { _ = try CodexPluginCatalog.capture(executable: executable, arguments: ["--capture-fixture", "timeout"], timeout: 0.1) }
        check(ProcessInfo.processInfo.systemUptime - start < 2, "timeout does not block waiting for child exit")
        print("\(checks)/\(checks) checks passed")
    }
}
