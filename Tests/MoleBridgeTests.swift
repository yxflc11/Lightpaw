// Fixture-only integration tests. Never invokes the installed Mole CLI.
// swiftc -swift-version 5 Sources/MoleBridge.swift Tests/MoleBridgeTests.swift -o .build/MoleBridgeTests
import Foundation
import Darwin

@main
enum MoleBridgeTests {
    static var failures = 0
    static let fm = FileManager.default
    static var guardian: URL!
    static var executable: URL { URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL }
    static var root: URL!

    static func output(_ text: String, fd: Int32 = STDOUT_FILENO) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count }
                else if errno != EINTR { break }
            }
        }
    }

    static func fixture(_ args: [String]) -> Never {
        let mode = args[0]
        if mode == "danger" || mode == "stubborn" {
            let marker = args[1], pidfile = args[2]
            try? String(getpid()).write(toFile: pidfile, atomically: true, encoding: .utf8)
            if mode == "stubborn" { signal(SIGTERM, SIG_IGN) }
            output("READY\n")
            while let line = readLine() {
                if line == "finish" { exit(0) }
            }
            try? "UNSAFE EOF".write(toFile: marker, atomically: true, encoding: .utf8)
            exit(71)
        }
        if mode == "echo" {
            output("中文开始\n")
            output("STDERR_ONLY\n", fd: STDERR_FILENO)
            while let line = readLine() {
                if line == "finish" { exit(0) }
                output("INPUT:\(line)\n")
            }
            exit(72)
        }
        if mode == "flood" {
            try? String(getpid()).write(toFile: args[1], atomically: true, encoding: .utf8)
            let chunk = String(repeating: "x", count: 16384)
            while true { output(chunk) }
        }
        if mode == "background" {
            var child: pid_t = 0
            var childArgs = [executable.path, "--fixture", "background-child"].map { strdup($0) }
            childArgs.append(nil)
            defer { childArgs.forEach { free($0) } }
            var emptyEnvironment: [UnsafeMutablePointer<CChar>?] = [nil]
            let launched = executable.path.withCString { command in
                posix_spawn(&child, command, nil, nil, &childArgs, &emptyEnvironment)
            }
            guard launched == 0 else { exit(75) }
            try? String(child).write(toFile: args[1], atomically: true, encoding: .utf8)
            output("BACKGROUND_STARTED\n")
            exit(0)
        }
        if mode == "background-child" {
            signal(SIGTERM, SIG_IGN)
            while true { pause() }
        }
        if mode == "environment" {
            let env = ProcessInfo.processInfo.environment
            output("MOLE_TEST=\(env["MOLE_BRIDGE_TEST_POISON"] ?? "nil")\n")
            output("BASH_ENV=\(env["BASH_ENV"] ?? "nil")\n")
            output("HOMEBREW_DEBUG=\(env["HOMEBREW_DEBUG"] ?? "nil")\n")
            output("NO_AUTOREMOVE=\(env["HOMEBREW_NO_AUTOREMOVE"] ?? "nil")\n")
            output("ASKPASS=\(env["SUDO_ASKPASS"] ?? "nil")\n")
            output("NO_INSTALL_CLEANUP=\(env["HOMEBREW_NO_INSTALL_CLEANUP"] ?? "nil")\n")
            output("BREW_OPERATION=\(env["LIGHTPAW_BREW_OPERATION"] ?? "nil")\n")
            output("PATH=\(env["PATH"] ?? "nil")\n")
            exit(0)
        }
        exit(73)
    }

    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        if value() { output("PASS \(name)\n") }
        else { failures += 1; output("FAIL \(name)\n", fd: STDERR_FILENO) }
    }

    @discardableResult
    static func wait(_ timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    static func path(_ label: String) -> URL { root.appendingPathComponent(label) }
    static func pid(_ url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    static func gone(_ value: pid_t?) -> Bool {
        guard let value else { return false }
        return kill(value, 0) != 0 && errno == ESRCH
    }

    static func rawGuardian(_ args: [String], timeoutMS: Int = 60000) throws -> (Process, Pipe) {
        let process = Process(), input = Pipe()
        process.executableURL = guardian
        process.arguments = ["--parent-pid", String(getpid()), "--timeout-ms", String(timeoutMS),
                             "--", executable.path, "--fixture"] + args
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? input.fileHandleForReading.close()
        return (process, input)
    }

    static func rawCancellation(_ label: String, closeInput: Bool) throws {
        let marker = path(label + ".danger"), pidfile = path(label + ".pid")
        let (process, input) = try rawGuardian(["danger", marker.path, pidfile.path])
        check(wait(until: { pid(pidfile) != nil }), "\(label): fixture ready")
        let childPID = pid(pidfile)
        if closeInput { try input.fileHandleForWriting.close() }
        else { process.terminate() }
        check(wait(until: { !process.isRunning }), "\(label): guardian exits")
        if process.isRunning { process.terminate() }
        check(!fm.fileExists(atPath: marker.path), "\(label): no unsafe EOF action")
        check(wait(2, until: { gone(childPID) }), "\(label): child reaped")
        if !closeInput { try? input.fileHandleForWriting.close() }
    }

    // Owner is deliberately killed while the test retains stdin's outer writer;
    // this exercises getppid(), independently from the outer-EOF cancellation.
    static func owner(_ args: [String]) -> Never {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = ["--parent-pid", String(getpid()), "--timeout-ms", "60000", "--",
                             executable.path, "--fixture", "danger", args[1], args[2]]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try String(process.processIdentifier).write(toFile: args[3], atomically: true, encoding: .utf8)
            while true { sleep(1) }
        } catch { exit(74) }
    }

    static func parentDeath() throws {
        let marker = path("parent-death.danger"), pidfile = path("parent-death.pid")
        let guardianPIDFile = path("parent-death.guardian-pid")
        let ownerProcess = Process(), input = Pipe()
        ownerProcess.executableURL = executable
        ownerProcess.arguments = ["--owner", guardian.path, marker.path, pidfile.path, guardianPIDFile.path]
        ownerProcess.standardInput = input
        ownerProcess.standardOutput = FileHandle.nullDevice
        ownerProcess.standardError = FileHandle.nullDevice
        try ownerProcess.run()
        try? input.fileHandleForReading.close()
        check(wait(until: { pid(pidfile) != nil && pid(guardianPIDFile) != nil }), "parent death: ready")
        let childPID = pid(pidfile), guardianPID = pid(guardianPIDFile)
        kill(ownerProcess.processIdentifier, SIGKILL)
        check(wait(until: { !ownerProcess.isRunning }), "parent death: owner exits")
        check(wait(until: { gone(childPID) }), "parent death: child ends with outer input still open")
        check(!fm.fileExists(atPath: marker.path), "parent death: no unsafe EOF action")
        check(wait(3, until: { gone(guardianPID) }), "parent death: guardian ends")
        try? input.fileHandleForWriting.close()
    }

    static func bridge(_ args: [String], timeout: TimeInterval = 30,
                       environment: [String: String] = [:], action: ((MoleBridge) -> Void)? = nil) throws -> (MoleCommandResult?, String) {
        let bridge = MoleBridge(executableURL: executable, guardianURL: guardian)
        var completed: MoleCommandResult?, streamed = ""
        try bridge.start(arguments: ["--fixture"] + args, timeout: timeout, environment: environment, onOutput: { text in
            checkMainThreadSilently()
            // Avoid the test itself retaining another 16 MiB flood transcript.
            if streamed.utf8.count < 65536 { streamed += text }
        }, onCompletion: { result in
            checkMainThreadSilently()
            completed = result
        })
        check(bridge.isRunning, "bridge reports running")
        action?(bridge)
        check(wait(max(12, timeout + 5), until: { completed != nil }), "bridge completes")
        if completed == nil { bridge.cancel(); _ = wait(5, until: { completed != nil }) }
        check(!bridge.isRunning, "bridge clears running state")
        return (completed, streamed)
    }
    static func checkMainThreadSilently() { if !Thread.isMainThread { failures += 1 } }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--fixture" { fixture(Array(args.dropFirst())) }
        if args.first == "--owner" { owner(Array(args.dropFirst())) }
        guard args.count == 1 else { output("Usage: MoleBridgeTests /absolute/MoleGuardian\n"); exit(2) }
        guardian = URL(fileURLWithPath: args[0])
        root = fm.temporaryDirectory.appendingPathComponent("mole-bridge-tests-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: root) }
            try rawCancellation("outer EOF", closeInput: true)
            try rawCancellation("SIGTERM", closeInput: false)
            try parentDeath()

            let (echo, streamed) = try bridge(["echo"]) { bridge in
                bridge.writeInput("one\n")
                bridge.writeInput("二\nfinish\n")
            }
            check(echo?.exitCode == 0 && echo?.cancelled == false, "normal exit status")
            check(echo?.stdout == "中文开始\nINPUT:one\nINPUT:二\n", "ordered input and complete UTF-8 stdout")
            check(echo?.stderr == "STDERR_ONLY\n", "stderr remains separate")
            check(streamed.contains("中文开始") && streamed.contains("INPUT:二"), "streamed prompts")

            let cancelMarker = path("bridge-cancel.danger"), cancelPIDFile = path("bridge-cancel.pid")
            let (cancelled, _) = try bridge(["danger", cancelMarker.path, cancelPIDFile.path]) { bridge in
                _ = wait(until: { pid(cancelPIDFile) != nil })
                bridge.cancel()
            }
            check(cancelled?.cancelled == true && !fm.fileExists(atPath: cancelMarker.path), "bridge cancel cannot confirm EOF")
            check(gone(pid(cancelPIDFile)), "bridge cancel reaps fixture")

            let timeoutMarker = path("timeout.danger"), timeoutPID = path("timeout.pid")
            let (timed, _) = try bridge(["stubborn", timeoutMarker.path, timeoutPID.path], timeout: 0.4)
            check(timed?.exitCode == 124 && timed?.cancelled == true, "timeout classified")
            check(!fm.fileExists(atPath: timeoutMarker.path) && gone(pid(timeoutPID)), "timeout KILLs stubborn child without EOF")

            let floodPID = path("flood.pid")
            let (flood, _) = try bridge(["flood", floodPID.path])
            check(flood?.truncated == true && flood?.cancelled == true, "output cap cancels")
            check((flood?.stdout.utf8.count ?? -1) == 16 * 1024 * 1024, "capture bounded at 16 MiB")
            check(gone(pid(floodPID)), "output cap leaves no fixture")

            let backgroundPID = path("background.pid")
            let (background, _) = try bridge(["background", backgroundPID.path])
            check(background?.exitCode == 0, "main child can finish normally")
            check(wait(3, until: { gone(pid(backgroundPID)) }), "normal completion ends same-group background child")

            setenv("MOLE_BRIDGE_TEST_POISON", "should-be-removed", 1)
            setenv("BASH_ENV", "/untrusted/fixture-only", 1)
            setenv("HOMEBREW_DEBUG", "1", 1)
            setenv("SUDO_ASKPASS", "/untrusted/password", 1)
            setenv("LIGHTPAW_BREW_OPERATION", "inherited", 1)
            let (environment, _) = try bridge(["environment"], environment: ["HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1"])
            unsetenv("HOMEBREW_DEBUG"); unsetenv("SUDO_ASKPASS")
            unsetenv("LIGHTPAW_BREW_OPERATION")
            unsetenv("MOLE_BRIDGE_TEST_POISON"); unsetenv("BASH_ENV")
            check(environment?.stdout.contains("MOLE_TEST=nil\nBASH_ENV=nil\n") == true, "inherited injection environment removed")
            check(environment?.stdout.contains("HOMEBREW_DEBUG=nil\nNO_AUTOREMOVE=1\nASKPASS=nil") == true, "only fixed brew environment is supplied")
            check(environment?.stdout.contains("NO_INSTALL_CLEANUP=1\nBREW_OPERATION=nil") == true, "cleanup suppressed and inherited operation removed")
            let invalid = MoleBridge(executableURL: executable, guardianURL: guardian)
            do { try invalid.start(arguments: [], timeout: 1, environment: ["SUDO_ASKPASS": "/untrusted"], onOutput: { _ in }, onCompletion: { _ in }); check(false, "arbitrary environment rejected") } catch { check(true, "arbitrary environment rejected") }
            check(environment?.stdout.contains("PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin") == true, "known PATH supplied")
        } catch {
            failures += 1
            output("FAIL thrown error: \(error)\n", fd: STDERR_FILENO)
        }
        output("Mole bridge fixture tests: \(failures == 0 ? "PASS" : "FAIL"), failures=\(failures)\n")
        exit(failures == 0 ? 0 : 1)
    }
}
