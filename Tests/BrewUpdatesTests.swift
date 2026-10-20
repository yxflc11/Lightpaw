// Fixture-only mutation tests. --local-inventory is a receipt-only real probe.
import AppKit
import CryptoKit
import Darwin
import Foundation

@main
enum BrewUpdatesTests {
    static let fm = FileManager.default
    static var failures = 0
    static var guardian: URL!
    static var executable: URL { URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL }
    struct Fixture {
        let root: URL, brew: URL, room: URL, prefix: URL, app: URL, receipt: URL, manifest: URL
        var record: [String: Any]
        func service() -> BrewUpdates { BrewUpdates(brewURL: brew, caskroomURL: room, prefixURL: prefix, homeURL: root, guardianURL: guardian) }
        func save() throws { try json(["formulae": [], "casks": [record]], to: brew.appendingPathExtension("inventory.json")) }
        func mode(_ name: String) throws { try name.write(to: brew.appendingPathExtension("mode"), atomically: true, encoding: .utf8) }
        func calls() -> [[String: Any]] {
            guard let data = try? String(contentsOf: brew.appendingPathExtension("calls"), encoding: .utf8) else { return [] }
            return data.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
    }
    static func json(_ value: Any, to url: URL) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url) }
    static func fixture(_ root: URL, token: String = "fixture-update", id: String = "local.lightpaw.fixture-update") throws -> Fixture {
        let brew = root.appendingPathComponent("brew"), room = root.appendingPathComponent("Caskroom"), prefix = root.appendingPathComponent("prefix")
        let apps = root.appendingPathComponent("Applications"), app = apps.appendingPathComponent("Fixture.app")
        let metadata = room.appendingPathComponent(token + "/.metadata"), manifests = metadata.appendingPathComponent("1.0/20261019000000.001/Casks")
        try fm.createDirectory(at: manifests, withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": "Fixture", "CFBundleVersion": "1.0", "CFBundleShortVersionString": "1.0"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try fm.createSymbolicLink(at: brew, withDestinationURL: executable)
        let receipt = metadata.appendingPathComponent("INSTALL_RECEIPT.json"), manifest = manifests.appendingPathComponent(token + ".json")
        let artifacts: [[String: Any]] = [["app": ["Fixture.app"]]]
        try json(["source": ["version": "1.0", "tap": "homebrew/cask"], "uninstall_flight_blocks": false, "uninstall_artifacts": artifacts], to: receipt)
        try json(["default": ["appdir": apps.path], "env": [:], "explicit": [:]], to: metadata.appendingPathComponent("config.json"))
        try json([:], to: manifest)
        let record: [String: Any] = ["token": token, "full_token": token, "name": ["Fixture"], "installed": "1.0", "version": "1.1", "tap": "homebrew/cask",
                                     "pinned": false, "disabled": false, "outdated": true, "auto_updates": NSNull(), "depends_on": ["macos": [:]],
                                     "artifacts": [["app": ["Fixture.app"], "target": app.path]], "ruby_source_path": "Casks/f/" + token + ".rb",
                                     "ruby_source_checksum": ["sha256": String(repeating: "a", count: 64)]]
        let result = Fixture(root: root, brew: brew, room: room, prefix: prefix, app: app, receipt: receipt, manifest: manifest, record: record)
        try result.save(); return result
    }
    static func check(_ condition: Bool, _ name: String) { if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") } }
    static func rejects(_ name: String, _ action: () throws -> Void) { do { try action(); check(false, name) } catch { check(true, name) } }
    static func wait(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(20)
        while !condition() && Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return condition()
    }
    static func loaded(_ service: BrewUpdates) throws -> BrewUpdateSnapshot {
        var result: Result<BrewUpdateSnapshot, Error>?
        try service.loadInstalled { result = $0 }
        guard wait({ result != nil }) else { throw BrewUpdateError.unavailable("load timeout") }
        return try result!.get()
    }
    static func checked(_ service: BrewUpdates) throws -> BrewUpdateSnapshot {
        var result: Result<BrewUpdateSnapshot, Error>?
        try service.checkForUpdates(onOutput: { _ in }) { result = $0 }
        guard wait({ result != nil }) else { service.cancel(); throw BrewUpdateError.unavailable("check timeout") }
        check(Thread.isMainThread, "completion reaches main thread")
        return try result!.get()
    }
    static func prepared(_ service: BrewUpdates, token: String = "fixture-update", version: String = "1.1") throws -> BrewUpdatePlan {
        var result: Result<BrewUpdatePlan, Error>?
        try service.prepare(token: token, expectedVersion: version, onOutput: { _ in }) { result = $0 }
        guard wait({ result != nil }) else { throw BrewUpdateError.unavailable("prepare timeout") }
        return try result!.get()
    }
    static func upgraded(_ service: BrewUpdates, _ plan: BrewUpdatePlan) throws -> MoleCommandResult {
        var result: MoleCommandResult?
        try service.upgrade(plan, onOutput: { _ in }) { result = $0 }
        guard wait({ result != nil }) else { service.cancel(); throw BrewUpdateError.unavailable("upgrade timeout") }
        return result!
    }
    static func fakeBrew() throws -> Bool {
        guard executable.lastPathComponent == "brew" else { return false }
        let args = Array(CommandLine.arguments.dropFirst()), mode = (try? String(contentsOf: executable.appendingPathExtension("mode"), encoding: .utf8)) ?? ""
        let call: [String: Any] = ["arguments": args, "environment": ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("HOMEBREW_") }]
        let line = String(data: try JSONSerialization.data(withJSONObject: call, options: [.sortedKeys]), encoding: .utf8)! + "\n"
        let calls = executable.appendingPathExtension("calls")
        var previous = (try? Data(contentsOf: calls)) ?? Data(); previous.append(Data(line.utf8)); try previous.write(to: calls)
        if mode == "sleep" { sleep(30) }
        if args == ["update"] {
            if mode == "refresh-fail" { fputs("metadata refresh failed\n", stderr); exit(7) }
            print("fixture metadata refreshed"); return true
        }
        if args.starts(with: ["info", "--cask", "--json=v2"]) {
            if mode == "json-noise" { print("diagnostic before JSON") }
            print(try String(contentsOf: executable.appendingPathExtension("inventory.json"), encoding: .utf8))
            return true
        }
        if args == ["upgrade", "--cask", "fixture-update"] {
            if mode == "upgrade-fail" { fputs("fixture upgrade failed\n", stderr); exit(9) }
            if mode == "upgrade-sleep" { print("fixture-upgrade-wait"); sleep(30) }
            if mode != "upgrade-noop" {
                let metadata = executable.deletingLastPathComponent().appendingPathComponent("Caskroom/fixture-update/.metadata")
                let receipt = metadata.appendingPathComponent("INSTALL_RECEIPT.json")
                var data = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as! [String: Any]
                var source = data["source"] as! [String: Any]; source["version"] = "1.1"; data["source"] = source
                try json(data, to: receipt)
                let folder = metadata.appendingPathComponent("1.1/20261019000001.001/Casks")
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try json([:], to: folder.appendingPathComponent("fixture-update.json"))
            }
            print("fixture upgrade successful (only temporary receipts changed)"); return true
        }
        fputs("unexpected command\n", stderr); exit(93)
    }
    static func main() {
        setbuf(stdout, nil)
        do { if try fakeBrew() { return } } catch { fputs(error.localizedDescription + "\n", stderr); exit(2) }
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--local-inventory", args.count == 2 {
            do {
                guardian = URL(fileURLWithPath: args[1])
                let snapshot = try loaded(BrewUpdates(guardianURL: guardian))
                for item in snapshot.items { print("\(item.token) | \(item.installedVersion) | \(item.bundleVersion ?? "—") | \(item.status.rawValue) | \(item.appPaths.joined(separator: ","))") }
                print("metadataFresh=\(snapshot.isFresh), casks=\(snapshot.items.count)")
                return
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        guard args.count == 1 else { print("Usage: BrewUpdatesTests /absolute/MoleGuardian"); exit(2) }
        guardian = URL(fileURLWithPath: args[0])
        let root = fm.temporaryDirectory.appendingPathComponent("lightpaw-brew-updates-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        do {
            let normal = try fixture(root.appendingPathComponent("normal")), service = normal.service()
            let local = try loaded(service)
            check(local.items.count == 1 && local.items[0].appPaths == [normal.app.path], "local receipt binds exact application")
            check(!local.isFresh && local.items[0].availableVersion == nil && local.items[0].status == .notChecked, "local inventory never claims a fresh version")
            check(normal.calls().isEmpty, "listing installed casks never invokes brew or Ruby")
            rejects("cannot prepare before explicit refresh") { _ = try prepared(service) }
            let initial = try checked(service)
            check(initial.isFresh && initial.items[0].canPrepare && initial.items[0].availableVersion == "1.1", "successful metadata refresh enables exact version")
            let calls = normal.calls().compactMap { $0["arguments"] as? [String] }
            check(calls == [["update"], ["info", "--cask", "--json=v2", "homebrew/cask/fixture-update"]], "check uses qualified current recipe after refresh")
            let plan = try prepared(service)
            check(plan.canExecute && plan.targetVersion == "1.1" && plan.preview.contains(normal.app.path), "preview binds selected application and target version")
            rejects("wrong expected target version rejected") { _ = try prepared(service, version: "8.0") }
            rejects("foreign service cannot execute plan") { _ = try upgraded(normal.service(), plan) }
            let result = try upgraded(service, plan)
            check(result.exitCode == 0 && !result.cancelled, "one selected cask upgrade succeeds through guardian")
            let upgrade = normal.calls().last!
            check(upgrade["arguments"] as? [String] == ["upgrade", "--cask", "fixture-update"], "upgrade uses exact cask-only argv")
            let environment = upgrade["environment"] as? [String: String] ?? [:]
            check(["HOMEBREW_NO_AUTOREMOVE", "HOMEBREW_NO_AUTO_UPDATE", "HOMEBREW_NO_ANALYTICS", "HOMEBREW_NO_ENV_HINTS", "HOMEBREW_NO_INSTALL_CLEANUP"].allSatisfy { environment[$0] == "1" }, "guarded child disables autoremove and cleanup")
            check(fm.fileExists(atPath: normal.app.path), "fixture never alters application")
            rejects("successful plan cannot be replayed") { _ = try upgraded(service, plan) }

            let noop = try fixture(root.appendingPathComponent("noop")), nooping = noop.service()
            _ = try checked(nooping); let noopPlan = try prepared(nooping); try noop.mode("upgrade-noop")
            check(try upgraded(nooping, noopPlan).exitCode != 0, "zero exit without target receipt is not success")

            let upgradeFailure = try fixture(root.appendingPathComponent("upgrade-failure")), failingUpgrade = upgradeFailure.service()
            _ = try checked(failingUpgrade); let failedPlan = try prepared(failingUpgrade); try upgradeFailure.mode("upgrade-fail")
            check(try upgraded(failingUpgrade, failedPlan).exitCode == 9, "nonzero upgrade exit is preserved")
            let upgradeCancel = try fixture(root.appendingPathComponent("upgrade-cancel")), cancellingUpgrade = upgradeCancel.service()
            _ = try checked(cancellingUpgrade); let cancelPlan = try prepared(cancellingUpgrade); try upgradeCancel.mode("upgrade-sleep")
            var cancelledUpgrade: MoleCommandResult?
            try cancellingUpgrade.upgrade(cancelPlan, onOutput: { text in
                if text.contains("fixture-upgrade-wait") { cancellingUpgrade.cancel() }
            }) { cancelledUpgrade = $0 }
            check(wait { cancelledUpgrade != nil }, "running upgrade cancels through guardian")
            check(cancelledUpgrade?.cancelled == true && cancelledUpgrade?.exitCode != 0, "cancelled upgrade cannot report success")

            var tapped = try fixture(root.appendingPathComponent("local-tap")); let tap = "lightpaw/fixtures"
            let recipe = tapped.prefix.appendingPathComponent("Library/Taps/lightpaw/homebrew-fixtures/Casks/fixture-update.rb")
            try fm.createDirectory(at: recipe.deletingLastPathComponent(), withIntermediateDirectories: true)
            let ruby = "cask \"fixture-update\" do\n  version \"1.1\"\n  sha256 :no_check\n  url \"file:///private/tmp/fixture.zip\"\n  name \"Fixture\"\n  app \"Fixture.app\"\nend\n"
            try ruby.write(to: recipe, atomically: true, encoding: .utf8)
            var tapReceipt = try JSONSerialization.jsonObject(with: Data(contentsOf: tapped.receipt)) as! [String: Any]
            tapReceipt["source"] = ["version": "1.0", "tap": tap, "path": recipe.path]; try json(tapReceipt, to: tapped.receipt)
            tapped.record["tap"] = tap; tapped.record["ruby_source_path"] = "Casks/fixture-update.rb"
            tapped.record["ruby_source_checksum"] = ["sha256": SHA256.hash(data: Data(ruby.utf8)).map { String(format: "%02x", $0) }.joined()]
            try tapped.save(); let tapService = tapped.service()
            check(try checked(tapService).items[0].canPrepare, "static local tap recipe is supported")
            check(try upgraded(tapService, prepared(tapService)).exitCode == 0, "local tap source remains bound across upgrade")

            for (name, value) in [("pinned", true), ("disabled", true), ("outdated", false)] {
                var f = try fixture(root.appendingPathComponent(name)); f.record[name] = value; try f.save()
                let item = try checked(f.service()).items[0]
                check(!item.canPrepare, "\(name) status prevents upgrade")
            }
            var latest = try fixture(root.appendingPathComponent("latest")); latest.record["version"] = "latest"; try latest.save()
            check(try checked(latest.service()).items[0].status == .latest, "latest is indeterminate, never current")
            var auto = try fixture(root.appendingPathComponent("automatic")); auto.record["auto_updates"] = true; auto.record["outdated"] = false; try auto.save()
            check(try checked(auto.service()).items[0].status == .automaticUpdates, "self updating apps retain distinct status")
            let protected = try fixture(root.appendingPathComponent("protected"), id: "com.openai.codex")
            check(try checked(protected.service()).items[0].status == .protectedApp, "Codex bundle identity is protected")
            var deps = try fixture(root.appendingPathComponent("dependencies")); deps.record["depends_on"] = ["formula": ["libexample"], "cask": ["other-app"]]; try deps.save()
            let dependencyItem = try checked(deps.service()).items[0]
            check(!dependencyItem.canPrepare && dependencyItem.unsupportedReason?.contains("libexample") == true && dependencyItem.unsupportedReason?.contains("other-app") == true, "implicit dependencies are named and blocked")

            var changed = try fixture(root.appendingPathComponent("changed")); let changing = changed.service()
            _ = try checked(changing); let confirmed = try prepared(changing)
            changed.record["version"] = "1.2"; try changed.save()
            check(try upgraded(changing, confirmed).exitCode != 0, "version change after confirmation blocks upgrade")
            check(!changed.calls().contains { ($0["arguments"] as? [String])?.first == "upgrade" }, "changed plan never starts mutation")
            var sourceChanged = try fixture(root.appendingPathComponent("source-changed")); let changingSource = sourceChanged.service()
            _ = try checked(changingSource); let sourcePlan = try prepared(changingSource)
            sourceChanged.record["ruby_source_checksum"] = ["sha256": String(repeating: "b", count: 64)]; try sourceChanged.save()
            check(try upgraded(changingSource, sourcePlan).exitCode != 0, "recipe source change invalidates confirmation")
            let receiptChanged = try fixture(root.appendingPathComponent("receipt-changed")), changingReceipt = receiptChanged.service()
            _ = try checked(changingReceipt); let receiptPlan = try prepared(changingReceipt)
            var receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptChanged.receipt)) as! [String: Any]
            receipt["source"] = ["version": "1.0", "tap": "other/tap"]; try json(receipt, to: receiptChanged.receipt)
            check(try upgraded(changingReceipt, receiptPlan).exitCode != 0, "receipt source substitution blocks upgrade")

            let failed = try fixture(root.appendingPathComponent("failed")), failing = failed.service()
            _ = try checked(failing); let previous = try prepared(failing)
            try failed.mode("refresh-fail")
            rejects("refresh failure does not reuse cached success") { _ = try checked(failing) }
            rejects("refresh failure invalidates prior confirmation") { _ = try upgraded(failing, previous) }
            try failed.mode("json-noise")
            rejects("diagnostic mixed with JSON is not accepted") { _ = try checked(failing) }
            try failed.mode("sleep")
            var cancellation: Result<BrewUpdateSnapshot, Error>?
            try failing.checkForUpdates(onOutput: { _ in }) { cancellation = $0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { failing.cancel() }
            check(wait { cancellation != nil }, "cancel waits for guardian completion")
            if case .failure? = cancellation { check(true, "cancel is reported as failure without a fresh snapshot") } else { check(false, "cancel is reported as failure without a fresh snapshot") }
            check(!failing.isRunning, "cancel releases service for next operation")

            for token in ["--all", "../bad", "a/b", "a\nupdate", "bad;echo", ""] {
                var record = normal.record; record["token"] = token
                rejects("unsafe token rejected \(token.debugDescription)") { _ = try BrewUpdates.inventory(JSONSerialization.data(withJSONObject: ["formulae": [], "casks": [record]])) }
            }
            rejects("duplicate cask rejected") { _ = try BrewUpdates.inventory(JSONSerialization.data(withJSONObject: ["formulae": [], "casks": [normal.record, normal.record]])) }
            rejects("formula result rejected") { _ = try BrewUpdates.inventory(JSONSerialization.data(withJSONObject: ["formulae": [["name": "formula"]], "casks": [normal.record]])) }
            var numeric = normal.record; numeric["disabled"] = 0
            rejects("numeric boolean rejected") { _ = try BrewUpdates.inventory(JSONSerialization.data(withJSONObject: ["formulae": [], "casks": [numeric]])) }
            var missing = normal.record; missing.removeValue(forKey: "outdated")
            rejects("missing status cannot become current") { _ = try BrewUpdates.inventory(JSONSerialization.data(withJSONObject: ["formulae": [], "casks": [missing]])) }
            let now = Date()
            check(!BrewUpdates.confirmationIsFresh(created: now.addingTimeInterval(-300), now: now) && !BrewUpdates.confirmationIsFresh(created: now.addingTimeInterval(1), now: now), "expired and future confirmations rejected")
            check(BrewUpdates.confirmationIsFresh(created: now.addingTimeInterval(-299), now: now), "recent confirmation accepted")
        } catch { failures += 1; print("FAIL unexpected error: \(error.localizedDescription)") }
        print("Brew updates fixture tests: \(failures == 0 ? "PASS" : "FAIL"), failures=\(failures)")
        try? fm.removeItem(at: root) // exit() does not unwind Swift defer blocks.
        exit(failures == 0 ? 0 : 1)
    }
}
