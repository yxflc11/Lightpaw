// Pure protocol fixtures. Does not invoke Mole or touch application files.
// swiftc -swift-version 5 Sources/Models/MoleModels.swift Tests/UninstallProtocolTests.swift -o /tmp/UninstallProtocolTests
import Foundation

@main
enum UninstallProtocolTests {
    static func main() {
        let app = MoleApplication(["name": "Example", "path": "/Applications/Example.app",
                                   "bundle_id": "org.example.app", "source": "App", "size": "1MB"])!
        let prompt = "➤ Remove 1 app, 1.0MB Enter confirm, ESC cancel: "
        func output(_ rows: String, title: String = "◎ Example , 1.0MB") -> String {
            "Files to be removed:\n\(title)\n\(rows)\n\(prompt)"
        }
        func reviewed(_ text: String, expected: MoleApplication = app) -> Bool {
            var state = UninstallProtocol(expected: expected)
            guard case .advanceDiscovery = state.receive("Matched 1 app(s):\n1. \(expected.name)  1MB\nProceed with uninstallation? [y/N] ") else { return false }
            if case .review = state.receive(text) { return true }
            return false
        }
        var cases: [(String, Bool)] = [
            ("measured bundle", reviewed(output("  ✓ /Applications/Example.app , 1.0MB"))),
            ("bundle without size", reviewed(output("  ✓ /Applications/Example.app"))),
            ("warning before bundle", reviewed(output("  ◎ Shared leftovers kept (other copies unchecked)\n  ✓ /Applications/Example.app , 1KB"))),
            ("prefix collision refused", !reviewed(output("  ✓ /Applications/Example.app Backup.app , 1.0MB"))),
            ("expected path in later related row refused", !reviewed(output("  ✓ /Applications/Other.app , 1.0MB\n  ✓ /Applications/Example.app , 1.0MB"))),
            ("retained path refused", !reviewed(output("Personal data kept:\n  ⊙ /Applications/Example.app"))),
            ("review-only path refused", !reviewed(output("  ◎ Review only: /Applications/Example.app , 1.0MB"))),
            ("wrong title refused", !reviewed(output("  ✓ /Applications/Example.app", title: "◎ Other , 1.0MB"))),
            ("unstructured path refused", !reviewed("Files to be removed:\n/Applications/Example.app\n\(prompt)")),
            ("size suffix is not a path wildcard", !reviewed(output("  ✓ /Applications/Example.app , 1MB.app"))),
            ("second app title refused", !reviewed(output("  ✓ /Applications/Example.app\n◎ Other , 1MB\n  ✓ /Applications/Other.app"))),
            ("multiple-app confirmation refused", !reviewed(output("  ✓ /Applications/Example.app").replacingOccurrences(of: "Remove 1 app,", with: "Remove 2 apps,")))
        ]
        let homeApp = MoleApplication(["name": "Example", "path": FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/Example.app",
                                       "bundle_id": "org.example.app", "source": "App", "size": "1MB"])!
        cases.append(("home abbreviation", reviewed(output("  ✓ ~/Applications/Example.app , 1.0MB"), expected: homeApp)))
        let colored = "\u{1B}[35mFiles to be removed:\u{1B}[0m\n\u{1B}[34m◎\u{1B}[0m Example \u{1B}[90m, 1.0MB\u{1B}[0m\n  \u{1B}[32m✓\u{1B}[0m /Applications/Example.app \u{1B}[90m, 1.0MB\u{1B}[0m\n\(prompt)"
        cases.append(("actual colored output", reviewed(colored)))
        let managed = MoleApplication(["name": "Example", "path": "/Applications/Example.app", "bundle_id": "org.example.app", "source": "Homebrew", "size": "1MB"])!
        cases.append(("Homebrew preview header", reviewed(output("  ✓ /Applications/Example.app , 1.0MB", title: "◎ Example [Brew] , 1.0MB"), expected: managed)))
        var state = UninstallProtocol(expected: app)
        _ = state.receive("Matched 1 app(s):\n1. Example  1MB\nProceed with uninstallation? [y/N] ")
        let valid = output("  ✓ /Applications/Example.app , 1.0MB")
        _ = state.receive(valid)
        if case .none = state.receive(valid) { cases.append(("review emitted once", true)) }
        else { cases.append(("review emitted once", false)) }
        let failures = cases.filter { !$0.1 }.map { $0.0 }
        guard failures.isEmpty else { fputs("FAIL: \(failures.joined(separator: ", "))\n", stderr); exit(1) }
        print("PASS: \(cases.count) exact uninstall-preview protocol cases.")
    }
}
