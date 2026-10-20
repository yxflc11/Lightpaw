import Foundation

/// Only records operations executed by this app, apart from Mole's own history.
final class LocalHistory {
    private let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexMemoryWatch")
    private var url: URL { directory.appendingPathComponent("maintenance-history.json") }
    func read() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url), data.count <= 1024 * 1024,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows
    }
    func append(command: String, summary: String, trashed: Int = 0, removed: Int = 0, skipped: Int = 0, failed: Int = 0) throws {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let date = formatter.string(from: Date())
        let row: [String: Any] = ["command": command, "size": summary, "started_at": date, "ended_at": date,
                                 "attribution": "native", "actions": ["trashed": trashed, "removed": removed, "skipped": skipped, "failed": failed]]
        let rows = Array(([row] + read()).prefix(100))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
