import Foundation

public enum PriorityValue: Sendable, Equatable {
    case number(Int)
    case first
    case last
}

/// One user intention. The planner turns it into a CLI invocation where a verb
/// exists (the CLI validates and notifies the server itself) and into a JSON edit
/// otherwise — or when the CLI is missing.
public enum SettingChange: Sendable, Equatable {
    case threshold(percent: Double)
    /// bucket → percent; nil means "back to default".
    case thresholdTable([String: Double?])
    case probe(seconds: Int)
    case warmupOff
    case warmupInterval(seconds: Int)
    case warmupReset(time: String, timezone: String)
    case warmupRolling(time: String, timezone: String)
    case distribute(String)
    case priority(account: String, org: String?, value: PriorityValue)
    case enabled(account: String, org: String?, enabled: Bool)
    case routeAdd(name: String, match: [String], accounts: [String], bucket: String?, color: String?)
    case routeRemove(name: String)
    case removeAccount(name: String, org: String?)
    case json(path: [String], value: JSON?, applies: Applies)
    case accountField(name: String, id: String?, key: String, value: JSON?, applies: Applies)
}

public enum ApplyPath: Sendable, Equatable {
    case patch(path: [String], value: JSON?, Applies)
    case accountPatch(name: String, id: String?, org: String?, key: String, value: JSON?, Applies)
    case routesPatch(RoutesEdit, Applies)
    case removeAccountPatch(name: String, org: String?, Applies)
}

public enum RoutesEdit: Sendable, Equatable {
    case upsert(name: String, match: [String], accounts: [String], bucket: String?, color: String?)
    case remove(name: String)
}

public enum SettingsPlanner {
    /// The CLI verb for a change, or nil when only a JSON edit exists.
    public static func cliArguments(_ change: SettingChange) -> [String]? {
        switch change {
        case .threshold(let pct):
            return ["threshold", formatPercent(pct)]
        case .thresholdTable(let table):
            let pairs = table.keys.sorted().map { key in "\(key)=\(table[key]!.map(formatPercent) ?? "default")" }
            return pairs.isEmpty ? nil : ["threshold"] + pairs
        case .probe(let secs):
            return ["probe", secs <= 0 ? "off" : String(secs)]
        case .warmupOff:
            return ["warmup", "off"]
        case .warmupInterval(let secs):
            return ["warmup", secs <= 0 ? "off" : String(secs)]
        case .warmupReset(let time, let tz):
            return ["warmup", "reset", time, "--timezone", tz]
        case .warmupRolling(let time, let tz):
            return ["warmup", "rolling", time, "--timezone", tz]
        case .distribute(let mode):
            return ["distribute", mode]
        case .priority(let account, let org, let value):
            var args = ["priority", account]
            switch value {
            case .number(let n): args.append(String(n))
            case .first: args.append("--first")
            case .last: args.append("--last")
            }
            if let org { args += ["--org", org] }
            return args
        case .enabled(let account, let org, let enabled):
            var args = [enabled ? "enable" : "disable", account]
            if let org { args += ["--org", org] }
            return args
        case .routeAdd(let name, let match, let accounts, let bucket, let color):
            // The CLI splits lists on commas and reads `--` as a flag, so such names go through JSON.
            let risky = ([name] + match + accounts).contains { $0.contains(",") || $0.hasPrefix("--") || $0.isEmpty }
            if risky { return nil }
            var args = ["route", "add", name, "--match", match.joined(separator: ",")]
            if !accounts.isEmpty { args += ["--accounts", accounts.joined(separator: ",")] }
            if let bucket, !bucket.isEmpty { args += ["--bucket", bucket] }
            if let color, !color.isEmpty { args += ["--color", color] }
            return args
        case .routeRemove(let name):
            return name.hasPrefix("--") ? nil : ["route", "rm", name]
        case .removeAccount(let name, let org):
            var args = ["remove", name]
            if let org { args += ["--org", org] }
            return args
        case .json, .accountField:
            return nil
        }
    }

