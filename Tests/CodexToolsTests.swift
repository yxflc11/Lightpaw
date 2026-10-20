// Fixture-only: live configuration is never written and live processes are never
// signalled. --check-config is an explicit read-only parser compatibility check.
import Foundation
import Darwin

@main enum CodexToolsTests {
    static var failures = 0
    static let fm = FileManager.default
    static func check(_ good: Bool, _ name: String) { print("\(good ? "PASS" : "FAIL") \(name)"); if !good { failures += 1 } }
    static func rejects(_ name: String, _ body: () throws -> Void) { do { try body(); check(false, name) } catch { check(true, name) } }
    static func bytes(_ s: String) -> Data { Data(s.utf8) }
    static let header = "[mcp_servers.chatcut_desktop]"
    static let fixture = "# retained 你好\nmodel = \"codex\"\n\(header) # keep header\ncommand = \"/fixture/launcher\" # never opened\nargs = []\n[features]\nother = true\n"
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--check-config" {
            var runtime = CodexToolsRuntime(); runtime.list = { ([], 0, 0) }
            do { let snapshot = try CodexTools(runtime: runtime).snapshot(); print("CONFIG_PARSER_PASS enabled=\(snapshot.enabled)") }
            catch { print("CONFIG_PARSER_REFUSED \(error.localizedDescription)"); exit(1) }
            return
        }
        let inserted = fixture.replacingOccurrences(of: header + " # keep header\n", with: header + " # keep header\nenabled = false\n")
        check(try ChatCutConfigEditor.disable(bytes(fixture)) == bytes(inserted), "insert preserves every existing byte")
        let enabled = header + "\r\n  enabled  =  true # keep\r\ncommand = '/fixture/launcher'\r\n"
        check(try ChatCutConfigEditor.disable(bytes(enabled)) == bytes(enabled.replacingOccurrences(of: "=  true", with: "=  false")), "replace only boolean; preserve whitespace CRLF comments")
        let explicitlyDisabled = enabled.replacingOccurrences(of: "=  true", with: "=  false")
        check(try ChatCutConfigEditor.setEnabled(true, in: bytes(explicitlyDisabled)) == bytes(enabled), "enable false to true preserves comments whitespace and CRLF")
        check(try ChatCutConfigEditor.setEnabled(true, in: bytes(fixture)) == bytes(fixture), "enable default true is byte-identical without adding a key")
        check(try ChatCutConfigEditor.setEnabled(true, in: bytes(enabled)) == bytes(enabled), "enable explicit true is byte-identical")
        check(try ChatCutConfigEditor.setEnabled(false, in: ChatCutConfigEditor.setEnabled(true, in: bytes(explicitlyDisabled))) == bytes(explicitlyDisabled), "false to true to false round trip preserves all other bytes")
        check(try ChatCutConfigEditor.disable(bytes(inserted)) == bytes(inserted), "already disabled is byte-identical")
        check(try ChatCutConfigEditor.disable(bytes(header)) == bytes(header + "\nenabled = false"), "EOF table without newline")
        check(try ChatCutConfigEditor.disable(bytes(header + "\n")) == bytes(header + "\nenabled = false\n"), "EOF table with newline")
        let withEnv = header + "\ncommand='/fixture'\n[mcp_servers.chatcut_desktop.env]\nFIXTURE='kept'\n[[unrelated.rules]]\nname='one'\n[[unrelated.rules]]\nname='two'\n"
        check(try ChatCutConfigEditor.disable(bytes(withEnv)) == bytes(withEnv.replacingOccurrences(of: header + "\n", with: header + "\nenabled = false\n")), "simple env and unrelated array tables preserved")
        for (name, text) in [
            ("missing table", "model = 'codex'\n"),
            ("duplicate table", header + "\n" + header + "\n"),
            ("duplicate enabled", header + "\nenabled=true\nenabled=false\n"),
            ("quoted target", "[mcp_servers.\"chatcut_desktop\"]\nenabled=true\n"),
            ("array table", "[[mcp_servers.chatcut_desktop]]\nenabled=true\n"),
            ("unsupported nested target", header + "\n[mcp_servers.chatcut_desktop.other]\na='b'\n"),
            ("dotted target key", header + "\nenabled.x=true\n"),
            ("quoted enabled", header + "\n\"enabled\"=true\n"),
            ("invalid boolean", header + "\nenabled='false'\n"),
            ("multiline string", "instructions=\"\"\"\n" + header + "\n\"\"\"\n"),
            ("multiline array", "args=[\n'a'\n]\n" + header + "\n"),
            ("inline target shadow", "mcp_servers={chatcut_desktop={enabled=true}}\n" + header + "\n"),
            ("complex target", header + "\nenv={A='b'}\n"),
            ("broken key", "[foo\"bar\"]\nx=true\n" + header + "\n")
        ] { rejects(name) { _ = try ChatCutConfigEditor.disable(bytes(text)) } }

        let custom = "# preserve both custom servers\n[mcp_servers.notes_sync]\ncommand='/fixture/notes'\n[mcp_servers.remote-docs-2]\nenabled = true # selected boolean\nurl='https://fixture.invalid/mcp'\n" + fixture
        let customInserted = custom.replacingOccurrences(of: "[mcp_servers.notes_sync]\n", with: "[mcp_servers.notes_sync]\nenabled = false\n")
        let customReplaced = custom.replacingOccurrences(of: "enabled = true # selected boolean", with: "enabled = false # selected boolean")
        check(try ChatCutConfigEditor.disable(bytes(custom), serverID: "notes_sync") == bytes(customInserted), "custom ID insertion leaves other servers byte-identical")
        check(try ChatCutConfigEditor.disable(bytes(custom), serverID: "remote-docs-2") == bytes(customReplaced), "custom ID replacement leaves other servers byte-identical")
        check(try !ChatCutConfigEditor.isEnabled(bytes(customInserted), serverID: "notes_sync") && ChatCutConfigEditor.isEnabled(bytes(customInserted), serverID: "remote-docs-2"), "enabled lookup is scoped to selected server")
        for id in ["", "notes.sync", "../notes", "notes\n", "notes'", "笔记"] {
            rejects("unsafe server ID rejected") { _ = try ChatCutConfigEditor.disable(bytes(custom), serverID: id) }
        }
        for id in ["node_repl", "cua", "cua_repl", "artifact", "artifact_tool", "artifact_session", "codex_app_tools", "code_review", "CUA", "codex-app-tools"] {
            let protected = bytes("[mcp_servers.\(id)]\nenabled = false\ncommand = '/fixture/core'\n")
            check(ChatCutConfigEditor.isProtected(serverID: id), "UI uses shared protected MCP decision: " + id)
            rejects("protected ID cannot be enabled through editor: " + id) { _ = try ChatCutConfigEditor.setEnabled(true, in: protected, serverID: id) }
            rejects("protected ID cannot be disabled even as a no-op: " + id) { _ = try ChatCutConfigEditor.disable(protected, serverID: id) }
        }
        let catalog = custom + "\n[mcp_servers.node_repl]\ncommand='builtin'\n[mcp_servers.cua]\ncommand='builtin'\n[mcp_servers.codex-app-tools]\ncommand='builtin'\n[mcp_servers.artifact_tool]\ncommand='builtin'\n[mcp_servers.\"quoted-custom\"]\ncommand='unsupported'\n[mcp_servers.notes_sync.env]\nKEY='kept'\n"
        check(try ChatCutConfigEditor.configuredServerIDs(bytes(catalog)) == ["chatcut_desktop", "notes_sync", "remote-docs-2"], "catalog includes only canonical custom top-level IDs")
        rejects("catalog cannot mistake a multiline string for headers") { _ = try ChatCutConfigEditor.configuredServerIDs(bytes("value=\"\"\"\n[mcp_servers.fake]\n\"\"\"")) }

        let pluginID = "record-and-replay@openai-bundled", otherPluginID = "github@openai-curated"
        let pluginHeader = "[plugins.\"\(pluginID)\"]", otherPluginHeader = "[plugins.\"\(otherPluginID)\"]"
        let plugins = custom + "\n" + pluginHeader + " # selected plugin\n  enabled = true # preserve plugin comment\n" + otherPluginHeader + "\nenabled = false # other plugin\n"
        let pluginDisabled = plugins.replacingOccurrences(of: "enabled = true # preserve plugin comment", with: "enabled = false # preserve plugin comment")
        check(try ChatCutConfigEditor.setEnabled(false, in: bytes(plugins), pluginID: pluginID) == bytes(pluginDisabled), "plugin disable only changes its own boolean")
        check(try ChatCutConfigEditor.setEnabled(true, in: bytes(pluginDisabled), pluginID: pluginID) == bytes(plugins), "plugin re-enable round trip preserves every other byte")
        check(try !ChatCutConfigEditor.isEnabled(bytes(pluginDisabled), pluginID: pluginID) && !ChatCutConfigEditor.isEnabled(bytes(pluginDisabled), pluginID: otherPluginID), "plugin enabled lookup is scoped to selected exact ID")
        let pluginCRLF = pluginHeader + "\r\n\tenabled  =  false # kept\r\n"
        check(try ChatCutConfigEditor.setEnabled(true, in: bytes(pluginCRLF), pluginID: pluginID) == bytes(pluginCRLF.replacingOccurrences(of: "=  false", with: "=  true")), "plugin toggle preserves CRLF whitespace and comments")
        check(try ChatCutConfigEditor.setEnabled(true, in: bytes(pluginHeader), pluginID: pluginID) == bytes(pluginHeader), "plugin table without enabled defaults true and enable is no-op")
        check(try ChatCutConfigEditor.setEnabled(false, in: bytes(pluginHeader), pluginID: pluginID) == bytes(pluginHeader + "\nenabled = false"), "plugin enabled insertion preserves EOF without newline")
        check(try ChatCutConfigEditor.isEnabled(bytes(custom), pluginID: pluginID), "missing plugin configuration defaults enabled")
        check(try ChatCutConfigEditor.setEnabled(true, in: bytes(custom), pluginID: pluginID) == bytes(custom), "missing default-enabled plugin enable is byte-identical")
        check(try ChatCutConfigEditor.setEnabled(false, in: bytes(custom), pluginID: pluginID) == bytes(custom + "\n" + pluginHeader + "\nenabled = false\n"), "missing plugin table safely appended preserving existing prefix")
        check(try ChatCutConfigEditor.setEnabled(false, in: bytes("model='fixture'"), pluginID: pluginID) == bytes("model='fixture'\n\n" + pluginHeader + "\nenabled = false\n"), "missing plugin append handles EOF without newline")
        check(try ChatCutConfigEditor.setEnabled(false, in: Data(), pluginID: pluginID) == bytes(pluginHeader + "\nenabled = false\n"), "missing plugin append handles empty configuration")
        for id in ["", "no-market", "a@", "@market", "a@b@c", "a.b@market", "../a@market", "a@b\n", "a\"@b", "插件@market"] {
            rejects("unsafe plugin ID rejected") { _ = try ChatCutConfigEditor.setEnabled(false, in: bytes(custom), pluginID: id) }
        }
        for (name, text) in [
            ("plugin duplicate table", pluginHeader + "\n" + pluginHeader + "\n"),
            ("plugin duplicate enabled", pluginHeader + "\nenabled=true\nenabled=false\n"),
            ("plugin noncanonical quotes", "[plugins.'\(pluginID)']\nenabled=true\n"),
            ("plugin quoted root alias", "[\"plugins\".\"\(pluginID)\"]\nenabled=true\n"),
            ("plugin array table", "[[plugins.\"\(pluginID)\"]]\nenabled=true\n"),
            ("plugin nested table", pluginHeader + "\n[plugins.\"\(pluginID)\".env]\nA='b'\n"),
            ("plugin dotted enabled", pluginHeader + "\nenabled.x=true\n"),
            ("plugin inline root shadow", "plugins={other={enabled=true}}\n"),
            ("plugin inline target shadow", "[plugins]\n\"\(pluginID)\"={enabled=true}\n"),
            ("plugin dotted target assignment", "plugins.\"\(pluginID)\".enabled=true\n"),
            ("plugin multiline ambiguity", "value=\"\"\"\n" + pluginHeader + "\n\"\"\"\n")
        ] { rejects(name) { _ = try ChatCutConfigEditor.setEnabled(false, in: bytes(text), pluginID: pluginID) } }
        let protectedPluginIDs = ["codex-app-tools@openai-bundled", "unified-computer-use@openai-bundled", "code-review@openai-bundled"]
        for id in protectedPluginIDs {
            let protected = bytes("[plugins.\"\(id)\"]\nenabled=false\n")
            check(ChatCutConfigEditor.isProtectedPlugin(id), "UI uses shared protected plugin decision: " + id)
            rejects("protected plugin cannot enable: " + id) { _ = try ChatCutConfigEditor.setEnabled(true, in: protected, pluginID: id) }
            rejects("protected plugin cannot disable even as no-op: " + id) { _ = try ChatCutConfigEditor.setEnabled(false, in: protected, pluginID: id) }
            rejects("protected missing plugin cannot be inserted: " + id) { _ = try ChatCutConfigEditor.setEnabled(false, in: bytes(custom), pluginID: id) }
        }
        check(!ChatCutConfigEditor.isProtected(serverID: "notes_sync") && !ChatCutConfigEditor.isProtectedPlugin(pluginID), "shared protected decisions allow ordinary integrations")

        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("lightpaw-codex-tools-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let config = root.appendingPathComponent("config.toml")
        try bytes(fixture).write(to: config); chmod(config.path, 0o640)
        let codex = Proc(id: Identity(pid: 900001, seconds: 1, micros: 10), parent: 1, name: "Codex", path: "/fixture/Codex")
        let tool = Proc(id: Identity(pid: 900002, seconds: 2, micros: 20), parent: codex.id.pid, name: "ChatCut", path: CodexTools.chatcutExecutable)
        let gui = Proc(id: Identity(pid: 900003, seconds: 3, micros: 30), parent: 1, name: "ChatCut", path: CodexTools.chatcutExecutable)
        var inventory = [codex, tool, gui], sent: [Identity] = [], signalError: Int32 = 0, afterSignal: Int32 = ESRCH, identityError: Int32 = 0
        var valid = true, recognized = true, knownBytes: UInt64? = 12_345
        var runtime = CodexToolsRuntime()
        runtime.list = { (inventory, 0, 0) }; runtime.targets = { [codex.path] }
        runtime.validate = { _ in valid }; runtime.kind = { $0.id == tool.id && recognized ? .chatcutMCP : nil }
        runtime.footprint = { _ in knownBytes }
        runtime.identityStatus = { id in sent.contains(id) ? afterSignal : identityError }
        runtime.terminate = { p in sent.append(p.id); return signalError }; runtime.sleep = { _ in }
        let service = CodexTools(configURL: config, runtime: runtime)
        let snapshot = try service.snapshot()
        check(snapshot.enabled && snapshot.processes.map(\.identity) == [tool.id] && snapshot.unverifiedPIDs.isEmpty, "exact confirmed Codex tool only; GUI excluded")
        check(snapshot.totalFootprintBytes == knownBytes, "confirmed memory total")
        knownBytes = nil
        check(try service.snapshot().totalFootprintBytes == nil, "unread memory remains unknown")
        knownBytes = 12_345
        let backup = try service.disable(snapshot)
        check(sent.isEmpty, "ChatCut disable changes configuration without any automatic stop")
        check(try Data(contentsOf: config) == bytes(inserted), "real fixture atomic edit preserves other bytes")
        check(try backup.map { try Data(contentsOf: $0) } == bytes(fixture), "private backup retains original bytes")
        let mode = (try fm.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber)?.intValue
        let backupMode = try backup.map { (try fm.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber)?.intValue }
        check(mode == 0o640 && backupMode == 0o600, "original permissions preserved; backup private")
        check(try service.stop(snapshot, waitSeconds: 0).first?.state == .exited && sent == [tool.id], "reviewed old snapshot can stop after its exact disable edit")
        sent = []
        let disabled = try service.snapshot()
        check(try service.disable(disabled) == nil, "disabled snapshot does not create another backup")
        check(try service.stop(disabled, waitSeconds: 0).first?.state == .exited && sent == [tool.id], "already disabled snapshot can stop")
        sent = []; inventory = [codex, Proc(id: Identity(pid: tool.id.pid, seconds: 99, micros: 20), parent: codex.id.pid, name: tool.name, path: tool.path)]
        check(try service.stop(disabled, waitSeconds: 0).first?.state == .refused && sent.isEmpty, "PID reuse refuses signal")
        check(!CodexTools.matchesReviewed(tool.id, current: inventory[1]), "pure identity matching rejects PID reuse")
        inventory = [codex, tool, gui]; recognized = false
        check(try service.stop(disabled, waitSeconds: 0).first?.state == .refused && sent.isEmpty, "argv mismatch refuses signal")
        recognized = true; valid = false
        check(try service.stop(disabled, waitSeconds: 0).first?.state == .refused && sent.isEmpty, "changed ancestor refuses signal")
        valid = true; inventory = [tool, gui]
        check(try service.stop(disabled, waitSeconds: 0).first?.state == .refused && sent.isEmpty, "missing Codex ancestor refuses signal")
        inventory = [codex, tool, gui]; afterSignal = 0
        check(try service.stop(disabled, waitSeconds: 0).first?.state == .stillRunning && sent == [tool.id], "SIGTERM-only reports still running")
        sent = []; signalError = EPERM
        check(try service.stop(disabled, waitSeconds: 0).first?.state == .failed, "failed signal reported")
        sent = []; signalError = 0; identityError = EACCES
        check(try service.stop(disabled, waitSeconds: 0).first?.state == .refused && sent.isEmpty, "unknown identity is not considered exited")
        identityError = ESRCH
        check(try service.stop(disabled, waitSeconds: 0).first?.state == .exited && sent.isEmpty, "already exited sends no signal")
        identityError = 0
        try bytes(inserted + "# changed\n").write(to: config)
        rejects("changed config refuses stop") { _ = try service.stop(disabled, waitSeconds: 0) }
        rejects("changed config refuses edit") { _ = try service.disable(disabled) }
        check(sent.isEmpty, "changed config never signals")
        try fm.removeItem(at: config)
        let target = root.appendingPathComponent("original.toml"); try bytes(fixture).write(to: target)
        try fm.createSymbolicLink(at: config, withDestinationURL: target)
        rejects("config symlink refused") { _ = try service.snapshot() }
        try fm.removeItem(at: config)
        try fm.linkItem(at: target, to: config)
        rejects("config hardlink refused") { _ = try service.snapshot() }
        try fm.removeItem(at: config)
        try bytes(fixture).write(to: config)
        let linkedParent = root.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linkedParent, withDestinationURL: root)
        rejects("parent symlink refused") { _ = try CodexTools(configURL: linkedParent.appendingPathComponent("config.toml"), runtime: runtime).snapshot() }

        let customDirectory = root.appendingPathComponent("custom")
        try fm.createDirectory(at: customDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let customConfig = customDirectory.appendingPathComponent("config.toml")
        try bytes(custom).write(to: customConfig)
        var customProcessCalls = 0, customSignals = 0
        var customRuntime = runtime
        customRuntime.list = { customProcessCalls += 1; return (inventory, 0, 0) }
        customRuntime.identityStatus = { _ in customProcessCalls += 1; return 0 }
        customRuntime.terminate = { _ in customSignals += 1; return 0 }
        let notes = CodexTools(configURL: customConfig, serverID: "notes_sync", runtime: customRuntime)
        let docs = CodexTools(configURL: customConfig, serverID: "remote-docs-2", runtime: customRuntime)
        let notesSnapshot = try notes.snapshot(), docsSnapshot = try docs.snapshot()
        let expectedNotesDisabledFingerprint = try notesSnapshot.fingerprintAfterSetting(false)
        check(try notesSnapshot.fingerprintAfterSetting(true) == notesSnapshot.configurationFingerprint, "MCP expected no-op fingerprint equals original bytes")
        check(notesSnapshot.configurationFingerprint == docsSnapshot.configurationFingerprint && notesSnapshot.configurationFingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              "snapshot exposes only a stable SHA256 configuration fingerprint")
        check(notesSnapshot.serverID == "notes_sync" && !notesSnapshot.processInspectionSupported && notesSnapshot.processes.isEmpty && notesSnapshot.totalFootprintBytes == nil,
              "custom snapshot declares unsupported process inspection and unknown memory")
        check(customProcessCalls == 0, "custom snapshot never inspects processes")
        check(try notes.configuredServerIDs() == ["chatcut_desktop", "notes_sync", "remote-docs-2"], "service enumerates custom IDs from secure configuration read")
        let beforeNoOp = try fm.contentsOfDirectory(atPath: customDirectory.path)
        check(try notes.setEnabled(true, notesSnapshot) == nil && Data(contentsOf: customConfig) == bytes(custom), "service default true enable performs no write")
        check(try fm.contentsOfDirectory(atPath: customDirectory.path) == beforeNoOp, "no-op enable creates no backup or temporary file")
        rejects("cross-server snapshot cannot edit configuration") { _ = try notes.disable(docsSnapshot) }
        rejects("cross-server snapshot cannot enable configuration") { _ = try notes.setEnabled(true, docsSnapshot) }
        rejects("custom service cannot stop its snapshot") { _ = try notes.stop(notesSnapshot, waitSeconds: 0) }
        rejects("custom service cannot stop a ChatCut snapshot") { _ = try notes.stop(snapshot, waitSeconds: 0) }
        rejects("ChatCut service cannot stop a custom snapshot") { _ = try service.stop(notesSnapshot, waitSeconds: 0) }
        check(customProcessCalls == 0 && customSignals == 0 && sent.isEmpty, "non-ChatCut stop never invokes process runtime or signals")
        let customBackup = try notes.disable(notesSnapshot)
        check(try customBackup != nil && Data(contentsOf: customConfig) == bytes(customInserted), "custom service safely inserts only its own enabled key")
        check(try notes.snapshot().configurationFingerprint == expectedNotesDisabledFingerprint, "MCP predicted fingerprint matches exact committed bytes")
        check(try notesSnapshot.fingerprintAfterSetting(false) == expectedNotesDisabledFingerprint, "MCP predicted fingerprint remains based only on reviewed bytes")
        rejects("other server snapshot becomes stale after edit") { _ = try docs.disable(docsSnapshot) }
        let freshDocs = try docs.snapshot()
        _ = try docs.disable(freshDocs)
        check(try Data(contentsOf: customConfig) == bytes(customInserted.replacingOccurrences(of: "enabled = true # selected boolean", with: "enabled = false # selected boolean")), "second custom edit preserves first edit and ChatCut section")
        check(customProcessCalls == 0 && customSignals == 0, "custom edits do not acquire process-control capability")

        let bothDisabled = try Data(contentsOf: customConfig)
        let freshNotes = try notes.snapshot()
        check(freshNotes.configurationFingerprint != notesSnapshot.configurationFingerprint, "configuration fingerprint changes when source bytes change")
        let enableBackup = try notes.setEnabled(true, freshNotes)
        let notesEnabled = String(decoding: bothDisabled, as: UTF8.self).replacingOccurrences(of: "[mcp_servers.notes_sync]\nenabled = false", with: "[mcp_servers.notes_sync]\nenabled = true")
        check(try enableBackup != nil && Data(contentsOf: customConfig) == bytes(notesEnabled), "service re-enable changes only selected server boolean")
        check(try enableBackup.map { try Data(contentsOf: $0) } == bothDisabled, "re-enable creates private backup of prior bytes")
        rejects("stale pre-enable snapshot cannot disable again") { _ = try notes.setEnabled(false, freshNotes) }
        _ = try notes.setEnabled(false, notes.snapshot())
        check(try Data(contentsOf: customConfig) == bothDisabled, "service enable-disable round trip preserves other servers")
        check(customProcessCalls == 0 && customSignals == 0, "enable and disable never inspect or stop custom processes")

        let pluginDirectory = root.appendingPathComponent("plugins")
        try fm.createDirectory(at: pluginDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pluginConfig = pluginDirectory.appendingPathComponent("config.toml")
        try bytes(plugins).write(to: pluginConfig); chmod(pluginConfig.path, 0o640)
        let recorder = CodexTools(configURL: pluginConfig, pluginID: pluginID, runtime: customRuntime)
        let github = CodexTools(configURL: pluginConfig, pluginID: otherPluginID, runtime: customRuntime)
        let pluginNotes = CodexTools(configURL: pluginConfig, serverID: "notes_sync", runtime: customRuntime)
        let recorderSnapshot = try recorder.snapshot(), githubSnapshot = try github.snapshot(), pluginNotesSnapshot = try pluginNotes.snapshot()
        let expectedPluginDisabledFingerprint = try recorderSnapshot.fingerprintAfterSetting(false)
        check(try recorderSnapshot.fingerprintAfterSetting(true) == recorderSnapshot.configurationFingerprint, "plugin expected no-op fingerprint equals original bytes")
        check(recorderSnapshot.pluginID == pluginID && recorderSnapshot.targetKey == "plugin:" + pluginID && recorder.targetKey == recorderSnapshot.targetKey,
              "plugin snapshot exposes exact plugin ID and target key")
        check(pluginNotesSnapshot.pluginID == nil && pluginNotesSnapshot.targetKey == "mcp:notes_sync", "MCP and plugin target namespaces remain distinct")
        check(recorderSnapshot.enabled && !recorderSnapshot.processInspectionSupported && recorderSnapshot.processes.isEmpty && recorderSnapshot.totalFootprintBytes == nil,
              "plugin snapshot does not inspect processes or report unknown memory as zero")
        check(recorderSnapshot.configurationFingerprint == pluginNotesSnapshot.configurationFingerprint, "plugin and MCP snapshots fingerprint the same source bytes")
        rejects("one plugin cannot use another plugin reviewed snapshot") { _ = try recorder.setEnabled(false, githubSnapshot) }
        rejects("plugin cannot use MCP reviewed snapshot") { _ = try recorder.setEnabled(false, pluginNotesSnapshot) }
        rejects("MCP cannot use plugin reviewed snapshot") { _ = try pluginNotes.setEnabled(false, recorderSnapshot) }
        rejects("plugin stop rejects its own reviewed snapshot") { _ = try recorder.stop(recorderSnapshot, waitSeconds: 0) }
        rejects("plugin stop rejects a ChatCut reviewed snapshot") { _ = try recorder.stop(snapshot, waitSeconds: 0) }
        rejects("ChatCut stop rejects a plugin reviewed snapshot") { _ = try service.stop(recorderSnapshot, waitSeconds: 0) }
        let pluginBackup = try recorder.setEnabled(false, recorderSnapshot)
        check(try pluginBackup != nil && Data(contentsOf: pluginConfig) == bytes(pluginDisabled), "plugin service atomic write changes only selected enabled boolean")
        check(try recorder.snapshot().configurationFingerprint == expectedPluginDisabledFingerprint, "plugin predicted fingerprint matches exact committed bytes")
        check(try pluginBackup.map { try Data(contentsOf: $0) } == bytes(plugins), "plugin service shares exact prior-bytes backup")
        let pluginMode = (try fm.attributesOfItem(atPath: pluginConfig.path)[.posixPermissions] as? NSNumber)?.intValue
        let pluginBackupMode = try pluginBackup.map { (try fm.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber)?.intValue }
        check(pluginMode == 0o640 && pluginBackupMode == 0o600, "plugin service preserves source permissions and private backup")
        rejects("plugin edit invalidates another plugin stale snapshot") { _ = try github.setEnabled(true, githubSnapshot) }
        _ = try recorder.setEnabled(true, recorder.snapshot())
        check(try Data(contentsOf: pluginConfig) == bytes(plugins), "plugin service disable-enable round trip preserves all other sections")
        let beforePluginNoOp = try fm.contentsOfDirectory(atPath: pluginDirectory.path)
        check(try recorder.setEnabled(true, recorder.snapshot()) == nil && fm.contentsOfDirectory(atPath: pluginDirectory.path) == beforePluginNoOp,
              "already enabled plugin does not create files")
        let absentPlugin = CodexTools(configURL: pluginConfig, pluginID: "fixture-extra@fixture-market", runtime: customRuntime)
        let absentSnapshot = try absentPlugin.snapshot()
        let expectedAppendedFingerprint = try absentSnapshot.fingerprintAfterSetting(false)
        check(try absentSnapshot.enabled && absentPlugin.setEnabled(true, absentSnapshot) == nil, "missing plugin service enable is a default-true no-op")
        _ = try absentPlugin.setEnabled(false, absentSnapshot)
        let appendedPlugin = plugins + "\n[plugins.\"fixture-extra@fixture-market\"]\nenabled = false\n"
        check(try Data(contentsOf: pluginConfig) == bytes(appendedPlugin), "plugin service safely appends only missing exact table")
        check(try absentPlugin.snapshot().configurationFingerprint == expectedAppendedFingerprint, "missing plugin predicted fingerprint matches appended bytes")
        _ = try absentPlugin.setEnabled(true, absentPlugin.snapshot())
        check(try Data(contentsOf: pluginConfig) == bytes(appendedPlugin.replacingOccurrences(of: "[plugins.\"fixture-extra@fixture-market\"]\nenabled = false", with: "[plugins.\"fixture-extra@fixture-market\"]\nenabled = true")),
              "new plugin table can subsequently be re-enabled")
        check(customProcessCalls == 0 && customSignals == 0 && sent.isEmpty, "plugin snapshot edits and rejected stops never invoke process runtime")

        let protectedDirectory = root.appendingPathComponent("protected")
        try fm.createDirectory(at: protectedDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let protectedConfig = protectedDirectory.appendingPathComponent("config.toml")
        for id in ["node_repl", "cua", "artifact_tool", "codex-app-tools"] {
            let original = bytes("[mcp_servers.\(id)]\nenabled=false # preserve\ncommand='/fixture/core'\n")
            try original.write(to: protectedConfig)
            let protectedService = CodexTools(configURL: protectedConfig, serverID: id, runtime: customRuntime)
            let reviewed = try protectedService.snapshot()
            rejects("protected MCP cannot predict an unauthorized edit: " + id) { _ = try reviewed.fingerprintAfterSetting(true) }
            rejects("direct service cannot enable protected ID: " + id) { _ = try protectedService.setEnabled(true, reviewed) }
            rejects("direct service cannot disable protected ID: " + id) { _ = try protectedService.setEnabled(false, reviewed) }
            check(try Data(contentsOf: protectedConfig) == original && fm.contentsOfDirectory(atPath: protectedDirectory.path) == ["config.toml"], "protected service leaves bytes and directory untouched: " + id)
        }
        for id in protectedPluginIDs {
            let original = bytes("[plugins.\"\(id)\"]\nenabled=false # preserve\n")
            try original.write(to: protectedConfig)
            let protectedService = CodexTools(configURL: protectedConfig, pluginID: id, runtime: customRuntime)
            let reviewed = try protectedService.snapshot()
            rejects("protected plugin cannot predict an unauthorized edit: " + id) { _ = try reviewed.fingerprintAfterSetting(true) }
            rejects("direct service cannot enable protected plugin: " + id) { _ = try protectedService.setEnabled(true, reviewed) }
            rejects("direct service cannot disable protected plugin: " + id) { _ = try protectedService.setEnabled(false, reviewed) }
            check(try Data(contentsOf: protectedConfig) == original && fm.contentsOfDirectory(atPath: protectedDirectory.path) == ["config.toml"], "protected plugin service leaves bytes and directory untouched: " + id)
        }
        check(customProcessCalls == 0 && customSignals == 0, "protected setters never invoke process runtime")

        let commitDirectory = root.appendingPathComponent("commit-hook")
        try fm.createDirectory(at: commitDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let commitConfig = commitDirectory.appendingPathComponent("config.toml")
        try bytes(custom).write(to: commitConfig)
        let commitService = CodexTools(configURL: commitConfig, serverID: "notes_sync", runtime: customRuntime)
        let commitSnapshot = try commitService.snapshot()
        var hookCalls = 0
        check(try commitService.setEnabled(true, commitSnapshot, beforeCommit: { hookCalls += 1 }) == nil && hookCalls == 0, "no-op edit does not call commit hook")
        rejects("commit hook can cancel before atomic replacement") {
            _ = try commitService.setEnabled(false, commitSnapshot, beforeCommit: { hookCalls += 1; throw CodexToolsError.configurationChanged })
        }
        check(try hookCalls == 1 && Data(contentsOf: commitConfig) == bytes(custom), "cancelled commit hook leaves source bytes untouched")
        check(try !fm.contentsOfDirectory(atPath: commitDirectory.path).contains(where: { $0.hasPrefix(".mcp-config-") }), "cancelled commit removes temporary file")
        let externallyChanged = custom + "# external fixture edit\n"
        rejects("external edit during commit hook is caught by final identity and bytes recheck") {
            _ = try commitService.setEnabled(false, commitSnapshot, beforeCommit: { try bytes(externallyChanged).write(to: commitConfig) })
        }
        check(try Data(contentsOf: commitConfig) == bytes(externallyChanged), "commit hook cannot cause concurrent external edit to be overwritten")
        let reviewedCommit = try commitService.snapshot()
        let expectedCommitFingerprint = try reviewedCommit.fingerprintAfterSetting(false)
        _ = try commitService.setEnabled(false, reviewedCommit, beforeCommit: { hookCalls += 1 })
        check(try hookCalls == 2 && commitService.snapshot().configurationFingerprint == expectedCommitFingerprint, "approved commit hook runs once before exact expected write")
        check(customProcessCalls == 0 && customSignals == 0, "commit hook support does not couple configuration changes to processes")
        let live = listProcesses()
        if let me = live.items.first(where: { $0.id.pid == getpid() }) {
            let script = CodexTools.scriptPath(me)
            check(script == CommandLine.arguments.dropFirst().first, "C transport returns only fixture argv[1]")
            check(CodexTools.scriptPath(me, argumentIndex: 2) == CommandLine.arguments.dropFirst(2).first, "C transport supports explicit fixture argv[2]")
            check(CodexTools.scriptPath(me, argumentIndex: 0) == nil && CodexTools.scriptPath(me, argumentIndex: 3) == nil, "C transport rejects other argument slots")
            check(CodexTools.workingDirectory(me) == fm.currentDirectoryPath, "C transport reads fixture working directory")
            let reused = Proc(id: Identity(pid: me.id.pid, seconds: me.id.seconds + 1, micros: me.id.micros), parent: me.parent, name: me.name, path: me.path)
            check(CodexTools.scriptPath(reused) == nil, "C transport rejects birthtime mismatch")
            check(CodexTools.workingDirectory(reused) == nil, "cwd transport rejects birthtime mismatch")
            var kind: Int32 = 0
            check(cwm_tool_kind(me.id.pid, me.id.seconds, me.id.micros, me.parent, &kind) != 0 && kind == 0, "fixture executable is not ChatCut")
        } else { check(false, "fixture process identity available") }
        print("Codex tools fixtures: \(failures == 0 ? "PASS" : "FAIL"), failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
