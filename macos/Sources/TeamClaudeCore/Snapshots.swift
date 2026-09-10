import Foundation

public enum SnapshotError: Error, Sendable, Equatable {
    /// Something answered on the port, but it is not a teamclaude control plane.
    case notStatus
    case notQuota
}

/// `GET /teamclaude/status`. Every field is optional on the wire: the running
/// proxy may predate or postdate the app. `raw` keeps what no field covers.
public struct StatusSnapshot: Sendable, Equatable {
    public var server: ServerInfo?
    public var probe: JobState?
    public var warm: JobState?
    public var currentAccount: String?
    public var defaultTarget: String?
    public var switchThreshold: Double
    public var switchThresholds: [String: Double]?
    public var routes: [Route]
    public var sessions: SessionsInfo?
    public var blockedModels: [String]
    public var accounts: [Account]
    public var raw: JSON

    public init(json: JSON) throws {
        guard let list = json["accounts"].array else { throw SnapshotError.notStatus }
        raw = json
        server = json["server"].object.map { _ in ServerInfo(json: json["server"]) }
        probe = json["probe"].object.map { _ in JobState(json: json["probe"]) }
        warm = json["warm"].object.map { _ in JobState(json: json["warm"]) }
        currentAccount = json["currentAccount"].string.map(Text.safe)
        defaultTarget = json["defaultTarget"].string.map(Text.safe)
        switchThreshold = json["switchThreshold"].double ?? 0.98
        if let table = json["switchThresholds"].object {
            var t: [String: Double] = [:]
            for (k, v) in table { if let d = v.double { t[k] = d } }
            switchThresholds = t
        } else {
            switchThresholds = nil
        }
        routes = (json["routes"].array ?? []).map(Route.init(json:))
        sessions = json["sessions"].object.map { _ in SessionsInfo(json: json["sessions"]) }
        blockedModels = json["blockedModels"].stringArray.map { Text.safe($0, max: 64) }
        accounts = list.map(Account.init(json:))
    }

    /// True on 1.1.18+, where the server reports where an unrouted request lands.
    public var hasDefaultTarget: Bool { !raw["defaultTarget"].isNull }
    /// Where an unrouted request lands right now (falls back to the current account).
    public var effectiveDefaultTarget: String? { defaultTarget ?? currentAccount }
    public var current: Account? { account(named: currentAccount) }

    public func account(named name: String?) -> Account? {
        guard let name else { return nil }
        return accounts.first { $0.name == name }
    }

    /// The threshold that governs a bucket: the per-bucket table wins, then the scalar.
    public func thresholdFor(bucket: String) -> Double {
        switchThresholds?[bucket] ?? switchThreshold
    }

    /// Preference order, which is what an operator configured priority to mean.
    public var accountsByPriority: [Account] {
        accounts.enumerated().sorted { a, b in
            a.element.priority != b.element.priority ? a.element.priority < b.element.priority : a.offset < b.offset
        }.map(\.element)
    }
}

public struct ServerInfo: Sendable, Equatable {
    public var startedAt: Date?
    public var uptimeSeconds: Int?
    public var port: Int?
    public var upstream: String?

    init(json: JSON) {
        startedAt = json["startedAt"].date
        uptimeSeconds = json["uptimeSeconds"].int
        port = json["port"].int
        upstream = json["upstream"].string
    }
}

/// The quota probe or the keep-warm job.
public struct JobState: Sendable, Equatable {
    public var enabled: Bool
    public var mode: String?
    public var intervalSeconds: Int
    public var running: Bool
    public var lastRunStartedAt: Date?
    public var lastRunFinishedAt: Date?
    public var nextRunAt: Date?
    public var accounts: [JobAccount]

    init(json: JSON) {
        enabled = json["enabled"].bool ?? false
        mode = json["mode"].string
        intervalSeconds = json["intervalSeconds"].int ?? 0
        running = json["running"].bool ?? false
        lastRunStartedAt = json["lastRunStartedAt"].date
        lastRunFinishedAt = json["lastRunFinishedAt"].date
        nextRunAt = json["nextRunAt"].date
        accounts = (json["accounts"].array ?? []).map(JobAccount.init(json:))
    }
}

public struct JobAccount: Sendable, Equatable {
    public var name: String
    public var status: String?
    public var lastAt: Date?
    public var durationMs: Int?
    public var error: String?

