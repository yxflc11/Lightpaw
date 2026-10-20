// Fixture-only: no real Homebrew uninstall is performed by this executable.
import AppKit
import Foundation
import Darwin

@main
enum BrewServiceTests {
    static let fm = FileManager.default
    static var failures = 0
    static var guardian: URL!
    static var executable: URL { URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL }

    struct Fixture {
        let root: URL
        let brew: URL
        let room: URL
        let prefix: URL
        let app: URL
        let receipt: URL
        let manifest: URL
        let record: [String: Any]
        func service() -> BrewService {
            BrewService(brewURL: brew, caskroomURL: room, prefixURL: prefix,
                        homeURL: root.appendingPathComponent("home"), guardianURL: guardian)
        }
    }

    static func json(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }
    static func makeApp(_ url: URL, id: String) throws {
        try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": url.deletingPathExtension().lastPathComponent, "CFBundleVersion": "1"], format: .xml, options: 0)
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
    static func fixture(at root: URL, token: String = "test-cask", ruby: Bool = false,
                        extra: [[String: Any]] = [], flight: Bool = false) throws -> Fixture {
        let brew = root.appendingPathComponent("brew")
        let room = root.appendingPathComponent("Caskroom"), prefix = root.appendingPathComponent("prefix")
        let apps = root.appendingPathComponent("Applications"), app = apps.appendingPathComponent("Fixture.app")
        let metadata = room.appendingPathComponent(token + "/.metadata")
        let manifests = metadata.appendingPathComponent("1.0/20261019000000.001/Casks")
        try fm.createDirectory(at: manifests, withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try makeApp(app, id: "local.mac-care.brew-fixture")
        try fm.createSymbolicLink(at: brew, withDestinationURL: executable)
        let receipt = metadata.appendingPathComponent("INSTALL_RECEIPT.json")
        let artifacts: [[String: Any]] = [["app": ["Fixture.app"]]] + extra
        try json(["source": ["version": "1.0", "tap": "local/fixtures"], "uninstall_flight_blocks": flight,
                  "uninstall_artifacts": artifacts], to: receipt)
        try json(["default": ["appdir": apps.path], "env": [:], "explicit": [:]], to: metadata.appendingPathComponent("config.json"))
        let manifest = manifests.appendingPathComponent(token + (ruby ? ".rb" : ".json"))
        if ruby {
            let source = """
            cask "\(token)" do
              version "1.0"
              sha256 "0123456789abcdef"
              url "file:///private/tmp/fixture.zip"
              name "Fixture"
              app "Fixture.app"
            end
            """
            try source.write(to: manifest, atomically: true, encoding: .utf8)
        } else { try json([:], to: manifest) }
        // Deliberately newer inventory artifacts: must NOT drive the preview.
        let record: [String: Any] = ["token": token, "installed": "1.0", "version": "9.0",
                                      "artifacts": [["app": ["Renamed.app"], "target": apps.appendingPathComponent("Renamed.app").path]]]
        try json(["casks": [record]], to: brew.appendingPathExtension("inventory.json"))
        return Fixture(root: root, brew: brew, room: room, prefix: prefix, app: app, receipt: receipt, manifest: manifest, record: record)
    }
    static func plan(_ f: Fixture, service: BrewService? = nil) throws -> BrewUninstallPlan {
        try (service ?? f.service()).makePlan(records: [f.record], appPath: f.app.path, bundleID: "local.mac-care.brew-fixture")
    }
    static func check(_ condition: Bool, _ name: String) {
        if condition { print("PASS \(name)") }
        else { failures += 1; print("FAIL \(name)") }
    }
    static func rejects(_ name: String, _ action: () throws -> Void) {
        do { try action(); check(false, name) } catch { check(true, name) }
    }
    static func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
    static func appPaths(_ service: BrewService) throws -> Result<Set<String>, Error> {
        var result: Result<Set<String>, Error>?
        try service.installedAppPaths {
            check(Thread.isMainThread, "source classification callback on main thread")
            result = $0
        }
        guard wait({ result != nil }), let result else {
            service.cancel()
            throw BrewServiceError.unavailable("source classification fixture timeout")
        }
        return result
    }

    // Executed through MoleGuardian as a fake brew, via a temporary symlink to
    // this binary. Writes only its own temporary fixture invocation metadata.
    static func fakeBrew(_ arguments: [String]) -> Never {
        let base = URL(fileURLWithPath: CommandLine.arguments[0])
        if arguments == ["info", "--cask", "--json=v2", "--installed"],
           let data = try? Data(contentsOf: base.appendingPathExtension("inventory.json")) {
            try? Data("called".utf8).write(to: base.appendingPathExtension("inventory-invoked"))
            FileHandle.standardOutput.write(data); exit(0)
        }
        let installedRuby = base.deletingLastPathComponent().appendingPathComponent("Caskroom/test-cask/.metadata/1.0/20261019000000.001/Casks/test-cask.rb").path
        let exactInstalledRuby = arguments.count == 3 && arguments[0] == "uninstall" && arguments[1] == "--cask" &&
            URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath() == URL(fileURLWithPath: installedRuby).resolvingSymlinksInPath()
        if arguments == ["uninstall", "--cask", "test-cask"] || exactInstalledRuby {
            let env = ProcessInfo.processInfo.environment
            let result: [String: Any] = ["arguments": arguments,
                "no_autoremove": env["HOMEBREW_NO_AUTOREMOVE"] ?? "missing",
                "no_auto_update": env["HOMEBREW_NO_AUTO_UPDATE"] ?? "missing",
                "no_analytics": env["HOMEBREW_NO_ANALYTICS"] ?? "missing",
                "no_env_hints": env["HOMEBREW_NO_ENV_HINTS"] ?? "missing"]
            try? json(result, to: base.appendingPathExtension("invocation.json"))
            FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: result))
            exit(0)
        }
        FileHandle.standardError.write(Data("Unexpected fixture argv: \(arguments); expected Ruby: \(installedRuby)\n".utf8))
        exit(91)
    }

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ["info", "uninstall"].contains(arguments.first ?? "") { fakeBrew(arguments) }
        if arguments.first == "--inspect-paths", arguments.count == 2 {
            let service = BrewService(guardianURL: URL(fileURLWithPath: arguments[1]))
            do {
                let paths = try appPaths(service).get()
                for path in paths.sorted() { print(path) }
                print("READ_ONLY_SOURCES count=\(paths.count)")
                exit(0)
            } catch { print("READ_ONLY_SOURCES_ERROR \(error.localizedDescription)"); exit(1) }
        }
        if arguments.first == "--inspect-fixture", arguments.count == 3 {
            // Explicitly read-only real-brew integration probe. Never calls uninstall.
            let app = URL(fileURLWithPath: arguments[1])
            let service = BrewService(guardianURL: URL(fileURLWithPath: arguments[2]))
            var done = false, status: Int32 = 1
            do {
                let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
                let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
                let id = plist["CFBundleIdentifier"] as! String
                try service.prepare(appPath: app.path, bundleID: id, onOutput: { print($0) }) { result in
                    switch result {
                    case .success(let plan):
                        print(plan.preview)
                        print("READ_ONLY_PLAN token=\(plan.token) canExecute=\(plan.canExecute) admin=\(plan.requiresAdministrator)")
                        status = plan.canExecute ? 0 : 3
                    case .failure(let error): print("READ_ONLY_PLAN_ERROR \(error.localizedDescription)")
                    }
                    done = true
                }
                if !wait({ done }) { service.cancel(); print("READ_ONLY_PLAN_TIMEOUT") }
            } catch { print("READ_ONLY_PLAN_ERROR \(error.localizedDescription)") }
            exit(status)
        }
        guard arguments.count == 1 else { print("Usage: BrewServiceTests /absolute/MoleGuardian"); exit(2) }
        guardian = URL(fileURLWithPath: arguments[0])
        let root = fm.temporaryDirectory.appendingPathComponent("mac-care-brew-tests-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: root) }
            let normal = try fixture(at: root.appendingPathComponent("normal"), extra: [["binary": ["Fixture.app/Contents/MacOS/fixture", ["target": "fixture"]]], ["zap": [["trash": "~/Library/Application Support/Fixture"]]]])
            let service = normal.service(), prepared = try plan(normal, service: service)
            check(prepared.canExecute && prepared.token == "test-cask", "installed receipt gives exact token")
            check(prepared.preview.contains(normal.app.path) && !prepared.preview.contains("Renamed.app"), "newer inventory artifacts cannot replace installed scope")
            check(prepared.preview.contains(normal.prefix.appendingPathComponent("bin/fixture").path), "binary target resolved from installed declaration")
            check(prepared.preview.contains("额外清理不会执行") && prepared.preview.contains("~/Library/Application Support/Fixture"), "zap explicitly retained")
            check(!prepared.requiresAdministrator, "writable ordinary app does not force administrator prompt")
            check(!prepared.scriptReviewRequired && prepared.scriptReviewSource == nil, "ordinary artifacts require no script confirmation")

            for token in ["--force", "../../other", "x;rm", "a/b"] {
                rejects("unsafe token rejected: \(token)") { _ = try BrewService.inventory(JSONSerialization.data(withJSONObject: ["casks": [["token": token, "installed": "1"]]])) }
            }
            rejects("duplicate token rejected") { _ = try BrewService.inventory(JSONSerialization.data(withJSONObject: ["casks": [normal.record, normal.record]])) }
            rejects("wrong app identity rejected") { _ = try service.makePlan(records: [normal.record], appPath: normal.app.path, bundleID: "local.wrong") }
            rejects("foreign plan owner rejected") { try normal.service().uninstall(prepared, onOutput: { _ in }, completion: { _ in }) }

            let ruby = try fixture(at: root.appendingPathComponent("ruby"), ruby: true)
            check(try plan(ruby).canExecute, "minimal static Ruby cask supported")
            let rubyService = ruby.service(), rubyPlan = try plan(ruby, service: rubyService)
            var rubyOutcome: MoleCommandResult?
            try rubyService.uninstall(rubyPlan, onOutput: { _ in }, completion: { rubyOutcome = $0 })
            check(wait { rubyOutcome != nil } && rubyOutcome?.exitCode == 0, "unchanged installed Ruby path reaches guarded fake brew")
            if rubyOutcome?.exitCode != 0 { print(rubyOutcome?.stderr ?? "missing result") }
            let rubyInvocation = try JSONSerialization.jsonObject(with: Data(contentsOf: ruby.brew.appendingPathExtension("invocation.json"))) as! [String: Any]
            let rubyArguments = rubyInvocation["arguments"] as? [String] ?? []
            check(rubyArguments.count == 3 && Array(rubyArguments.prefix(2)) == ["uninstall", "--cask"] &&
                  URL(fileURLWithPath: rubyArguments[2]).resolvingSymlinksInPath() == ruby.manifest.resolvingSymlinksInPath(),
                  "Ruby execution bound to exact installed path instead of current tap token")
            try "\nsystem \"touch /private/tmp/should-never-run\"\n".write(to: ruby.manifest, atomically: true, encoding: .utf8)
            check(try !plan(ruby).canExecute, "executable Ruby is not evaluated or silently authorized")

            let hooked = try fixture(at: root.appendingPathComponent("hook"), extra: [["uninstall_postflight": NSNull()]], flight: true)
            let hookPlan = try plan(hooked)
            check(!hookPlan.canExecute && hookPlan.preview.contains("uninstall_postflight"), "flight hooks visible and blocked")

            let complex = try fixture(at: root.appendingPathComponent("complex"), ruby: true,
                                      extra: [["uninstall_preflight": NSNull()], ["uninstall_postflight": NSNull()]], flight: true)
            let marker = complex.root.appendingPathComponent("must-not-exist")
            let complexSource = """
            cask "test-cask" do
              version "1.0"
              sha256 :no_check
              url "file:///private/tmp/fixture.zip"
              app "Fixture.app"
              uninstall_preflight do
                File.write("\(marker.path)", "before")
              end
              uninstall_postflight do
                File.write("\(marker.path)", "after")
              end
            end
            """
            try complexSource.write(to: complex.manifest, atomically: true, encoding: .utf8)
            let complexService = complex.service(), complexPlan = try plan(complex, service: complexService)
            check(complexPlan.canExecute && complexPlan.scriptReviewRequired, "installed Ruby hooks supported with explicit review")
            check(complexPlan.scriptReviewSource?.contains(complexSource) == true && complexPlan.preview.contains("SHA256") && complexPlan.preview.contains("不是完整影响清单"), "complete installed Ruby and honest unknown behavior disclosed")
            rejects("Ruby cannot execute without explicit review confirmation") {
                try complexService.uninstall(complexPlan, onOutput: { _ in }, completion: { _ in })
            }
            check(!fm.fileExists(atPath: marker.path), "preview never executes Ruby hooks")
            let originalAttributes = try fm.attributesOfItem(atPath: complex.manifest.path)
            try complexSource.replacingOccurrences(of: "before", with: "BEFORE").write(to: complex.manifest, atomically: false, encoding: .utf8)
            try fm.setAttributes([.modificationDate: originalAttributes[.modificationDate]!], ofItemAtPath: complex.manifest.path)
            rejects("same-length Ruby edit invalidates reviewed source even with restored timestamp") {
                try complexService.uninstall(complexPlan, scriptReviewConfirmed: true, onOutput: { _ in }, completion: { _ in })
            }

            let scriptPath = root.appendingPathComponent("uninstall-fixture.sh")
            let scriptSource = "#!/bin/sh\nprintf 'fixture only\\n'\n"
            try scriptSource.write(to: scriptPath, atomically: true, encoding: .utf8)
            let scripted = try fixture(at: root.appendingPathComponent("scripted"), extra: [["uninstall": [["script": ["executable": scriptPath.path, "args": ["--fixture"], "sudo": false]]]]])
            let scriptService = scripted.service(), scriptPlan = try plan(scripted, service: scriptService)
            check(scriptPlan.canExecute && scriptPlan.scriptReviewRequired && !scriptPlan.requiresAdministrator, "declarative non-sudo script supported with review")
            check(scriptPlan.scriptReviewSource?.contains(scriptSource) == true && scriptPlan.preview.contains("--fixture"), "external text script fully displayed with exact args")
            rejects("external script requires explicit review confirmation") {
                try scriptService.uninstall(scriptPlan, onOutput: { _ in }, completion: { _ in })
            }
            var scriptOutcome: MoleCommandResult?
            try scriptService.uninstall(scriptPlan, scriptReviewConfirmed: true, onOutput: { _ in }, completion: { scriptOutcome = $0 })
            check(wait { scriptOutcome != nil } && scriptOutcome?.exitCode == 0, "confirmed unchanged script reaches guarded fake brew")
            try (scriptSource + "# changed\n").write(to: scriptPath, atomically: true, encoding: .utf8)
            rejects("external script changes invalidate confirmation before execution") {
                try scriptService.uninstall(scriptPlan, scriptReviewConfirmed: true, onOutput: { _ in }, completion: { _ in })
            }
            try fm.removeItem(at: scriptPath)
            check(try !plan(scripted).canExecute, "missing external source cannot be authorized")

            let idFixture = try fixture(at: root.appendingPathComponent("sudo-binary"), extra: [["uninstall": [["script": ["executable": "/usr/bin/id", "args": ["-u"], "sudo": true]]]]])
            let idPlan = try plan(idFixture)
            check(idPlan.canExecute && idPlan.scriptReviewRequired && idPlan.requiresAdministrator && idPlan.preview.contains("二进制程序"), "fixed id -u administrator fixture discloses hashed binary and args")

            let interpreter = try fixture(at: root.appendingPathComponent("interpreter"), extra: [["uninstall": [["script": ["executable": "/bin/sh", "args": [scriptPath.path]]]]]])
            try scriptSource.write(to: scriptPath, atomically: true, encoding: .utf8)
            check(try plan(interpreter).scriptReviewSource?.contains(scriptSource) == true, "interpreter source argument is read and bound")

            let sudo = try fixture(at: root.appendingPathComponent("sudo"), extra: [["uninstall": [["launchctl": "local.mac-care.fixture", "delete": root.appendingPathComponent("fixture-helper").path, "pkgutil": "local.mac-care.fixture.pkg"]]]])
            let sudoPlan = try plan(sudo)
            check(sudoPlan.canExecute && sudoPlan.requiresAdministrator, "declarative sudo uninstall remains supported")
            check(sudoPlan.preview.contains("pkgutil") && sudoPlan.preview.contains("停止后台服务") && sudoPlan.preview.contains("fixture-helper"), "sudo hooks fully disclosed")

            let broad = try fixture(at: root.appendingPathComponent("broad"), extra: [["uninstall": [["delete": "/Applications"]]]])
            check(try !plan(broad).canExecute, "broad deletion root rejected")
            let unknown = try fixture(at: root.appendingPathComponent("unknown"), extra: [["future_action": ["x"]]])
            check(try !plan(unknown).canExecute, "unknown artifacts are not hidden")

            let invalidStamp = try fixture(at: root.appendingPathComponent("invalid-stamp"))
            let stampVersion = invalidStamp.manifest.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try fm.createDirectory(at: stampVersion.appendingPathComponent("zzzz-newer-unrecognized"), withIntermediateDirectories: false)
            rejects("unexpected newer metadata cannot be ignored to review an older recipe") { _ = try plan(invalidStamp) }

            let changed = try fixture(at: root.appendingPathComponent("changed"))
            let changedService = changed.service(), changedPlan = try plan(changed, service: changedService)
            var receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: changed.receipt)) as! [String: Any]
            receipt["uninstall_artifacts"] = [["app": ["Fixture.app"]], ["uninstall": [["quit": "local.mac-care.brew-fixture"]]]]
            try json(receipt, to: changed.receipt)
            rejects("changed receipt invalidates preview before launch") { try changedService.uninstall(changedPlan, onOutput: { _ in }, completion: { _ in }) }
            check(!fm.fileExists(atPath: changed.brew.appendingPathExtension("invocation.json").path), "invalid plan never invokes uninstall")

            var asyncPlan: BrewUninstallPlan?, prepareError: Error?
            try service.prepare(appPath: normal.app.path, bundleID: "local.mac-care.brew-fixture", onOutput: { _ in
                check(Thread.isMainThread, "prepare callback on main thread")
            }, completion: { result in
                switch result { case .success(let p): asyncPlan = p; case .failure(let e): prepareError = e }
            })
            check(wait { asyncPlan != nil || prepareError != nil }, "file-only inventory completes")
            if let prepareError { throw prepareError }
            guard let asyncPlan else { throw BrewServiceError.unavailable("fixture inventory timeout") }
            check(!fm.fileExists(atPath: normal.brew.appendingPathExtension("inventory-invoked").path), "preparing never invokes brew info or evaluates Ruby")
            var outcome: MoleCommandResult?
            try service.uninstall(asyncPlan, onOutput: { _ in }, completion: { outcome = $0 })
            check(wait { outcome != nil }, "guardian fake uninstall completes")
            check(outcome?.exitCode == 0 && outcome?.cancelled == false, "fake uninstall successful")
            let invocation = try JSONSerialization.jsonObject(with: Data(contentsOf: normal.brew.appendingPathExtension("invocation.json"))) as! [String: Any]
            check(invocation["arguments"] as? [String] == ["uninstall", "--cask", "test-cask"], "only exact cask uninstall argv")
            check(["no_autoremove", "no_auto_update", "no_analytics", "no_env_hints"].allSatisfy { invocation[$0] as? String == "1" }, "all four safe Homebrew flags reach guarded child")
            check(fm.fileExists(atPath: normal.app.path), "tests never delete even fixture app")

            let classified = try appPaths(service).get()
            check(classified == [normal.app.path], "source classification uses custom appdir installed snapshot, not current inventory targets")
            var cancelledResult: Result<Set<String>, Error>?
            try service.installedAppPaths { cancelledResult = $0 }
            service.cancel()
            check(wait { cancelledResult != nil }, "file inventory cancellation completes")
            if case .failure = cancelledResult { check(true, "cancelled inventory never reports success") }
            else { check(false, "cancelled inventory never reports success") }
            let saved = normal.root.appendingPathComponent("saved-cask")
            try fm.moveItem(at: normal.room.appendingPathComponent("test-cask"), to: saved)
            check(try appPaths(service).get().isEmpty, "no installed casks returns empty success")
            try fm.moveItem(at: saved, to: normal.room.appendingPathComponent("test-cask"))
            try fm.createDirectory(at: normal.room.appendingPathComponent("broken-cask"), withIntermediateDirectories: false)
            switch try appPaths(service) {
            case .success: check(false, "one broken cask must prevent partial source success")
            case .failure(let error):
                check(error.localizedDescription.contains("broken-cask") && error.localizedDescription.contains("不能把未识别条目视为普通应用"), "one broken cask fails closed with exact token")
            }
        } catch { failures += 1; print("FAIL unexpected error: \(error.localizedDescription)") }
        print("Brew service fixture tests: \(failures == 0 ? "PASS" : "FAIL"), failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