    /// The JSON edit equivalent of a change (used when the CLI is missing, or when there is no verb).
    public static func jsonPath(_ change: SettingChange) -> ApplyPath {
        switch change {
        case .threshold(let pct):
            return .patch(path: ["switchThreshold"], value: .number(pct / 100), .live)
        case .thresholdTable(let table):
            var obj: [String: JSON] = [:]
            for (k, v) in table { if let v { obj[k] = .number(v / 100) } }
            // The CLI's rule: a table holding only `default` is the plain scalar written the long way.
            if obj.keys.allSatisfy({ $0 == "default" }) { return .patch(path: ["switchThreshold"], value: obj["default"] ?? .number(0.98), .live) }
            return .patch(path: ["switchThreshold"], value: .object(obj), .live)
        case .probe(let secs):
            return .patch(path: ["quotaProbeSeconds"], value: .number(Double(max(0, secs))), .live)
        case .warmupOff:
            return .patch(path: ["warmupSeconds"], value: .number(0), .live)
        case .warmupInterval(let secs):
            return .patch(path: ["warmupSeconds"], value: .number(Double(max(0, secs))), .live)
        case .warmupReset(let time, let tz):
            return .patch(path: ["warmupSchedule"], value: .object(["resetTime": .string(time), "timezone": .string(tz)]), .live)
        case .warmupRolling(let time, let tz):
            return .patch(path: ["warmupSchedule"], value: .object(["mode": .string("rolling"), "resetTime": .string(time), "timezone": .string(tz)]), .live)
        case .distribute(let mode):
            let v: JSON = mode == "adaptive" ? .string("adaptive") : .bool(mode == "on")
            return .patch(path: ["distributeSessions"], value: v, .live)
        case .priority(let account, let org, let value):
            let n: Int
            switch value { case .number(let x): n = x; case .first: n = -1; case .last: n = 100 }
            return .accountPatch(name: account, id: nil, org: org, key: "priority", value: .number(Double(n)), .live)
        case .enabled(let account, let org, let enabled):
            return .accountPatch(name: account, id: nil, org: org, key: "disabled", value: enabled ? nil : .bool(true), .live)
        case .routeAdd(let name, let match, let accounts, let bucket, let color):
            return .routesPatch(.upsert(name: name, match: match, accounts: accounts, bucket: bucket, color: color), .live)
        case .routeRemove(let name):
            return .routesPatch(.remove(name: name), .live)
        case .removeAccount(let name, let org):
            return .removeAccountPatch(name: name, org: org, .restart)
        case .json(let path, let value, let applies):
            return .patch(path: path, value: value, applies)
        case .accountField(let name, let id, let key, let value, let applies):
            return .accountPatch(name: name, id: id, org: nil, key: key, value: value, applies)
        }
    }

    public static func applies(_ change: SettingChange) -> Applies {
        switch jsonPath(change) {
        case .patch(_, _, let a), .accountPatch(_, _, _, _, _, let a), .routesPatch(_, let a), .removeAccountPatch(_, _, let a): return a
        }
    }

    static func formatPercent(_ pct: Double) -> String {
        if pct == pct.rounded() { return String(Int(pct)) }
        return String(format: "%.1f", pct)
    }

    /// Apply a JSON-path plan to a config document.
    public static func mutate(_ root: inout JSON, _ path: ApplyPath) throws {
        switch path {
        case .patch(let p, let value, _):
            // warmup: interval and schedule are mutually exclusive.
            if p == ["warmupSeconds"] { ConfigFile.patch(&root, path: ["warmupSchedule"], value: nil) }
            if p == ["warmupSchedule"] { ConfigFile.patch(&root, path: ["warmupSeconds"], value: .number(0)) }
            ConfigFile.patch(&root, path: p, value: value)
        case .accountPatch(let name, let id, let org, let key, let value, _):
            switch ConfigFile.matchAccount(root, name: name, id: id, org: org) {
            case .notFound: throw SettingsError.noSuchAccount(name)
            case .ambiguous: throw SettingsError.ambiguousAccount(name)
            case .index: break
            }
            guard ConfigFile.patchAccount(&root, name: name, id: id, org: org, key: key, value: value) else { throw SettingsError.noSuchAccount(name) }
        case .routesPatch(let edit, _):
            var routes = root["routes"].array ?? []
            switch edit {
            case .upsert(let name, let match, let accounts, let bucket, let color):
                var obj: [String: JSON] = ["name": .string(name), "match": .array(match.map(JSON.string))]
                if !accounts.isEmpty { obj["accounts"] = .array(accounts.map(JSON.string)) }
                if let bucket, !bucket.isEmpty { obj["bucket"] = .string(bucket) }
                if let color, !color.isEmpty { obj["color"] = .string(color) }
                if let i = routes.firstIndex(where: { $0["name"].string == name }) { routes[i] = .object(obj) } else { routes.append(.object(obj)) }
            case .remove(let name):
                routes.removeAll { $0["name"].string == name }
            }
            ConfigFile.patch(&root, path: ["routes"], value: .array(routes))
        case .removeAccountPatch(let name, let org, _):
            var rows = root["accounts"].array ?? []
            switch ConfigFile.matchAccount(root, name: name, org: org) {
            case .notFound: throw SettingsError.noSuchAccount(name)
            case .ambiguous: throw SettingsError.ambiguousAccount(name)
            case .index(let i): rows.remove(at: i)
            }
            ConfigFile.patch(&root, path: ["accounts"], value: .array(rows))
        }
    }
}

