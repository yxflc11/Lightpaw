import Foundation
import Darwin
import Security

public struct MoleCommandResult {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let cancelled: Bool
    public let truncated: Bool
}

public enum MoleBridgeError: LocalizedError {
    case alreadyRunning, invalidTimeout, invalidArgument, unavailableExecutable(String)
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "已有 Mole 操作正在运行。"
        case .invalidTimeout: return "Mole 操作时限须为 0–24 小时内的正数。"
        case .invalidArgument: return "Mole 参数无效。"
        case .unavailableExecutable(let name): return "找不到可运行的 \(name)。"
        }
    }
}

/// The UI supplies arguments, never a shell command. Alternate executable URLs
/// are an injection seam for CLI fixture tests, not a user-facing feature.
public final class MoleBridge {
    private let executableURL: URL
    private let guardianURL: URL
    private let queue = DispatchQueue(label: "local.codex.memorywatch.mole-bridge")
    private var session: Session?

    // One bounded capture budget across both streams. Input is never logged.
    private static let outputLimit = 16 * 1024 * 1024
    private static let inputLimit = 64 * 1024

    private final class Session {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let onOutput: (String) -> Void
        let onCompletion: (MoleCommandResult) -> Void
        var stdout = Data(), stderr = Data(), pendingInput = Data()
        var outputTail = Data(), errorTail = Data()
        var outputSource: DispatchSourceRead?, errorSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var cancelled = false, truncated = false, completed = false

        init(onOutput: @escaping (String) -> Void,
             onCompletion: @escaping (MoleCommandResult) -> Void) {
            self.onOutput = onOutput
            self.onCompletion = onCompletion
        }
    }

