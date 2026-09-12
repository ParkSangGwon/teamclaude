import Foundation
import XCTest
import TeamClaudeCore

enum Fixtures {
    static func url(_ name: String) -> URL {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        guard let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures") else {
            fatalError("missing fixture \(name)")
        }
        return url
    }

    static func data(_ name: String) -> Data { try! Data(contentsOf: url(name)) }
    static func text(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }
    static func json(_ name: String) -> JSON { try! JSON.parse(data(name)) }
    static func status(_ name: String) throws -> StatusSnapshot { try StatusSnapshot(json: json(name)) }
    static func quota(_ name: String) throws -> QuotaSnapshot { try QuotaSnapshot(json: json(name)) }

    static let statusNames = ["status-live-1.1.16.json", "status-1.1.20.json", "status-two-accounts-b-quota.json",
                              "status-hold.json", "status-empty.json", "status-hostile.json", "status-mixed-providers.json", "status-mixed-providers-rotated.json"]
}

/// Epoch milliseconds for a moment relative to `now`, the shape quota resets take on the wire.
func ms(_ date: Date) -> JSON { .number((date.timeIntervalSince1970 * 1000).rounded()) }

extension JSON {
    /// Returns a copy with one key path replaced (or removed with nil).
    func patched(_ path: [String], _ value: JSON?) -> JSON {
        var copy = self
        ConfigFile.patch(&copy, path: path, value: value)
        return copy
    }

    /// Returns a copy with `accounts[index]` altered.
    func patchingAccount(_ index: Int, _ mutate: (inout [String: JSON]) -> Void) -> JSON {
        var rows = self["accounts"].array ?? []
        var row = rows[index].object ?? [:]
        mutate(&row)
        rows[index] = .object(row)
        return patched(["accounts"], .array(rows))
    }
}

/// A minimal status account row for tests that build snapshots in code.
func accountJSON(_ name: String, priority: Int = 0, unavailable: String? = nil, fiveHour: Double? = nil, weekly: Double? = nil,
                 extraQuota: [String: JSON] = [:], extra: [String: JSON] = [:]) -> JSON {
    var quota: [String: JSON] = [:]
    if let fiveHour { quota["unified5h"] = .number(fiveHour) }
    if let weekly { quota["unified7d"] = .number(weekly) }
    for (k, v) in extraQuota { quota[k] = v }
    var row: [String: JSON] = [
        "name": .string(name), "type": .string("oauth"), "priority": .number(Double(priority)),
        "status": .string("active"), "unavailable": unavailable.map(JSON.string) ?? .null,
        "quota": .object(quota), "usage": .object([:]),
    ]
    for (k, v) in extra { row[k] = v }
    return .object(row)
}

func statusJSON(current: String?, accounts: [JSON], extra: [String: JSON] = [:]) -> JSON {
    var obj: [String: JSON] = [
        "currentAccount": current.map(JSON.string) ?? .null,
        "switchThreshold": .number(0.98),
        "routes": .array([]),
        "blockedModels": .array([]),
        "accounts": .array(accounts),
    ]
    for (k, v) in extra { obj[k] = v }
    return .object(obj)
}

func makeStatus(current: String?, accounts: [JSON], extra: [String: JSON] = [:]) -> StatusSnapshot {
    try! StatusSnapshot(json: statusJSON(current: current, accounts: accounts, extra: extra))
}

func makeQuota(fiveHour: Double?, weekly: Double? = nil, nextResetAt: Date? = nil, knownAccounts: Int = 2) -> QuotaSnapshot {
    func agg(_ u: Double?) -> JSON {
        var o: [String: JSON] = ["knownAccounts": .number(Double(knownAccounts)), "capacityWeight": .number(40)]
        if let u { o["utilization"] = .number(u) }
        if let nextResetAt { o["nextResetAt"] = ms(nextResetAt) }
        return .object(o)
    }
    var aggregate: [String: JSON] = [:]
    if fiveHour != nil { aggregate["fiveHour"] = agg(fiveHour) }
    if weekly != nil { aggregate["weeklyShared"] = agg(weekly) }
    return try! QuotaSnapshot(json: .object(["accounts": .array([]), "aggregate": .object(aggregate)]))
}

/// Thread-safe list for values collected from `@Sendable` callbacks.
final class Collected<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ v: T) { lock.lock(); items.append(v); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}
