import Foundation
import AppKit
import CryptoKit
import Darwin

struct CleanupCandidate: Identifiable {
    let id: Int
    let path: String
    let section: String
    let detail: String
}

enum CleanupStatus: String { case trashed, removed, skipped, failed, cancelled }

struct CleanupResult: Identifiable {
    let id: Int
    let path: String
    let status: CleanupStatus
    let message: String
    let bytes: UInt64?
}

struct CleanupPlanItem: Identifiable {
    let candidate: CleanupCandidate
    var id: Int { candidate.id }
    var path: String { candidate.path }
    let bytes: UInt64?
    fileprivate let parent: CleanupNode
    fileprivate let tree: [String: CleanupNode]
}

struct CleanupPlan {
    let items: [CleanupPlanItem]
    let skipped: [CleanupResult]
    let totalBytes: UInt64?
    fileprivate let owner: UUID
    fileprivate let created: Date
    fileprivate let rulesHash: String
}

fileprivate struct CleanupNode: Equatable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let uid: UInt32
    let size: Int64
    let seconds: Int
    let nanos: Int
    var directory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; mode = s.st_mode; uid = s.st_uid
        size = s.st_size; seconds = s.st_mtimespec.tv_sec; nanos = s.st_mtimespec.tv_nsec
    }
    func sameObject(_ other: CleanupNode) -> Bool {
        device == other.device && inode == other.inode && mode == other.mode && uid == other.uid
    }
}

private struct CleanupError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
    init(_ text: String) { self.text = text }
}

