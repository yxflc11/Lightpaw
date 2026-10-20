import Foundation
import Darwin
import OSLog

struct CodexManagedPlugin {
    let id: String
    let title: String
    let enabled: Bool
    let remote: Bool
}

enum CodexPluginCatalog {
    static let cliPath = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    private static let log = Logger(subsystem: "local.codex.memorywatch", category: "Tools")
    private static let limit = 1024 * 1024
    private static let protectedIDs: Set<String> = [
        "codex-app-tools@openai-bundled", "unified-computer-use@openai-bundled", "code-review@openai-bundled"
    ]

    enum Failure: LocalizedError {
        case unavailable, invalidCatalog, timedOut, tooLarge
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Codex 插件目录暂时无法读取。"
            case .invalidCatalog: return "Codex 插件目录格式不在支持范围内。"
            case .timedOut: return "读取 Codex 插件目录超时，请稍后重试。"
            case .tooLarge: return "Codex 插件目录超过读取上限。"
            }
        }
    }

    private struct Catalog: Decodable { let installed: [Entry] }
    private struct Entry: Decodable, Equatable {
        // Equality covers every eligibility field below. The source path is
        // deliberately not decoded: it is not the installed cache location.
        struct Source: Decodable, Equatable { let source: String }
        let pluginId: String, name: String, marketplaceName: String, version: String
        let installed: Bool, enabled: Bool
        let source: Source
        let installPolicy: String
        let userUninstallable: Bool?
        let nonUserUninstallable: Bool?
    }
    private struct Manifest: Decodable {
        struct Interface: Decodable { let displayName: String? }
        let name: String
        let mcpServers: String?
        let interface: Interface?
        let userUninstallable: Bool?
        let nonUserUninstallable: Bool?
    }
    private struct MCP: Decodable {
        struct Server: Decodable { let command: String?; let url: String? }
        let mcpServers: [String: Server]
    }

    static func scan() throws -> [CodexManagedPlugin] {
        let metadata = try capture(executable: URL(fileURLWithPath: cliPath), arguments: ["plugin", "list", "--json"])
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/plugins/cache", isDirectory: true)
        let result = try decode(metadata, cacheRoot: cache)
        log.info("catalog result IDs=\(result.map(\.id).joined(separator: ","), privacy: .public)")
        return result
    }

    // Only the currently verified installed-cache format is supported. A cache
    // folder alone is never evidence of a registered, user-manageable plugin.
    static func decode(_ metadata: Data, cacheRoot: URL) throws -> [CodexManagedPlugin] {
        guard metadata.count <= limit else { throw Failure.tooLarge }
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: metadata) else { throw Failure.invalidCatalog }
        log.info("catalog installed count=\(catalog.installed.count)")
        if catalog.installed.isEmpty { return [] }
        guard cacheRoot.isFileURL, cacheRoot.path.hasPrefix("/") else { throw Failure.unavailable }
        let directory = open(cacheRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.unavailable }
        defer { close(directory) }
        let entriesByID = Dictionary(grouping: catalog.installed, by: \.pluginId)
        var seenIDs = Set<String>()
        var result: [CodexManagedPlugin] = []
        for entry in catalog.installed {
            guard identifier(entry.name), identifier(entry.marketplaceName),
                  entry.pluginId == entry.name + "@" + entry.marketplaceName else { continue }
            guard seenIDs.insert(entry.pluginId).inserted else { continue }
            guard entriesByID[entry.pluginId]?.allSatisfy({ $0 == entry }) == true else {
                excludedBasic(entry.pluginId, at: "duplicate-conflict"); continue
            }
            guard entry.installed else { excludedBasic(entry.pluginId, at: "not-installed"); continue }
            guard entry.installPolicy == "AVAILABLE", entry.userUninstallable != false, entry.nonUserUninstallable != true else {
                excludedBasic(entry.pluginId, at: "policy"); continue
            }
            guard entry.source.source == "local" else { excludedBasic(entry.pluginId, at: "source"); continue }
            guard !protectedIDs.contains(entry.pluginId.lowercased()) else {
                excludedBasic(entry.pluginId, at: "protected"); continue
            }
            guard segment(entry.version), entry.version.utf8.count <= 128 else {
                excludedBasic(entry.pluginId, at: "cache-version"); continue
            }
            let base = [entry.marketplaceName, entry.name, entry.version]
            guard let bytes = readFile(directory: directory, components: base + [".codex-plugin", "plugin.json"]) else {
                excluded(entry.pluginId, at: "manifest-read"); continue
            }
            guard let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes) else {
                excluded(entry.pluginId, at: "manifest-decode"); continue
            }
            guard manifest.name == entry.name, manifest.userUninstallable != false, manifest.nonUserUninstallable != true else {
                excluded(entry.pluginId, at: "manifest-identity-or-policy"); continue
            }
            guard let declaration = manifest.mcpServers else { continue } // Normal skill-only plugin.
            guard let components = relativePath(declaration) else {
                excluded(entry.pluginId, at: "mcp-declaration"); continue
            }
            guard let mcpBytes = readFile(directory: directory, components: base + components) else {
                excluded(entry.pluginId, at: "mcp-read"); continue
            }
            guard let mcp = try? JSONDecoder().decode(MCP.self, from: mcpBytes), !mcp.mcpServers.isEmpty else {
                excluded(entry.pluginId, at: "mcp-decode-or-empty"); continue
            }
            var local = false, valid = true
            for (id, server) in mcp.mcpServers {
                guard identifier(id) else { valid = false; break }
                if let command = server.command, !command.isEmpty, !command.contains("\0"), server.url == nil {
                    local = true
                } else if server.command == nil, let address = server.url, let url = URL(string: address),
                          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                    // Do not retain URLs, command arguments, or environment values.
                } else { valid = false; break }
            }
            guard valid else { excluded(entry.pluginId, at: "transport-guard"); continue }
            let title = manifest.interface?.displayName.flatMap { value in
                !value.isEmpty && value.count <= 100 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? value : nil
            } ?? entry.name
            result.append(CodexManagedPlugin(id: entry.pluginId, title: title, enabled: entry.enabled, remote: !local))
        }
        return result.sorted { $0.id < $1.id }
    }

    // Called only after the plugin ID has passed the identifier/identity checks.
    // Stages are constants; paths and MCP payloads must never be logged here.
    private static func excluded(_ pluginID: String, at stage: String) {
        log.info("catalog excluded plugin=\(pluginID, privacy: .public) stage=\(stage, privacy: .public)")
    }

    private static func excludedBasic(_ pluginID: String, at stage: String) {
        log.debug("catalog excluded plugin=\(pluginID, privacy: .public) stage=\(stage, privacy: .public)")
    }

    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private static func segment(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 255 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95, 46, 43].contains($0)
        }
    }
    private static func relativePath(_ value: String) -> [String]? {
        guard value.utf8.count <= 1024 else { return nil }
        let path = value.hasPrefix("./") ? String(value.dropFirst(2)) : value
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return !parts.isEmpty && parts.allSatisfy(segment) ? parts : nil
    }

    // Descriptor-relative traversal rejects links and special files, including
    // a manifest replaced between validation and reading. No manifest is run.
    private static func readFile(directory: Int32, components: [String]) -> Data? {
        guard let last = components.last else { return nil }
        var parent = dup(directory)
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return nil }
            close(parent); parent = next
        }
        let file = openat(parent, last, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= limit else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 { if errno == EINTR { continue }; return nil }
            guard data.count + count <= limit else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    // The only child is a short-lived CLI listing. On failure, cleanup targets
    // that child alone; existing Codex engines and MCP processes are untouched.
    static func capture(executable: URL, arguments: [String], timeout: TimeInterval = 8) throws -> Data {
        guard timeout.isFinite, timeout > 0 else { throw Failure.timedOut }
        let deadline = ProcessInfo.processInfo.systemUptime + min(timeout, 8)
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        defer {
            // Cleanup is limited to the transient CLI launched by this call.
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.unavailable }
        do { try process.run() } catch { throw Failure.unavailable }
        try? output.fileHandleForWriting.close()
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192), eof = false
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timedOut }
            if !eof {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= limit else { throw Failure.tooLarge }
                    data.append(contentsOf: buffer.prefix(count)); continue
                }
                if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw Failure.unavailable }
            }
            if eof && !process.isRunning {
                guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw Failure.unavailable }
                return data
            }
            Thread.sleep(forTimeInterval: min(0.01, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        }
    }
}