    init(json: JSON) {
        name = Text.safe(json["name"].string ?? "")
        status = json["status"].string
        lastAt = json["lastProbedAt"].date ?? json["lastWarmedAt"].date
        durationMs = json["durationMs"].int
        error = json["error"].string.map { Text.safe($0, max: 200) }
    }
}

public struct Route: Sendable, Equatable {
    public var name: String
    public var match: [String]
    public var bucket: String?
    public var color: String?
    public var autocreated: Bool
    public var pinned: String?
    public var accounts: [RouteAccount]
    public var target: String?

    init(json: JSON) {
        name = Text.safe(json["name"].string ?? "")
        match = json["match"].stringArray.map { Text.safe($0, max: 64) }
        bucket = json["bucket"].string
        color = json["color"].string
        autocreated = json["autocreated"].bool ?? false
        pinned = json["pinned"].string.map(Text.safe)
        accounts = (json["accounts"].array ?? []).map { RouteAccount(name: Text.safe($0["name"].string ?? ""), eligible: $0["eligible"].bool ?? false) }
        target = json["target"].string.map(Text.safe)
    }
}

public struct RouteAccount: Sendable, Equatable {
    public var name: String
    public var eligible: Bool
}

public struct SessionsInfo: Sendable, Equatable {
    public var known: Int
    public var active: Int
    public var distribute: Bool
    /// `off` / `even` / `adaptive`; derived from `distribute` on servers without `mode`.
    public var mode: String
    public var draining: Int
    public var perAccount: [Int: Int]
    public var starvedMax: Int

    init(json: JSON) {
        known = json["known"].int ?? 0
        active = json["active"].int ?? 0
        let dist = json["distribute"]
        distribute = dist.bool ?? (dist.string != nil)
        mode = json["mode"].string ?? (distribute ? "even" : "off")
        draining = json["draining"].int ?? 0
        var per: [Int: Int] = [:]
        for (k, v) in json["perAccount"].object ?? [:] { if let i = Int(k), let n = v.int { per[i] = n } }
        perAccount = per
        starvedMax = json["starvedMax"].int ?? 0
    }
}

public struct Account: Sendable, Equatable {
    public var name: String
    public var type: String
    public var orgName: String?
    public var priority: Int
    public var disabled: Bool
    public var maxUsage: JSON
    /// `active` / `throttled` / `exhausted` / `error`.
    public var status: String
    /// Why the account is out of rotation, or nil when it can serve. Unknown
    /// codes are kept verbatim; `UnavailableText.label` falls back to the code.
    public var unavailable: String?
    public var sessions: Int
    public var quota: Quota
    public var usage: Usage
    public var rateLimitedUntil: Date?
    public var pausedUntil: Date?
    public var entitlementDeniedUntil: Date?
    public var raw: JSON

    init(json: JSON) {
        raw = json
        name = Text.safe(json["name"].string ?? "")
        type = json["type"].string ?? "oauth"
        orgName = json["orgName"].string.map(Text.safe)
        priority = json["priority"].int ?? 0
        disabled = json["disabled"].bool ?? false
        maxUsage = json["maxUsage"]
        status = json["status"].string ?? "active"
        unavailable = json["unavailable"].string.map { Text.safe($0, max: 32) }
        sessions = json["sessions"].int ?? 0
        quota = Quota(json: json["quota"])
        usage = Usage(json: json["usage"])
        rateLimitedUntil = json["rateLimitedUntil"].date
        pausedUntil = json["pausedUntil"].date
        entitlementDeniedUntil = json["entitlementDeniedUntil"].date
    }

    public var isApiKey: Bool { type == "apikey" }
}

public struct Quota: Sendable, Equatable {
    public var unified5h: Double?
    public var unified7d: Double?
    public var unified7dSonnet: Double?
    public var unified7dFable: Double?
    public var unified5hReset: Date?
    public var unified7dReset: Date?
    public var unified7dSonnetReset: Date?
    public var unified7dFableReset: Date?
    public var unifiedStatus: String?
    /// Learned from the usage payload's `limits` array: family → bucket.
    public var scopedWeekly: [String: ScopedBucket]
    public var tokensLimit: Double?
    public var tokensRemaining: Double?
    public var requestsLimit: Double?
    public var requestsRemaining: Double?
    public var resetsAt: Date?
    public var backend: Backend?
    public var spend: Spend?

