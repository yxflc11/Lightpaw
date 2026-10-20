// Standalone integration tests. All deletions are confined to a newly created
// /private/tmp home. Does not invoke Mole or touch the actual user's caches.
// swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Models/SelectedCleanup.swift Tests/SelectedCleanupTests.swift -o .build/SelectedCleanupTests
import Foundation
import Darwin

@main
enum SelectedCleanupTests {
    static func main() throws {
        let fm = FileManager.default
        let home = "/private/tmp/selected-cleanup-tests-" + UUID().uuidString
        try fm.createDirectory(atPath: home + "/Library/Caches", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: home) }
        let engine = SelectedCleanup(home: home, activityCheck: { _, _ in nil })
        var count = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fputs("FAIL: \(message)\n", stderr); try? fm.removeItem(atPath: home); exit(1) }; count += 1
        }
        func file(_ relative: String, _ content: String = "fixture") throws -> String {
            let path = home + "/Library/Caches/" + relative
            try fm.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: URL(fileURLWithPath: path)); return path
        }
        func candidate(_ id: Int, _ path: String) -> CleanupCandidate {
            CleanupCandidate(id: id, path: path, section: "fixture", detail: "test only")
        }
        func run(_ engine: SelectedCleanup, _ plan: CleanupPlan, cancelImmediately: Bool = false) -> [CleanupResult] {
            var result: [CleanupResult]?
            engine.execute(plan, permanently: true, onProgress: { _ in
                expect(Thread.isMainThread, "progress uses main queue")
            }, completion: {
                expect(Thread.isMainThread, "completion uses main queue"); result = $0
            })
            if cancelImmediately { engine.cancel() }
            let deadline = Date().addingTimeInterval(20)
            while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            expect(result != nil, "execution finishes within bound")
            expect(!engine.isRunning, "running resets")
            return result ?? []
        }

        let chosen = try file("Exact/selected.txt")
        let retained = try file("Exact/unselected.txt")
        let sibling = try file("Exact-prefix/sibling.txt")
        var plan = try engine.prepare(candidates: [candidate(1, chosen), candidate(2, retained), candidate(3, sibling)], selectedIDs: [1])
        if plan.items.isEmpty { print("prepare diagnostics:", plan.skipped.map(\.message)) }
        expect(plan.items.count == 1 && plan.totalBytes == 7, "one exact file planned")
        var results = run(engine, plan)
        expect(results.count == 1 && results[0].status == .removed, "permanent exact item succeeds")
        expect(!fm.fileExists(atPath: chosen) && fm.fileExists(atPath: retained) && fm.fileExists(atPath: sibling), "unselected and prefix sibling preserved")

        let child = try file("Parent/child.txt")
        let parent = URL(fileURLWithPath: child).deletingLastPathComponent().path
        plan = try engine.prepare(candidates: [candidate(4, parent), candidate(5, child)], selectedIDs: [4, 5])
        expect(plan.items.count == 1 && plan.skipped.isEmpty && plan.items[0].id == 4, "selected parent-child collapsed")
        results = run(engine, plan)
        expect(results.first?.status == .removed && !fm.fileExists(atPath: parent), "prepared parent tree removed")
        let unselectedChild = try file("Partial/child.txt")
        let partialParent = URL(fileURLWithPath: unselectedChild).deletingLastPathComponent().path
        plan = try engine.prepare(candidates: [candidate(6, partialParent), candidate(7, unselectedChild)], selectedIDs: [6])
        expect(plan.items.isEmpty && plan.skipped.count == 1 && fm.fileExists(atPath: unselectedChild), "unselected descendant blocks parent")

        let target = try file("Kept/target.txt")
        let link = home + "/Library/Caches/leaf-link"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        plan = try engine.prepare(candidates: [candidate(8, link)], selectedIDs: [8])
        expect(plan.items.isEmpty && plan.skipped.count == 1 && fm.fileExists(atPath: target), "leaf symlink refused")
        let ancestorLink = home + "/Library/Caches/ancestor-link"
        try fm.createSymbolicLink(atPath: ancestorLink, withDestinationPath: home + "/Library/Caches/Kept")
        plan = try engine.prepare(candidates: [candidate(9, ancestorLink + "/target.txt")], selectedIDs: [9])
        expect(plan.items.isEmpty && plan.skipped.count == 1, "ancestor symlink refused")
        let nested = try file("Nested/kept.txt")
        try fm.createSymbolicLink(atPath: home + "/Library/Caches/Nested/link", withDestinationPath: target)
        plan = try engine.prepare(candidates: [candidate(10, home + "/Library/Caches/Nested")], selectedIDs: [10])
        expect(plan.items.isEmpty && fm.fileExists(atPath: nested), "nested symlink refuses whole item")

        let replace = try file("Replace/item.txt", "original")
        plan = try engine.prepare(candidates: [candidate(11, replace)], selectedIDs: [11])
        try fm.moveItem(atPath: replace, toPath: replace + ".original")
        try Data("replacement".utf8).write(to: URL(fileURLWithPath: replace))
        results = run(engine, plan)
        expect(results.first?.status == .skipped && (try? String(contentsOfFile: replace, encoding: .utf8)) == "replacement", "replacement inode preserved")
        let mutable = try file("Mutable/item.txt")
        let mutableParent = URL(fileURLWithPath: mutable).deletingLastPathComponent().path
        plan = try engine.prepare(candidates: [candidate(12, mutableParent)], selectedIDs: [12])
        _ = try file("Mutable/new-file.txt")
        results = run(engine, plan)
        expect(results.first?.status == .skipped && fm.fileExists(atPath: mutable), "post-preview tree addition refused")

        let raced = try file("Race/item.txt", "approved")
        var raceCalls = 0
        let racer = SelectedCleanup(home: home, activityCheck: { _, _ in
            raceCalls += 1
            if raceCalls == 2 {
                try! fm.moveItem(atPath: raced, toPath: raced + ".approved")
                try! Data("foreign replacement".utf8).write(to: URL(fileURLWithPath: raced))
            }
            return nil
        })
        plan = try racer.prepare(candidates: [candidate(17, raced)], selectedIDs: [17])
        results = run(racer, plan)
        expect(results.first?.status == .skipped && (try? String(contentsOfFile: raced, encoding: .utf8)) == "foreign replacement", "replacement during final probe is staged, detected and restored")
        expect((try? String(contentsOfFile: raced + ".approved", encoding: .utf8)) == "approved", "approved inode moved elsewhere never deleted")
        let lateActive = try file("LateActive/item.txt")
        var lateCalls = 0
        let late = SelectedCleanup(home: home, activityCheck: { _, _ in lateCalls += 1; return lateCalls == 3 ? "became active" : nil })
        plan = try late.prepare(candidates: [candidate(18, lateActive)], selectedIDs: [18])
        results = run(late, plan)
        expect(results.first?.status == .skipped && fm.fileExists(atPath: lateActive), "post-stage owner check restores item")

        let protected = try file("Protected/item.txt")
        try fm.createDirectory(atPath: home + "/.config/mole", withIntermediateDirectories: true)
        let whitelist = home + "/.config/mole/whitelist"
        try Data((protected + "\n").utf8).write(to: URL(fileURLWithPath: whitelist))
        plan = try engine.prepare(candidates: [candidate(13, protected)], selectedIDs: [13])
        expect(plan.items.isEmpty && plan.skipped.count == 1, "user rule enforced")
        try Data().write(to: URL(fileURLWithPath: whitelist))
        plan = try engine.prepare(candidates: [candidate(13, protected)], selectedIDs: [13])
        try Data((protected + "\n").utf8).write(to: URL(fileURLWithPath: whitelist))
        results = run(engine, plan)
        expect(results.first?.status == .skipped && fm.fileExists(atPath: protected), "changed rules invalidate plan")
        try Data().write(to: URL(fileURLWithPath: whitelist))

        let cancelItem = try file("Cancelled/item.txt")
        let slow = SelectedCleanup(home: home, activityCheck: { _, _ in Thread.sleep(forTimeInterval: 0.05); return nil })
        plan = try slow.prepare(candidates: [candidate(14, cancelItem)], selectedIDs: [14])
        results = run(slow, plan, cancelImmediately: true)
        expect(results.first?.status == .cancelled && fm.fileExists(atPath: cancelItem), "cancel preserves untouched item")
        let expired = SelectedCleanup(home: home, planTTL: -1, activityCheck: { _, _ in nil })
        plan = try expired.prepare(candidates: [candidate(15, cancelItem)], selectedIDs: [15])
        results = run(expired, plan)
        expect(results.first?.status == .skipped && fm.fileExists(atPath: cancelItem), "expired plan refused")

        let active = SelectedCleanup(home: home, activityCheck: { _, _ in "fixture active process" })
        plan = try active.prepare(candidates: [candidate(16, cancelItem)], selectedIDs: [16])
        expect(plan.items.isEmpty && plan.skipped.count == 1, "active/unknown probe refuses item")
        expect(engine.restriction(path: home + "/Documents/x") != nil, "personal documents excluded")
        expect(engine.restriction(path: home + "/Library/Caches") != nil, "cache root excluded")
        expect(engine.restriction(path: home + "/Library/Caches/Codex/x") != nil, "Codex always protected")
        expect(engine.restriction(path: home + "/Library/Logs/Mac Care/x") != nil, "maintenance app always protected")
        expect(engine.restriction(path: home + "/Library/Application Support/Example/Profile") != nil, "profile data excluded")
        expect(engine.restriction(path: home + "/Library/Application Support/Example/GPUCache/x") == nil, "exact Chromium cache child supported")
        expect(engine.restriction(path: home + "/Library/Caches/../Documents/x") != nil, "traversal refused")
        let realProbe = SelectedCleanup(home: home)
        let probed = try realProbe.prepare(candidates: [candidate(19, cancelItem)], selectedIDs: [19])
        print("Read-only production probe:", probed.items.count == 1 ? "idle fixture eligible" : probed.skipped.map(\.message).joined(separator: "; "))
        expect(fm.fileExists(atPath: cancelItem), "real process/open-handle probe does not mutate fixture")
        let stages = fm.enumerator(atPath: home)?.allObjects.compactMap { $0 as? String }.filter { $0.contains(".mac-care-stage-") } ?? []
        expect(stages.isEmpty, "no staging residue on completed fixture actions")
        print("PASS: \(count) selected-cleanup assertions; only temporary-home fixtures modified.")
    }
}
