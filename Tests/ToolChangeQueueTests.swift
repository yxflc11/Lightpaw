// Fixture-only. No live config, process, signal or reload is ever used.
import Foundation

private enum FixtureError: Error { case failure }

private final class Fixture {
    var values = ["mcp:notes": true, "mcp:docs": true, "plugin:palette@fixture": false]
    var revision = 1
    var fingerprint: String { String(format: "%064x", revision) }
    var data: Data?
    var saveFails = false
    var readFails = false
    var writeFails = false
    var badReadFingerprint = false
    var badWriteResult = false
    var activity = ToolChangeActivity.running
    var activities: [ToolChangeActivity] = []
    var clock = Date(timeIntervalSince1970: 100)
    var reads = 0, activityChecks = 0, saves = 0
    var writes: [String] = []
    var afterRead: (() -> Void)?
    var afterWrite: (() -> Void)?

    func makeQueue() throws -> ToolChangeQueue {
        let runtime = ToolChangeRuntime(read: { [self] key in
            reads += 1
            guard !readFails, let enabled = values[key] else { throw FixtureError.failure }
            let state = ToolConfigurationState(enabled: enabled, fingerprint: badReadFingerprint ? "secret" : fingerprint)
            afterRead?()
            return state
        }, write: { [self] key, desired, expected in
            guard !writeFails, values[key] != nil, expected == fingerprint else { throw FixtureError.failure }
            // Production setter also validates its exact expected source bytes.
            values[key] = desired; revision += 1; writes.append(key)
            let state = ToolConfigurationState(enabled: badWriteResult ? !desired : desired, fingerprint: fingerprint)
            afterWrite?()
            return state
        }, activity: { [self] in
            activityChecks += 1
            return activities.isEmpty ? activity : activities.removeFirst()
        }, now: { [self] in clock })
        return try ToolChangeQueue(runtime: runtime, load: { [self] in data }, save: { [self] next in
            guard !saveFails else { throw FixtureError.failure }
            data = next; saves += 1
        })
    }

    func stoppedTwice(_ queue: ToolChangeQueue) throws -> [String] {
        activity = .stopped
        _ = try queue.applyWhenStopped()
        clock += 2
        return try queue.applyWhenStopped()
    }
}

