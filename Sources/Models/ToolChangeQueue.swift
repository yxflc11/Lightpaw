import Foundation

struct ToolConfigurationState: Equatable {
    let enabled: Bool
    // SHA-256 of the complete configuration, never the configuration itself.
    let fingerprint: String
}

struct ToolChangeState: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case waiting, conflict, failed }
    let key: String
    var targetEnabled: Bool
    let baselineEnabled: Bool
    var fingerprint: String
    var status: Status
    var id: String { key }
}

enum ToolChangeActivity { case running, stopped, unknown }

struct ToolChangeRuntime {
    var read: (String) throws -> ToolConfigurationState
    // Must independently validate the key, eligibility and exact fingerprint.
    // Return the state read from the successfully written configuration.
    var write: (String, Bool, String) throws -> ToolConfigurationState
    var activity: () -> ToolChangeActivity
    var now: () -> Date = Date.init
}

enum ToolChangeQueueError: LocalizedError {
    case invalidKey, invalidState, invalidStorage, limitReached
    case configurationUnavailable, configurationChanged, persistence
    var errorDescription: String? {
        switch self {
        case .invalidKey: return "此工具标识不在安全管理范围内。"
        case .invalidState: return "无法核实工具配置，未预约更改。"
        case .invalidStorage: return "待应用记录无法安全读取，未更改工具配置。"
        case .limitReached: return "最多可同时预约 64 个工具更改。"
        case .configurationUnavailable: return "工具配置暂时无法核实，请刷新后重试。"
        case .configurationChanged: return "配置已被其他操作更改；请核对当前状态，再重新确认此项。"
        case .persistence: return "待应用记录未能保存，请重试；尚未保存的预约不会执行。"
        }
    }
}

/// Small synchronous state machine. The owner calls every method on one serial
/// queue and supplies its existing sampling tick; this class creates no timers,
/// processes or configuration reloads. Stopped evidence is never persisted.
final class ToolChangeQueue {
    private struct Envelope: Codable { let version: Int; let changes: [ToolChangeState] }
    private let runtime: ToolChangeRuntime
    private let save: (Data) throws -> Void
    private var stoppedSince: Date?
    private(set) var changes: [ToolChangeState]
    private(set) var persistenceNeedsRetry = false
    private static let maximumBytes = 128 * 1024
    private static let maximumItems = 64

    init(runtime: ToolChangeRuntime, load: () throws -> Data?, save: @escaping (Data) throws -> Void) throws {
        self.runtime = runtime
        self.save = save
        do {
            if let data = try load() {
                guard data.count <= Self.maximumBytes else { throw ToolChangeQueueError.invalidStorage }
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.version == 1 else { throw ToolChangeQueueError.invalidStorage }
                try Self.validate(envelope.changes)
                changes = envelope.changes
            } else { changes = [] }
        } catch { throw ToolChangeQueueError.invalidStorage }
    }

    /// Reconfirm must only be passed after the user reviews an external change.
    /// Clicking back to the unchanged baseline cancels a pending intention.
    func request(key: String, desired: Bool, reconfirm: Bool = false) throws {
        guard Self.validKey(key) else { throw ToolChangeQueueError.invalidKey }
        let current: ToolConfigurationState
        do { current = try runtime.read(key) }
        catch { throw ToolChangeQueueError.configurationUnavailable }
        guard Self.validFingerprint(current.fingerprint) else { throw ToolChangeQueueError.invalidState }
        var next = changes
        if let index = next.firstIndex(where: { $0.key == key }) {
            let existing = next[index]
            let matches = existing.fingerprint == current.fingerprint && existing.baselineEnabled == current.enabled
            if (!matches || existing.status == .conflict) && !reconfirm {
                next[index].status = .conflict
                try persist(next)
                throw ToolChangeQueueError.configurationChanged
            }
            if desired == current.enabled { next.remove(at: index) }
            else {
                next[index] = ToolChangeState(key: key, targetEnabled: desired, baselineEnabled: current.enabled,
                                             fingerprint: current.fingerprint, status: .waiting)
            }
        } else if desired != current.enabled {
            guard next.count < Self.maximumItems else { throw ToolChangeQueueError.limitReached }
            next.append(ToolChangeState(key: key, targetEnabled: desired, baselineEnabled: current.enabled,
                                        fingerprint: current.fingerprint, status: .waiting))
        }
        try persist(next)
        // Each explicit new intention needs fresh stopped evidence, even if an
        // earlier empty queue happened to observe Codex closed.
        stoppedSince = nil
    }