public enum SettingsError: Error, Sendable, Equatable {
    case noSuchAccount(String)
    case ambiguousAccount(String)
    case invalid(String)

    public var message: String {
        switch self {
        case .noSuchAccount(let n): return "No account named \(n)"
        case .ambiguousAccount(let n): return "\(n) matches more than one account — pick it by organization"
        case .invalid(let why): return why
        }
    }
}

public struct ApplyOutcome: Sendable, Equatable {
    public var via: String
    public var restartRequired: Bool
    public var reloaded: Bool
    public var added: Int
    public var note: String?
}

/// CLI first, JSON fallback only when the CLI is missing, then always a reload —
/// `login --api` and `remove` do not notify the server themselves.
public struct SettingsOps: Sendable {
    public typealias Run = @Sendable ([String], String?) async throws -> CLIResult
    public typealias Update = @Sendable (@Sendable (inout JSON) throws -> Void) throws -> JSON
    public typealias Reload = @Sendable () async throws -> ReloadResult

    let run: Run
    let update: Update
    let reload: Reload
    public var serverVersion: String?

    public init(run: @escaping Run, update: @escaping Update, reload: @escaping Reload, serverVersion: String? = nil) {
        self.run = run; self.update = update; self.reload = reload; self.serverVersion = serverVersion
    }

    public func apply(_ change: SettingChange) async throws -> ApplyOutcome {
        var via = "json"
        var usedCLI = false
        if let args = SettingsPlanner.cliArguments(change) {
            do {
                let result = try await run(args, nil)
                if !result.succeeded { throw CLIError.failed(result) }
                usedCLI = true
                via = "cli"
            } catch CLIError.notFound {
                usedCLI = false
            }
        }
        if !usedCLI {
            let path = SettingsPlanner.jsonPath(change)
            _ = try update { root in try SettingsPlanner.mutate(&root, path) }
        }
        let applies = SettingsPlanner.applies(change).resolved(serverVersion: serverVersion)
        var outcome = ApplyOutcome(via: via, restartRequired: applies == .restart, reloaded: false, added: 0, note: nil)
        do {
            let r = try await reload()
            outcome.reloaded = r.ok
            outcome.added = r.added
        } catch let e as ProxyError {
            // Only "nothing is listening" means the change waits for a start; a 401/404/500 is a running proxy saying no.
            if case .unreachable = e { outcome.note = "Saved to the config; it applies when the proxy starts" } else { outcome.note = e.message }
        } catch {
            outcome.note = "Saved to the config; reload failed: \(error.localizedDescription)"
        }
        return outcome
    }
}

/// Validation the CLI does not do for us, run before anything is written.
public enum SettingsValidation {
    /// Only http, a host, and a sane port: a bad value kills the proxy on reload.
    public static func upstreamProxy(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        let withScheme = s.contains("://") ? s : "http://" + s
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased() else { return "Not a valid proxy URL" }
        guard scheme == "http" else { return "Only http:// proxies are supported" }
        guard let host = url.host, !host.isEmpty else { return "A host is required" }
        if let port = url.port, !(1...65535).contains(port) { return "Port must be 1–65535" }
        return nil
    }

    public static func timeHHMM(_ s: String) -> String? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return "Time must be HH:MM" }
        return nil
    }

    public static func timezone(_ s: String) -> String? {
        TimeZone(identifier: s) == nil ? "Not an IANA time zone" : nil
    }

    public static let reservedDimensionHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "x-api-key", "x-app", "x-claude-code-session-id",
        "x-claude-code-agent-id", "x-claude-code-parent-agent-id", "x-anthropic-additional-protection",
    ]
}