    public init(executableURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/mo"),
                guardianURL: URL? = nil) {
        self.executableURL = executableURL
        self.guardianURL = guardianURL ??
            (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
                .deletingLastPathComponent().appendingPathComponent("MoleGuardian")
    }

    public var isRunning: Bool { queue.sync { session != nil } }

    public func start(arguments: [String], timeout: TimeInterval, environment: [String: String] = [:], allowAdministratorPrompt: Bool = false, administratorOperation: String = "卸载",
                      onOutput: @escaping (String) -> Void,
                      onCompletion: @escaping (MoleCommandResult) -> Void) throws {
        try queue.sync {
            guard session == nil else { throw MoleBridgeError.alreadyRunning }
            guard timeout.isFinite, timeout > 0, timeout <= 86400 else {
                throw MoleBridgeError.invalidTimeout
            }
            guard arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
                throw MoleBridgeError.invalidArgument
            }
            let allowedEnvironment: Set<String> = ["HOMEBREW_NO_AUTOREMOVE", "HOMEBREW_NO_AUTO_UPDATE", "HOMEBREW_NO_ANALYTICS", "HOMEBREW_NO_ENV_HINTS", "HOMEBREW_NO_INSTALL_CLEANUP"]
            guard environment.allSatisfy({ allowedEnvironment.contains($0.key) && $0.value == "1" }) else { throw MoleBridgeError.invalidArgument }
            for url in [executableURL, guardianURL] {
                guard url.isFileURL, url.path.hasPrefix("/"),
                      FileManager.default.isExecutableFile(atPath: url.path) else {
                    throw MoleBridgeError.unavailableExecutable(url.lastPathComponent)
                }
            }
            let active = Session(onOutput: onOutput, onCompletion: onCompletion)
            active.process.executableURL = guardianURL
            active.process.arguments = ["--parent-pid", String(getpid()), "--timeout-ms",
                                        String(max(1, Int(ceil(timeout * 1000)))), "--",
                                        executableURL.path] + arguments
            active.process.environment = Self.cleanEnvironment()
            environment.forEach { active.process.environment?[$0.key] = $0.value }
            if allowAdministratorPrompt {
                guard ["卸载", "更新"].contains(administratorOperation),
                      ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains(executableURL.path),
                      Bundle.main.bundleURL.pathExtension == "app" else { throw MoleBridgeError.invalidArgument }
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MacCareAskpass")
                var code: SecStaticCode?
                guard helper.resolvingSymlinksInPath().path == helper.path,
                      FileManager.default.isExecutableFile(atPath: helper.path),
                      SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
                      let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else {
                    throw MoleBridgeError.unavailableExecutable("已验证的管理员密码窗口")
                }
                active.process.environment?["SUDO_ASKPASS"] = helper.path
                active.process.environment?["LIGHTPAW_BREW_OPERATION"] = administratorOperation
            }
            active.process.standardInput = active.input
            active.process.standardOutput = active.output
            active.process.standardError = active.errors
            let workQueue = queue
            active.process.terminationHandler = { [weak self, active] _ in
                workQueue.async {
                    self?.finish(active)
                    // If the bridge was released, still keep stdin until guardian exits.
                    if self == nil { Self.closeHandles(active) }
                    active.process.terminationHandler = nil
                }
            }
            do { try active.process.run() }
            catch {
                active.process.terminationHandler = nil
                Self.closeHandles(active)
                throw error
            }
            // Retain the writer for the whole invocation, including cancellation.
            try? active.input.fileHandleForReading.close()
            try? active.output.fileHandleForWriting.close()
            try? active.errors.fileHandleForWriting.close()
            for handle in [active.output.fileHandleForReading, active.errors.fileHandleForReading,
                           active.input.fileHandleForWriting] {
                let fd = handle.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            }
            _ = fcntl(active.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            session = active
            active.outputSource = makeReader(active, errorStream: false)
            active.errorSource = makeReader(active, errorStream: true)
        }
    }

    public func writeInput(_ text: String) {
        queue.async { [weak self] in
            guard let self, let active = self.session, !active.cancelled else { return }
            let bytes = Data(text.utf8)
            guard bytes.count <= Self.inputLimit - active.pendingInput.count else {
                self.requestCancellation(active)
                return
            }
            active.pendingInput.append(bytes)
            self.flushInput(active)
        }
    }

    public func cancel() {
        queue.async { [weak self] in
            guard let self, let active = self.session else { return }
            self.requestCancellation(active)
        }
    }

    private static func cleanEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            let prefixes = ["MOLE_", "DYLD_", "LD_", "BASH_FUNC_", "HOMEBREW_"]
            let removed: Set<String> = ["BASH_ENV", "ENV", "CDPATH", "GLOBIGNORE", "SHELLOPTS",
                "BASHOPTS", "IFS", "ZDOTDIR", "NODE_OPTIONS", "PYTHONPATH", "PYTHONHOME",
                "PERL5OPT", "PERL5LIB", "RUBYOPT", "RUBYLIB", "SUDO_ASKPASS", "SSH_ASKPASS", "LIGHTPAW_BREW_OPERATION"]
            return !prefixes.contains(where: key.hasPrefix) && !removed.contains(key)
        }
        environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        return environment
    }

    private func makeReader(_ active: Session, errorStream: Bool) -> DispatchSourceRead {
        let handle = errorStream ? active.errors.fileHandleForReading : active.output.fileHandleForReading
        let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self, weak active] in
            guard let self, let active else { return }
            self.drain(active, errorStream: errorStream)
        }
        source.resume()
        return source
    }

    private func drain(_ active: Session, errorStream: Bool) {
        let fd = (errorStream ? active.errors.fileHandleForReading : active.output.fileHandleForReading).fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 16384)
        // A finite batch prevents a noisy process from starving cancel/termination.
        for _ in 0..<64 {
            let size = Darwin.read(fd, &buffer, buffer.count)
            if size > 0 {
                capture(Data(buffer[0..<size]), active, errorStream: errorStream)
            } else if size == 0 {
                if errorStream { active.errorSource?.cancel() }
                else { active.outputSource?.cancel() }
                break
            } else {
                if errno == EINTR { continue }
                break
            }
        }
    }

    private func capture(_ data: Data, _ active: Session, errorStream: Bool) {
        let room = Self.outputLimit - active.stdout.count - active.stderr.count
        let saved = Data(data.prefix(max(0, room)))
        if errorStream { active.stderr.append(saved) } else { active.stdout.append(saved) }
        if !saved.isEmpty {
            var tail = errorStream ? active.errorTail : active.outputTail
            tail.append(saved)
            let count = Self.completeUTF8Prefix(tail)
            if count > 0 {
                let text = String(decoding: tail.prefix(count), as: UTF8.self)
                tail.removeFirst(count)
                DispatchQueue.main.async { active.onOutput(text) }
            }
            if errorStream { active.errorTail = tail } else { active.outputTail = tail }
        }
        if data.count > room {
            active.truncated = true
            requestCancellation(active)
        }
    }

    /// Keep a partial final UTF-8 sequence for the next chunk (Chinese prompts).
    private static func completeUTF8Prefix(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(4))
        guard !bytes.isEmpty else { return 0 }
        var index = bytes.count - 1
        while index > 0 && bytes[index] & 0xC0 == 0x80 { index -= 1 }
        let head = bytes[index]
        let expected: Int = head < 0x80 ? 1 : head & 0xE0 == 0xC0 ? 2 :
            head & 0xF0 == 0xE0 ? 3 : head & 0xF8 == 0xF0 ? 4 : 1
        let remaining = bytes.count - index
        return expected > remaining ? data.count - remaining : data.count
    }

    private func flushInput(_ active: Session) {
        guard !active.cancelled, !active.completed else { return }
        let fd = active.input.fileHandleForWriting.fileDescriptor
        while !active.pendingInput.isEmpty {
            let count = active.pendingInput.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress, buffer.count)
            }
            if count > 0 { active.pendingInput.removeFirst(count); continue }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if active.writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self, weak active] in
                        guard let self, let active else { return }
                        self.flushInput(active)
                    }
                    active.writeSource = source
                    source.resume()
                }
                return
            }
            requestCancellation(active)
            return
        }
        active.writeSource?.cancel()
        active.writeSource = nil
    }

    private func requestCancellation(_ active: Session) {
        guard !active.cancelled, !active.completed else { return }
        active.cancelled = true
        active.pendingInput.removeAll(keepingCapacity: false)
        active.writeSource?.cancel()
        active.writeSource = nil
        // Only signal the supervisor. NEVER close the writer to cancel Mole.
        if active.process.isRunning { active.process.terminate() }
    }

    private func finish(_ active: Session) {
        guard !active.completed else { return }
        drain(active, errorStream: false)
        drain(active, errorStream: true)
        active.completed = true
        for tail in [active.outputTail, active.errorTail] where !tail.isEmpty {
            let text = String(decoding: tail, as: UTF8.self)
            DispatchQueue.main.async { active.onOutput(text) }
        }
        let result = MoleCommandResult(
            exitCode: active.process.terminationStatus,
            stdout: String(decoding: active.stdout, as: UTF8.self),
            stderr: String(decoding: active.stderr, as: UTF8.self),
            cancelled: active.cancelled || [124, 130].contains(active.process.terminationStatus),
            truncated: active.truncated)
        Self.closeHandles(active)
        if session === active { session = nil }
        DispatchQueue.main.async { active.onCompletion(result) }
    }

    private static func closeHandles(_ active: Session) {
        active.outputSource?.cancel(); active.errorSource?.cancel(); active.writeSource?.cancel()
        // Called only before launch failure or AFTER guardian termination.
        for handle in [active.input.fileHandleForReading, active.input.fileHandleForWriting,
                       active.output.fileHandleForReading, active.output.fileHandleForWriting,
                       active.errors.fileHandleForReading, active.errors.fileHandleForWriting] {
            try? handle.close()
        }
    }

    deinit {
        // Session is retained by terminationHandler until the guardian has reaped
        // its child. No deinit path closes stdin before that handshake completes.
        if let active = session, active.process.isRunning { active.process.terminate() }
    }
}