@main enum ToolChangeQueueTests {
    static var failures = 0, checks = 0
    static func check(_ good: Bool, _ name: String) {
        checks += 1; print("\(good ? "PASS" : "FAIL") \(name)")
        if !good { failures += 1 }
    }
    static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body(); check(false, name) } catch { check(true, name) }
    }
    static func run(_ name: String, _ body: () throws -> Void) {
        do { try body() } catch { check(false, name + " threw " + String(describing: type(of: error))) }
    }

    static func main() {
        run("running task") {
            let f = Fixture(), q = try f.makeQueue()
            try q.request(key: "mcp:notes", desired: false)
            check(q.changes.count == 1 && q.changes[0].status == .waiting && f.data != nil, "request persists one waiting intention")
            for _ in 0..<4 { f.clock += 10; _ = try q.applyWhenStopped() }
            check(f.writes.isEmpty && f.values["mcp:notes"] == true, "running tasks never trigger config writes")
            check(f.reads == 1, "running ticks do not read or mutate configuration")
            try q.request(key: "mcp:notes", desired: true)
            check(q.changes.isEmpty && f.writes.isEmpty, "returning toggle to unchanged baseline cancels intention")
            let checks = f.activityChecks; _ = try q.applyWhenStopped()
            check(f.activityChecks == checks, "empty queue does no process polling")
        }
        run("time gate") {
            let f = Fixture(), q = try f.makeQueue()
            try q.request(key: "mcp:notes", desired: false)
            f.activity = .stopped
            _ = try q.applyWhenStopped()
            check(f.writes.isEmpty, "first stopped observation never writes")
            f.clock += 1.99; _ = try q.applyWhenStopped()
            check(f.writes.isEmpty, "two stopped observations below two seconds do not write")
            f.clock += 0.01
            check(try q.applyWhenStopped() == ["mcp:notes"] && q.changes.isEmpty, "two seconds of stopped evidence applies requested change")
            check(f.values["mcp:notes"] == false, "disable changes only the selected tool")
        }
        run("unknown and revived") {
            let f = Fixture(), q = try f.makeQueue()
            try q.request(key: "mcp:notes", desired: false)
            f.activity = .stopped; _ = try q.applyWhenStopped(); f.clock += 10
            f.activity = .unknown; _ = try q.applyWhenStopped()
            f.activity = .stopped; _ = try q.applyWhenStopped()
            check(f.writes.isEmpty, "unknown process state discards previous stopped evidence")
            f.clock += 2; f.activities = [.stopped, .running]
            _ = try q.applyWhenStopped()
            check(f.writes.isEmpty && q.changes.count == 1, "revival before per-item read prevents write")
            _ = try q.applyWhenStopped()
            check(f.writes.isEmpty, "revival resets the two-observation gate")
            f.clock += 2; f.afterRead = { f.activity = .running }
            _ = try q.applyWhenStopped()
            check(f.writes.isEmpty, "revival while configuration is read prevents write")
        }
        run("backward time") {
            let f = Fixture(), q = try f.makeQueue()
            try q.request(key: "mcp:notes", desired: false)
            f.activity = .stopped; _ = try q.applyWhenStopped(); f.clock -= 10
            _ = try q.applyWhenStopped(); f.clock += 1; _ = try q.applyWhenStopped()
            check(f.writes.isEmpty, "clock moving backwards resets stopped evidence")
            f.clock += 1; _ = try q.applyWhenStopped()
            check(f.writes.count == 1, "clock gate recovers with fresh elapsed evidence")
        }
        run("multi-item shared configuration") {
            let f = Fixture(), q = try f.makeQueue()
            try q.request(key: "mcp:notes", desired: false)
            try q.request(key: "mcp:docs", desired: false)
            try q.request(key: "plugin:palette@fixture", desired: true)
            let results = try f.stoppedTwice(q)
            check(results == ["mcp:notes", "mcp:docs", "plugin:palette@fixture"], "own writes advance fingerprints for all remaining shared-config intentions")
            check(q.changes.isEmpty && f.values == ["mcp:notes": false, "mcp:docs": false, "plugin:palette@fixture": true], "disable and enable apply independently without losing another item")
            check(try f.makeQueue().changes.isEmpty, "successful queue removals persist across relaunch")
        }
        run("revival between items") {
            let f = Fixture(), q = try f.makeQueue()
            try q.request(key: "mcp:notes", desired: false); try q.request(key: "mcp:docs", desired: false)
            f.afterWrite = { f.activity = .running }
            _ = try f.stoppedTwice(q)
            check(f.writes == ["mcp:notes"] && q.changes.map(\.key) == ["mcp:docs"], "Codex restart between items aborts remaining writes")
            check(q.changes.first?.fingerprint == f.fingerprint, "aborted remaining intention keeps own-write fingerprint update")
            f.afterWrite = nil
            check(try f.stoppedTwice(q) == ["mcp:docs"], "remaining item can apply after a new stopped gate")
        }
        run("external config conflict") {
            let f = Fixture(), q = try f.makeQueue()
            try q.request(key: "mcp:notes", desired: false); f.revision += 1
            _ = try f.stoppedTwice(q)
            check(f.writes.isEmpty && q.changes.first?.status == .conflict, "external config bytes mark conflict without write")
            rejects("ordinary toggle cannot silently rebase external conflict") { try q.request(key: "mcp:notes", desired: false) }
            try q.request(key: "mcp:notes", desired: false, reconfirm: true)
            check(q.changes.first?.status == .waiting && q.changes.first?.fingerprint == f.fingerprint, "explicit reconfirm accepts reviewed fresh baseline")
            _ = try f.stoppedTwice(q)
            check(f.writes == ["mcp:notes"], "reconfirmed intention still needs the stopped gate")
        }
        run("external Boolean change") {
            let f = Fixture(), q = try f.makeQueue()
            try q.request(key: "mcp:notes", desired: false)
            f.values["mcp:notes"] = false // Even a faulty unchanged digest cannot bypass the Boolean check.
            _ = try f.stoppedTwice(q)
            check(f.writes.isEmpty && q.changes.first?.status == .conflict, "changed baseline Boolean is independently detected")
            try q.cancel(key: "mcp:notes")
            check(q.changes.isEmpty && f.values["mcp:notes"] == false, "cancelling a conflict leaves external config unchanged")
        }
        run("external change immediately after own write") {
            let f = Fixture(), q = try f.makeQueue()
            try q.request(key: "mcp:notes", desired: false); try q.request(key: "mcp:docs", desired: false)
            f.afterWrite = { f.revision += 1 }
            _ = try f.stoppedTwice(q)
            check(f.writes == ["mcp:notes"] && q.changes.first?.status == .conflict, "external change after own write is not adopted by following item")
        }
        run("restart persistence") {
            let f = Fixture(), original = try f.makeQueue()
            try original.request(key: "mcp:notes", desired: false)
            f.activity = .stopped; _ = try original.applyWhenStopped(); f.clock += 20
            let relaunched = try f.makeQueue(); _ = try relaunched.applyWhenStopped()
            check(f.writes.isEmpty && relaunched.changes.count == 1, "relaunch restores intentions but never restores stopped evidence")
            f.clock += 2; _ = try relaunched.applyWhenStopped()
            check(f.writes.count == 1, "restored intention applies after fresh two-observation gate")
        }
        run("request persistence failure") {
            let f = Fixture(), q = try f.makeQueue(); f.saveFails = true
            rejects("failed save rejects reservation") { try q.request(key: "mcp:notes", desired: false) }
            check(q.changes.isEmpty && f.data == nil && f.writes.isEmpty, "failed reservation is not reported or applied from memory")
            f.saveFails = false; try q.request(key: "mcp:notes", desired: false); f.saveFails = true
            rejects("failed cancellation is reported") { try q.cancel(key: "mcp:notes") }
            check(q.changes.count == 1, "failed cancellation retains actual durable intention")
        }
        run("save failure after successful config write") {
            let f = Fixture(), q = try f.makeQueue()
            try q.request(key: "mcp:notes", desired: false); try q.request(key: "mcp:docs", desired: false)
            f.afterWrite = { f.saveFails = true }
            rejects("post-write queue save failure is reported") { _ = try f.stoppedTwice(q) }
            check(f.writes == ["mcp:notes"] && q.changes.map(\.key) == ["mcp:docs"] && q.persistenceNeedsRetry,
                  "post-write failure retains truthful memory and marks persistence retry")
            rejects("failed persistence retry blocks later config writes") { _ = try q.applyWhenStopped() }
            check(f.writes.count == 1, "unsaved progress does not trigger further writes")
            f.saveFails = false; f.afterWrite = nil
            let recovered = try f.makeQueue(); _ = try f.stoppedTwice(recovered)
            check(f.writes.count == 1 && recovered.changes.allSatisfy({ $0.status == .conflict }), "crash with stale disk intentions detects conflicts instead of repeating writes")
            _ = try q.applyWhenStopped()
            check(f.writes == ["mcp:notes", "mcp:docs"] && !q.persistenceNeedsRetry, "same-process retry makes actual progress durable before continuing")
        }
        run("read and write failure") {
            let f = Fixture(), q = try f.makeQueue()
            f.readFails = true
            rejects("unreadable configuration cannot be reserved") { try q.request(key: "mcp:notes", desired: false) }
            f.readFails = false; try q.request(key: "mcp:notes", desired: false); f.readFails = true
            _ = try f.stoppedTwice(q)
            check(q.changes.first?.status == .failed && f.writes.isEmpty, "apply read failure preserves a failed cancellable intention")
            f.readFails = false; f.writeFails = true; try q.request(key: "mcp:notes", desired: false)
            _ = try f.stoppedTwice(q)
            check(q.changes.first?.status == .failed && f.writes.isEmpty, "setter failure remains visible without automatic retry")
            let reads = f.reads; _ = try q.applyWhenStopped()
            check(f.reads == reads, "failed rows are not automatically retried")
            f.writeFails = false; try q.request(key: "mcp:notes", desired: false); _ = try f.stoppedTwice(q)
            check(f.writes.count == 1, "explicit retry can recover a failed unchanged configuration")
        }
        run("malformed runtime results") {
            let f = Fixture(), q = try f.makeQueue(); f.badReadFingerprint = true
            rejects("non-digest runtime fingerprint cannot leak into storage") { try q.request(key: "mcp:notes", desired: false) }
            check(f.data == nil, "invalid fingerprint is never persisted")
            f.badReadFingerprint = false; try q.request(key: "mcp:notes", desired: false); f.badWriteResult = true
            _ = try f.stoppedTwice(q)
            check(q.changes.first?.status == .failed, "invalid setter result cannot masquerade as successful application")
        }
        run("key validation") {
            let f = Fixture(), q = try f.makeQueue()
            for key in ["", "notes", "mcp:", "mcp:../notes", "mcp:notes\n", "mcp:笔记", "plugin:name", "plugin:a@@b", "plugin:a@", "plugin:@b", "plugin:a/b@c", "unknown:notes", "mcp:" + String(repeating: "x", count: 129)] {
                rejects("invalid key rejected before runtime read") { try q.request(key: key, desired: false) }
            }
            check(f.reads == 0 && f.data == nil, "key validation precedes runtime and storage")
            rejects("unknown but syntactically valid key cannot be reserved") { try q.request(key: "mcp:absent", desired: false) }
        }
        run("bounded storage") {
            let f = Fixture(), q = try f.makeQueue()
            for i in 0..<65 { f.values["mcp:item_\(i)"] = true }
            for i in 0..<64 { try q.request(key: "mcp:item_\(i)", desired: false) }
            rejects("item count bounded at 64") { try q.request(key: "mcp:item_64", desired: false) }
            check(q.changes.count == 64 && (f.data?.count ?? 0) < 128 * 1024, "maximum valid queue fits bounded payload")
            try q.request(key: "mcp:item_0", desired: true)
            check(q.changes.count == 63, "at capacity existing reservation may still be cancelled")
            let valid = f.data!
            var object = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
            object["version"] = 2; f.data = try JSONSerialization.data(withJSONObject: object)
            rejects("unknown persisted version rejected") { _ = try f.makeQueue() }
            object["version"] = 1
            var rows = object["changes"] as! [[String: Any]]; rows.append(rows[0]); object["changes"] = rows
            f.data = try JSONSerialization.data(withJSONObject: object)
            rejects("duplicate persisted key rejected") { _ = try f.makeQueue() }
            rows.removeLast(); rows[0]["key"] = "mcp:../bad"; object["changes"] = rows
            f.data = try JSONSerialization.data(withJSONObject: object)
            rejects("unsafe persisted key rejected") { _ = try f.makeQueue() }
            rows[0]["key"] = "mcp:item_1"; rows[0]["fingerprint"] = "not a digest"; object["changes"] = rows
            f.data = try JSONSerialization.data(withJSONObject: object)
            rejects("invalid persisted fingerprint rejected") { _ = try f.makeQueue() }
            f.data = Data(repeating: 0x20, count: 128 * 1024 + 1)
            rejects("oversized storage rejected before decoding") { _ = try f.makeQueue() }
            f.data = Data("bad json".utf8)
            rejects("corrupt storage fails closed") { _ = try f.makeQueue() }
            check(f.writes.isEmpty, "invalid storage never writes external configuration")
        }
        run("new request resets evidence") {
            let f = Fixture(), q = try f.makeQueue()
            try q.request(key: "mcp:notes", desired: false)
            f.activity = .stopped; _ = try q.applyWhenStopped(); f.clock += 20
            try q.request(key: "mcp:docs", desired: false); _ = try q.applyWhenStopped()
            check(f.writes.isEmpty, "new request cannot reuse stale stopped evidence")
        }
        print("\(checks - failures)/\(checks) checks passed")
        if failures != 0 { exit(1) }
    }
}