    init(json: JSON) {
        unified5h = json["unified5h"].double
        unified7d = json["unified7d"].double
        unified7dSonnet = json["unified7dSonnet"].double
        unified7dFable = json["unified7dFable"].double
        unified5hReset = json["unified5hReset"].date
        unified7dReset = json["unified7dReset"].date
        unified7dSonnetReset = json["unified7dSonnetReset"].date
        unified7dFableReset = json["unified7dFableReset"].date
        unifiedStatus = json["unifiedStatus"].string
        var scoped: [String: ScopedBucket] = [:]
        for (family, v) in json["scopedWeekly"].object ?? [:] {
            scoped[family] = ScopedBucket(utilization: v["utilization"].double, resetAt: v["resetAt"].date)
        }
        scopedWeekly = scoped
        tokensLimit = json["tokensLimit"].double
        tokensRemaining = json["tokensRemaining"].double
        requestsLimit = json["requestsLimit"].double
        requestsRemaining = json["requestsRemaining"].double
        resetsAt = json["resetsAt"].date
        backend = json["backend"].object.map { _ in Backend(json: json["backend"]) }
        spend = json["spend"].object.map { _ in Spend(json: json["spend"]) }
    }

    public var isEmpty: Bool {
        unified5h == nil && unified7d == nil && tokensLimit == nil && requestsLimit == nil && backend == nil
    }
}

public struct ScopedBucket: Sendable, Equatable {
    public var utilization: Double?
    public var resetAt: Date?
}

public struct Backend: Sendable, Equatable {
    public var label: String
    public var text: String
    public var utilization: Double?
    public var at: Date?

    init(json: JSON) {
        label = Text.safe(json["label"].string ?? "Backend", max: 32)
        text = Text.safe(json["text"].string ?? "", max: 64)
        utilization = json["utilization"].double
        at = json["at"].date
    }
}

public struct Spend: Sendable, Equatable {
    public var enabled: Bool
    public var usedMinor: Double?
    public var limitMinor: Double?
    public var currency: String
    public var exponent: Int

    init(json: JSON) {
        enabled = json["enabled"].bool ?? false
        usedMinor = json["usedMinor"].double
        limitMinor = json["limitMinor"].double
        currency = json["currency"].string ?? "USD"
        exponent = json["exponent"].int ?? 2
    }
}

public struct Usage: Sendable, Equatable {
    public var totalRequests: Int
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    public var totalCacheReadTokens: Int
    public var totalCacheCreationTokens: Int
    public var lastUsed: Date?

    init(json: JSON) {
        totalRequests = json["totalRequests"].int ?? 0
        totalInputTokens = json["totalInputTokens"].int ?? 0
        totalOutputTokens = json["totalOutputTokens"].int ?? 0
        totalCacheReadTokens = json["totalCacheReadTokens"].int ?? 0
        totalCacheCreationTokens = json["totalCacheCreationTokens"].int ?? 0
        lastUsed = json["lastUsed"].date
    }

    public var totalTokens: Int { totalInputTokens + totalOutputTokens + totalCacheReadTokens + totalCacheCreationTokens }
}

// MARK: - GET /teamclaude/quota

public struct QuotaSnapshot: Sendable, Equatable {
    public var accounts: [QuotaAccount]
    /// Keys: `fiveHour`, `weeklyShared`, `weeklySonnet`, `weeklyFable`.
    public var aggregate: [String: Aggregate]
    public var unknownTiers: [String]
    public var warmup: JSON
    public var raw: JSON

    public init(json: JSON) throws {
        guard let list = json["accounts"].array else { throw SnapshotError.notQuota }
        raw = json
        accounts = list.map(QuotaAccount.init(json:))
        var agg: [String: Aggregate] = [:]
        for (k, v) in json["aggregate"].object ?? [:] { if v.object != nil { agg[k] = Aggregate(json: v) } }
        aggregate = agg
        unknownTiers = (json["unknownTiers"].array ?? []).compactMap { $0["name"].string.map(Text.safe) }
        warmup = json["warmup"]
    }

    public func account(named name: String?) -> QuotaAccount? {
        guard let name else { return nil }
        return accounts.first { $0.name == name }
    }
}