    /// Cancellation only changes our local intention, never the tool config.
    func cancel(key: String) throws {
        guard Self.validKey(key) else { throw ToolChangeQueueError.invalidKey }
        try persist(changes.filter { $0.key != key })
        if changes.isEmpty { stoppedSince = nil }
    }

    /// Returns successfully applied keys. Failed/conflicting rows remain visible
    /// and require an explicit request or cancellation; they are not retried.
    @discardableResult func applyWhenStopped() throws -> [String] {
        // A config write can precede a failed queue save. Retain that real state
        // in memory, and make it durable before attempting any further write.
        if persistenceNeedsRetry { try persist(changes) }
        guard changes.contains(where: { $0.status == .waiting }) else { stoppedSince = nil; return [] }
        guard runtime.activity() == .stopped else { stoppedSince = nil; return [] }
        let now = runtime.now()
        guard let earlier = stoppedSince else { stoppedSince = now; return [] }
        let elapsed = now.timeIntervalSince(earlier)
        guard elapsed >= 0 else { stoppedSince = now; return [] }
        guard elapsed >= 2 else { return [] }
        var applied: [String] = []
        // Snapshot only the keys; each iteration reads the latest fingerprints
        // after previous changes to the same shared configuration.
        for key in changes.filter({ $0.status == .waiting }).map(\.key) {
            guard runtime.activity() == .stopped else { stoppedSince = nil; break }
            guard let index = changes.firstIndex(where: { $0.key == key && $0.status == .waiting }) else { continue }
            let pending = changes[index]
            let current: ToolConfigurationState
            do { current = try runtime.read(key) }
            catch { try mark(key, .failed); continue }
            guard Self.validFingerprint(current.fingerprint) else { try mark(key, .failed); continue }
            guard current.enabled == pending.baselineEnabled, current.fingerprint == pending.fingerprint else {
                try mark(key, .conflict); continue
            }
            // A process may start while read() is in progress. No write follows
            // unknown/running evidence, including a restart between two rows.
            guard runtime.activity() == .stopped else { stoppedSince = nil; break }
            let updated: ToolConfigurationState
            do { updated = try runtime.write(key, pending.targetEnabled, pending.fingerprint) }
            catch { try mark(key, .failed); continue }
            guard updated.enabled == pending.targetEnabled, Self.validFingerprint(updated.fingerprint) else {
                try mark(key, .failed); continue
            }
            var next = changes.filter { $0.key != key }
            // Our own atomic change advances only entries with the same known
            // baseline. An unrelated external change is never silently rebased.
            for position in next.indices where next[position].status == .waiting && next[position].fingerprint == pending.fingerprint {
                next[position].fingerprint = updated.fingerprint
            }
            // The external write already succeeded. Never put its old intention
            // back in memory if persistence fails; a restored stale disk record
            // will fail the exact fingerprint check instead of being applied.
            changes = next
            persistenceNeedsRetry = true
            applied.append(key)
            try persist(next)
        }
        if !changes.contains(where: { $0.status == .waiting }) { stoppedSince = nil }
        return applied
    }

    private func mark(_ key: String, _ status: ToolChangeState.Status) throws {
        var next = changes
        if let index = next.firstIndex(where: { $0.key == key }) { next[index].status = status }
        try persist(next)
    }

    private func persist(_ next: [ToolChangeState]) throws {
        try Self.validate(next)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Envelope(version: 1, changes: next))
            guard data.count <= Self.maximumBytes else { throw ToolChangeQueueError.invalidStorage }
            try save(data)
        } catch { throw ToolChangeQueueError.persistence }
        changes = next
        persistenceNeedsRetry = false
    }

    private static func validate(_ changes: [ToolChangeState]) throws {
        guard changes.count <= maximumItems, Set(changes.map(\.key)).count == changes.count,
              changes.allSatisfy({ validKey($0.key) && validFingerprint($0.fingerprint) && $0.targetEnabled != $0.baselineEnabled })
        else { throw ToolChangeQueueError.invalidStorage }
    }

    private static func validFingerprint(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validKey(_ key: String) -> Bool {
        guard key.utf8.count <= 300 else { return false }
        if key.hasPrefix("mcp:") {
            let id = key.dropFirst(4)
            return !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy(asciiIdentifier)
        }
        if key.hasPrefix("plugin:") {
            let parts = key.dropFirst(7).split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { asciiIdentifier($0) || $0 == 46 } }
        }
        return false
    }

    private static func asciiIdentifier(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 45
    }
}