/// Independent, narrow cleanup engine. Mole is only the source of candidate paths.
/// prepare is synchronous and must be called off the main queue. execute runs on
/// its own serial queue; both callbacks are always delivered on the main queue.
/// Bytes are logical item bytes, never a claim about physical disk space freed.
final class SelectedCleanup {
    private let home: String
    private let owner = UUID()
    private let ttl: TimeInterval
    private let queue = DispatchQueue(label: "MacCare.SelectedCleanup", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var cancelled = false
    // Test seam: production always uses process and open-handle probes below.
    private let activityCheck: ((String, Bool) -> String?)?
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    init(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
         planTTL: TimeInterval = 300, activityCheck: ((String, Bool) -> String?)? = nil) {
        // Do not canonicalize /private/tmp into its /tmp symlink alias in fixtures;
        // every ancestor must remain explicit for the no-follow walk.
        self.home = home.hasSuffix("/") ? String(home.dropLast()) : home
        self.ttl = planTTL
        self.activityCheck = activityCheck
    }

    /// Fast, lexical-only eligibility for rendering checkboxes. This is not authorization.
    func restriction(path: String) -> String? {
        guard path.hasPrefix(home + "/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.contains("//"), !path.hasSuffix("/"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return "仅支持当前用户目录内、格式明确的绝对路径"
        }
        let relative = String(path.dropFirst(home.count + 1))
        let lower = relative.lowercased()
        // These cache-shaped paths may hold durable state or service-critical data.
        let protected = ["codex", "mac care", "mac-care", "codexmemorywatch", "mole", "orbstack",
            "adobe", "crowdstrike", "sentinel", "falcon", "displaylink", "silverfast", "cotypist",
            "com.apple.", "cloudkit", "familycircle", "gippseudonymousid", "cctclearcutlogger",
            "ms-playwright", "pypoetry", "virtualenv", "org.r-project", "jetbrains", "nssurge", "tealdeer/tldr-pages",
            "coreaudio", "keychain", "license", "auth", "huggingface", "ollama", "models"]
        if protected.contains(where: { lower.contains($0) }) { return "此项包含应用状态、系统服务或维护台保护数据" }
        if relative.hasPrefix("Library/Caches/") || relative.hasPrefix("Library/Logs/") { return nil }
        for root in [".npm/_cacache", ".npm/_npx", ".npm/_logs",
                     ".cache/uv", ".cache/pip", ".cache/pip-tools", ".cache/yarn", ".cache/npm",
                     ".cache/node-gyp", ".cache/go-build", ".cache/ruff", ".cache/mypy", ".cache/typescript"] {
            if relative == root || relative.hasPrefix(root + "/") { return nil }
        }
        // Keep Chromium profiles and cache leaf directories; allow their children only.
        if relative.hasPrefix("Library/Application Support/") {
            let parts = relative.split(separator: "/").map(String.init)
            if parts.count >= 5 {
                let leaves = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"]
                if leaves.contains(parts[3]) { return nil }
            }
        }
        return "当前逐项清理仅支持明确缓存与日志；此项保留"
    }

    func prepare(candidates: [CleanupCandidate], selectedIDs: Set<Int>) throws -> CleanupPlan {
        guard !isRunning else { throw CleanupError("已有清理正在进行") }
        lock.lock(); cancelled = false; lock.unlock()
        guard Set(candidates.map(\.id)).count == candidates.count,
              selectedIDs.isSubset(of: Set(candidates.map(\.id))) else { throw CleanupError("候选 ID 无效，请重新预览") }
        let rules = try readRules()
        var items: [CleanupPlanItem] = []; var skipped: [CleanupResult] = []
        let selected = candidates.filter { selectedIDs.contains($0.id) }.sorted {
            $0.path.count == $1.path.count ? $0.id < $1.id : $0.path.count < $1.path.count
        }
        for candidate in selected {
            do {
                try checkCancellation()
                if let why = restriction(path: candidate.path) { throw CleanupError(why) }
                if candidates.contains(where: { !selectedIDs.contains($0.id) && $0.path.hasPrefix(candidate.path + "/") }) {
                    throw CleanupError("目录内有未勾选子项，已保留整个目录")
                }
                if items.contains(where: { candidate.path == $0.path || candidate.path.hasPrefix($0.path + "/") }) { continue }
                try checkRules(candidate.path, rules.patterns)
                let parentFD = try openParent(candidate.path); defer { close(parentFD) }
                let parent = try node(fd: parentFD)
                let tree = try snapshot(parentFD: parentFD, name: leaf(candidate.path), basePath: candidate.path, rules: rules.patterns)
                guard let root = tree[""] else { throw CleanupError("目标不存在") }
                if let why = activity(candidate.path, root.directory) { throw CleanupError(why) }
                // A process/handle probe can take seconds. Rebind after it, too.
                guard tree == (try snapshot(parentFD: parentFD, name: leaf(candidate.path), basePath: candidate.path, rules: rules.patterns)) else {
                    throw CleanupError("扫描期间内容发生变化，请重新预览")
                }
                let bytes = tree.values.filter { !$0.directory }.reduce(UInt64(0)) { $0 &+ UInt64(max(0, $1.size)) }
                items.append(CleanupPlanItem(candidate: candidate, bytes: bytes, parent: parent, tree: tree))
            } catch {
                skipped.append(result(candidate, wasCancelled ? .cancelled : .skipped, error.localizedDescription))
            }
        }
        guard try readRules().hash == rules.hash else { throw CleanupError("保护规则已改变，请重新预览") }
        return CleanupPlan(items: items, skipped: skipped, totalBytes: items.reduce(0) { $0 &+ ($1.bytes ?? 0) },
                           owner: owner, created: Date(), rulesHash: rules.hash)
    }

    func execute(_ plan: CleanupPlan, permanently: Bool = false,
                 onProgress: @escaping (CleanupResult) -> Void,
                 completion: @escaping ([CleanupResult]) -> Void) {
        lock.lock()
        guard !running else {
            lock.unlock()
            let rows = plan.items.map { result($0.candidate, .skipped, "已有清理正在进行") }
            DispatchQueue.main.async { completion(plan.skipped + rows) }; return
        }
        running = true; cancelled = false; lock.unlock()
        queue.async { [self] in
            var results = plan.skipped
            for item in plan.items {
                let row: CleanupResult
                do {
                    try checkCancellation()
                    guard plan.owner == owner, Date().timeIntervalSince(plan.created) <= ttl else {
                        throw CleanupError("清理计划已过期或来源不符，请重新预览")
                    }
                    let rules = try readRules()
                    guard rules.hash == plan.rulesHash else { throw CleanupError("保护规则已改变，请重新预览") }
                    row = try process(item, permanently: permanently, rules: rules, expectedHash: plan.rulesHash)
                } catch {
                    row = result(item.candidate, wasCancelled ? .cancelled : .skipped, error.localizedDescription)
                }
                results.append(row)
                DispatchQueue.main.async { onProgress(row) }
            }
            lock.lock(); running = false; lock.unlock()
            let final = results
            DispatchQueue.main.async { completion(final) }
        }
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func checkCancellation() throws { if wasCancelled { throw CleanupError("已取消，未处理项目保留") } }
    private func result(_ c: CleanupCandidate, _ status: CleanupStatus, _ message: String, _ bytes: UInt64? = nil) -> CleanupResult {
        CleanupResult(id: c.id, path: c.path, status: status, message: message, bytes: bytes)
    }
    private func leaf(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }
    private func failure(_ operation: String) -> CleanupError { CleanupError("\(operation)：\(String(cString: strerror(errno)))") }

    // Walk from / using openat(O_NOFOLLOW); never resolve a redirected ancestor.
    private func openParent(_ path: String) throws -> Int32 {
        let components = path.split(separator: "/").dropLast()
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure("无法打开根目录") }
        for component in components {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 { let e = failure("目录不可访问或包含符号链接"); close(fd); throw e }
            close(fd); fd = next
        }
        return fd
    }
    private func node(fd: Int32) throws -> CleanupNode {
        var s = stat(); guard fstat(fd, &s) == 0 else { throw failure("无法核对文件身份") }; return CleanupNode(s)
    }
    private func node(parentFD: Int32, name: String) throws -> CleanupNode {
        var s = stat()
        guard fstatat(parentFD, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("目标不存在或无法读取") }
        let n = CleanupNode(s)
        guard n.uid == getuid(), n.mode & UInt16(S_IFMT) == UInt16(S_IFREG) || n.directory else {
            throw CleanupError("仅处理本人拥有的普通文件和目录；符号链接与特殊文件保留")
        }
        return n
    }
    private func names(_ fd: Int32) throws -> [String] {
        let copy = dup(fd); guard copy >= 0 else { throw failure("无法读取目录") }
        guard let dir = fdopendir(copy) else { close(copy); throw failure("无法读取目录") }
        defer { closedir(dir) }
        var values: [String] = []
        errno = 0
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw CleanupError("目录包含无法可靠表示的文件名") }
            if name != "." && name != ".." { values.append(name) }
            errno = 0
        }
        if errno != 0 { throw failure("目录读取不完整") }
        return values.sorted()
    }
    private func snapshot(parentFD: Int32, name: String, basePath: String, rules: [String]) throws -> [String: CleanupNode] {
        var output: [String: CleanupNode] = [:]
        let started = Date()
        let device = try node(fd: parentFD).device
        func walk(_ parent: Int32, _ name: String, _ relative: String) throws {
            try checkCancellation()
            guard output.count < 50_000, Date().timeIntervalSince(started) < 12 else { throw CleanupError("目录过大或读取超时，保留此项") }
            let absolute = relative.isEmpty ? basePath : basePath + "/" + relative
            if let why = restriction(path: absolute) { throw CleanupError(why) }
            try checkRules(absolute, rules)
            if name.lowercased().hasSuffix(".mlmodelc") { throw CleanupError("编译模型缓存保留") }
            let value = try node(parentFD: parent, name: name)
            guard value.device == device else { throw CleanupError("跨越挂载卷的目录保留") }
            output[relative] = value
            if value.directory {
                let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw failure("目录发生变化") }; defer { close(fd) }
                guard value.sameObject(try node(fd: fd)) else { throw CleanupError("目录身份发生变化") }
                for child in try names(fd) { try walk(fd, child, relative.isEmpty ? child : relative + "/" + child) }
            }
        }
        try walk(parentFD, name, "")
        return output
    }

    private struct Rules { let hash: String; let patterns: [String] }
    private func readRules() throws -> Rules {
        let path = home + "/.config/mole/whitelist"
        var info = stat(); var data = Data("missing".utf8); var patterns: [String] = []
        var ancestor = home
        for part in [".config", "mole"] {
            ancestor += "/" + part
            var s = stat()
            if lstat(ancestor, &s) != 0 {
                if errno == ENOENT { break }
                throw failure("无法核对保护规则目录")
            }
            guard s.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR) else { throw CleanupError("保护规则目录包含符号链接或特殊文件") }
        }
        if lstat(path, &info) == 0 {
            guard info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), info.st_uid == getuid(), info.st_size <= 1_048_576 else {
                throw CleanupError("保护规则不是可信的普通文件")
            }
            let fd = try openParent(path); defer { close(fd) }
            let file = openat(fd, "whitelist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { throw failure("无法读取保护规则") }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            guard CleanupNode(info).sameObject(try node(fd: file)) else { throw CleanupError("保护规则身份已改变") }
            data = try handle.readToEnd() ?? Data()
            guard CleanupNode(info) == (try node(fd: file)) else { throw CleanupError("保护规则读取期间已改变") }
            guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw CleanupError("保护规则编码或大小无效") }
            for line in text.components(separatedBy: .newlines) {
                var pattern = line.trimmingCharacters(in: .whitespaces)
                if pattern.isEmpty || pattern.hasPrefix("#") || pattern == "FINDER_METADATA" { continue }
                if pattern.hasPrefix("~") { pattern = home + pattern.dropFirst() }
                pattern = pattern.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
                guard pattern.hasPrefix("/"), !pattern.contains(".."), !pattern.contains("//"),
                      !pattern.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw CleanupError("保护规则含无法安全解释的条目，请检查规则")
                }
                patterns.append(pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern)
            }
        } else if errno != ENOENT { throw failure("无法读取保护规则") }
        // A stronger static overlay is also applied by restriction, regardless of user rules.
        return Rules(hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), patterns: patterns)
    }
    private func checkRules(_ path: String, _ patterns: [String]) throws {
        for pattern in patterns {
            let glob = pattern.contains(where: { "*?[".contains($0) })
            if path == pattern || fnmatch(pattern, path, 0) == 0 || pattern.hasPrefix(path + "/") || (!glob && path.hasPrefix(pattern + "/")) {
                throw CleanupError("命中用户清理保护规则")
            }
            // If a glob might protect an unknown descendant, keep its enclosing directory.
            if glob, let marker = pattern.firstIndex(where: { "*?[".contains($0) }) {
                let fixed = String(pattern[..<marker])
                if fixed.hasPrefix(path + "/") || path.hasPrefix(fixed) { throw CleanupError("目录可能包含受保护项目") }
            }
        }
    }

    private func activity(_ path: String, _ directory: Bool, checkOpenFiles: Bool = true) -> String? {
        if let activityCheck { return activityCheck(path, directory) }
        let relative = String(path.dropFirst(home.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        var tokens: [String] = []
        if parts.count > 2 && parts[0] == "Library" { tokens = [parts[2]] }
        else if parts.first == ".npm" { tokens = ["node", "npm", "yarn", "pnpm"] }
        else if parts.count > 1 { tokens = [parts[1]] }
        if tokens.contains(where: { $0.lowercased().contains("docker") }) { tokens.append("docker") }
        func comparable(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            let values = [app.bundleIdentifier, app.localizedName, app.bundleURL?.deletingPathExtension().lastPathComponent].compactMap { $0?.lowercased() }
            if tokens.contains(where: { token in values.contains {
                $0 == token.lowercased() || token.lowercased().hasPrefix($0 + ".") ||
                (comparable($0).count >= 3 && comparable(token).hasPrefix(comparable($0)))
            } }) {
                return "所属应用正在运行，已保留"
            }
        }
        guard let process = probe("/bin/ps", ["-axo", "comm="], timeout: 4), process.code == 0, process.error.isEmpty, !process.output.isEmpty else {
            return "无法核实活跃进程，已保留"
        }
        let commands = process.output.lowercased()
        if tokens.contains(where: { token in
            let t = token.lowercased()
            return t.count >= 3 && (commands.contains("/" + t + ".app/") || commands.components(separatedBy: .newlines).contains { URL(fileURLWithPath: $0).lastPathComponent == t })
        }) { return "所属应用或开发工具仍在运行，已保留" }
        return checkOpenFiles ? openHandles(path, directory) : nil
    }
    private func openHandles(_ path: String, _ directory: Bool) -> String? {
        var args = ["-nP", "-t", "-a", "-p", "^\(getpid())"]
        if directory { args += ["+D", path] } else { args += ["--", path] }
        guard let probe = probe("/usr/sbin/lsof", args, timeout: 6) else { return "文件占用检查超时或不可用，已保留" }
        if !probe.error.isEmpty || (probe.code != 0 && probe.code != 1) { return "无法可靠判断文件占用，已保留" }
        return probe.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && probe.code == 1 ? nil : "文件仍被进程占用，已保留"
    }
    private struct Probe { let code: Int32; let output: String; let error: String }
    private func probe(_ command: String, _ arguments: [String], timeout: TimeInterval) -> Probe? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: command); p.arguments = arguments
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "LC_ALL": "C"]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(); let err = Pipe(); p.standardOutput = out; p.standardError = err
        // Drain concurrently so a full pipe cannot deadlock a bounded probe.
        let group = DispatchGroup(); let dataLock = NSLock(); var output = Data(); var error = Data()
        do { try p.run() } catch { return nil }
        group.enter(); DispatchQueue.global(qos: .utility).async {
            let d = out.fileHandleForReading.readDataToEndOfFile(); dataLock.lock(); output = d; dataLock.unlock(); group.leave()
        }
        group.enter(); DispatchQueue.global(qos: .utility).async {
            let d = err.fileHandleForReading.readDataToEndOfFile(); dataLock.lock(); error = d; dataLock.unlock(); group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline && !wasCancelled { Thread.sleep(forTimeInterval: 0.025) }
        let stopped = p.isRunning
        if stopped { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit(); group.wait()
        if stopped { return nil }
        dataLock.lock(); defer { dataLock.unlock() }
        return Probe(code: p.terminationStatus, output: String(decoding: output, as: UTF8.self), error: String(decoding: error, as: UTF8.self))
    }

    private func process(_ item: CleanupPlanItem, permanently: Bool, rules: Rules, expectedHash: String) throws -> CleanupResult {
        let path = item.path
        if let why = restriction(path: path) { throw CleanupError(why) }
        try checkRules(path, rules.patterns)
        let parentFD = try openParent(path); defer { close(parentFD) }
        guard item.parent.sameObject(try node(fd: parentFD)) else { throw CleanupError("父目录身份已改变，已保留") }
        guard item.tree == (try snapshot(parentFD: parentFD, name: leaf(path), basePath: path, rules: rules.patterns)), let root = item.tree[""] else {
            throw CleanupError("目标或内容已改变，请重新预览")
        }
        if let why = activity(path, root.directory) { throw CleanupError(why) }
        try checkCancellation()
        guard try readRules().hash == expectedHash else { throw CleanupError("保护规则已改变，已保留") }
        // Stage on the same filesystem with atomic rename. If a source is swapped
        // between verification and rename, verify the moved object before touching it.
        let stage = ".mac-care-stage-" + UUID().uuidString
        guard mkdirat(parentFD, stage, 0o700) == 0 else { throw failure("无法建立隔离目录") }
        let stageFD = openat(parentFD, stage, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { _ = unlinkat(parentFD, stage, AT_REMOVEDIR); throw failure("无法打开隔离目录") }
        defer { close(stageFD); _ = unlinkat(parentFD, stage, AT_REMOVEDIR) }
        let stagePath = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(stage).appendingPathComponent(leaf(path)).path
        guard renameat(parentFD, leaf(path), stageFD, leaf(path)) == 0 else { throw failure("无法隔离所选项目") }
        var staged = true
        var destructiveStarted = false
        func restore(_ reason: String, status: CleanupStatus) -> CleanupResult {
            if staged && renameatx_np(stageFD, leaf(path), parentFD, leaf(path), UInt32(RENAME_EXCL)) == 0 {
                staged = false; return result(item.candidate, status, reason + "；已恢复原位置")
            }
            return result(item.candidate, .failed, reason + "；原位置被占用或恢复失败，保留于：" + stagePath)
        }
        do {
            try checkCancellation()
            guard item.tree == (try snapshot(parentFD: stageFD, name: leaf(path), basePath: path, rules: rules.patterns)) else {
                return restore("隔离后身份或内容不符", status: .skipped)
            }
            if let why = activity(path, root.directory, checkOpenFiles: false) { return restore(why, status: .skipped) }
            if activityCheck == nil, let why = openHandles(stagePath, root.directory) { return restore(why, status: .skipped) }
            guard try readRules().hash == expectedHash else { return restore("保护规则已改变", status: .skipped) }
            try checkCancellation()
            if permanently {
                // After destruction begins cancellation stops at the next item;
                // finish this isolated item to avoid claiming a partial deletion is intact.
                destructiveStarted = true
                try erase(parentFD: stageFD, name: leaf(path), relative: "", expected: item.tree)
            } else {
                let freshParent = try openParent(stagePath); defer { close(freshParent) }
                guard (try node(fd: freshParent)).sameObject(try node(fd: stageFD)),
                      root == (try node(parentFD: freshParent, name: leaf(path))) else { throw CleanupError("隔离位置已改变") }
                var destination: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: stagePath), resultingItemURL: &destination)
            }
            staged = false
            return result(item.candidate, permanently ? .removed : .trashed,
                          permanently ? "已永久删除所选项目" : "已移入废纸篓；清空前不会释放占用", item.bytes)
        } catch {
            // erase may have removed some children: never describe that as a skip.
            return restore((destructiveStarted ? "部分内容可能已删除；" : "") + error.localizedDescription,
                           status: destructiveStarted ? .failed : (wasCancelled ? .cancelled : .failed))
        }
    }

    /// Descriptor-relative unlink, visiting only the prepared tree. No recursive
    /// rm or link following; a newly added child makes rmdir fail and is preserved.
    private func erase(parentFD: Int32, name: String, relative: String, expected: [String: CleanupNode]) throws {
        guard let identity = expected[relative], identity == (try node(parentFD: parentFD, name: name)) else {
            throw CleanupError("删除前文件身份或内容变化，停止当前项")
        }
        if identity.directory {
            let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw failure("无法读取隔离目录") }; defer { close(fd) }
            guard identity.sameObject(try node(fd: fd)) else { throw CleanupError("隔离目录身份改变") }
            let children = try names(fd)
            for child in children {
                let childPath = relative.isEmpty ? child : relative + "/" + child
                guard expected[childPath] != nil else { throw CleanupError("出现未授权新文件，已停止当前项") }
                try erase(parentFD: fd, name: child, relative: childPath, expected: expected)
            }
            guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else { throw failure("目录未完全删除") }
        } else {
            guard unlinkat(parentFD, name, 0) == 0 else { throw failure("文件删除失败") }
        }
    }
}