public struct QuotaAccount: Sendable, Equatable {
    public var name: String
    public var type: String
    public var disabled: Bool
    public var status: String?
    public var tier: Tier
    public var buckets: [String: Bucket]

    init(json: JSON) {
        name = Text.safe(json["name"].string ?? "")
        type = json["type"].string ?? "oauth"
        disabled = json["disabled"].bool ?? false
        status = json["status"].string
        tier = Tier(json: json["tier"])
        var b: [String: Bucket] = [:]
        for (k, v) in json["buckets"].object ?? [:] { if v.object != nil { b[k] = Bucket(json: v) } }
        buckets = b
    }
}

public struct Tier: Sendable, Equatable {
    public var rateLimitTier: String?
    public var seatTier: String?
    /// 1 (Pro / Team standard), 5 (Max 5x / Team tier 1), 20 (Max 20x / Team tier 2), nil unknown.
    public var weight: Int?

    init(json: JSON) {
        rateLimitTier = json["rateLimitTier"].string
        seatTier = json["seatTier"].string
        weight = json["weight"].int
    }
}

public struct Bucket: Sendable, Equatable {
    public var utilization: Double?
    public var remaining: Double?
    public var resetAt: Date?
    /// Which raw field fed the bucket (`unified7d` when a family fell back to the shared week).
    public var source: String?
    public var limit: Double?
    public var remainingAmount: Double?

    init(json: JSON) {
        utilization = json["utilization"].double
        remaining = json["remaining"].double
        resetAt = json["resetAt"].date
        source = json["source"].string
        limit = json["limit"].double
        remainingAmount = json["remainingAmount"].double
    }
}

public struct Aggregate: Sendable, Equatable {
    public var capacityWeight: Double
    public var usedWeight: Double
    public var remainingWeight: Double
    public var utilization: Double?
    public var remaining: Double?
    public var knownAccounts: Int
    public var nextResetAt: Date?

    init(json: JSON) {
        capacityWeight = json["capacityWeight"].double ?? 0
        usedWeight = json["usedWeight"].double ?? 0
        remainingWeight = json["remainingWeight"].double ?? 0
        utilization = json["utilization"].double
        remaining = json["remaining"].double
        knownAccounts = json["knownAccounts"].int ?? 0
        nextResetAt = json["nextResetAt"].date
    }
}

// MARK: - Control-plane replies

public struct SwitchResult: Sendable, Equatable {
    public var ok: Bool
    public var account: String?
    public var eligible: Bool?
    public var reason: String?
    public var error: String?

    public init(ok: Bool, account: String? = nil, eligible: Bool? = nil, reason: String? = nil, error: String? = nil) {
        self.ok = ok; self.account = account; self.eligible = eligible; self.reason = reason; self.error = error
    }

    init(json: JSON) {
        ok = json["ok"].bool ?? false
        account = json["account"].string.map(Text.safe)
        eligible = json["eligible"].bool
        reason = json["reason"].string.map { Text.safe($0, max: 160) }
        error = json["error"].string.map { Text.safe($0, max: 160) }
    }
}

public struct ReloadResult: Sendable, Equatable {
    public var ok: Bool
    public var added: Int
    public var error: String?

    public init(ok: Bool, added: Int = 0, error: String? = nil) {
        self.ok = ok; self.added = added; self.error = error
    }

    init(json: JSON) {
        ok = json["ok"].bool ?? false
        added = json["added"].int ?? 0
        error = json["error"].string.map { Text.safe($0, max: 160) }
    }
}

/// Strings off the wire started life in an OAuth reply or a config file: drop
/// control characters and cap the length before they reach a menu or a notification.
public enum Text {
    /// Identifiers (account names, targets) keep their full value: a truncated name
    /// no longer matches the server, the CLI or the config. Views truncate at render time.
    public static func safe(_ s: String) -> String { safe(s, max: 512) }

    public static func safe(_ s: String, max: Int) -> String {
        var out = ""
        for u in s.unicodeScalars where !(u.value < 0x20 || u.value == 0x7f || (u.value >= 0x80 && u.value < 0xa0)) {
            out.unicodeScalars.append(u)
        }
        if out.count > max { return String(out.prefix(max - 1)) + "…" }
        return out
    }
}
