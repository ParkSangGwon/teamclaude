import Foundation

/// Bar colour by severity, ported from the TUI so the app never contradicts `teamclaude status`.
public enum Level: String, Sendable, Equatable, CaseIterable {
    case green, yellow, orange, red
}

public enum Window {
    public static let fiveHour: TimeInterval = 5 * 3600
    public static let sevenDay: TimeInterval = 7 * 24 * 3600
}

public enum Buckets {
    public static let fiveHour = "unified5h"
    public static let weekly = "unified7d"
    public static let sonnet = "unified7dSonnet"
    public static let fable = "unified7dFable"
    public static let all = [fiveHour, weekly, sonnet, fable, "tokens", "requests"]
}

/// Why an account is out of rotation, in the operator's terms (status-renderer.js).
public enum UnavailableText {
    public static let table: [String: String] = [
        "disabled": "disabled by operator",
        "throttled": "upstream 429 hold",
        "exhausted": "marked exhausted",
        "error": "account error (see logs)",
        "upstream-rejected": "upstream reports quota rejected",
        "quota": "local switch threshold reached",
        "capped": "account usage cap reached (maxUsage)",
        "advisor-capped": "advisor model's usage cap reached (maxUsage)",
        "entitlement": "upstream refused this account for the organization (cooldown)",
        "route": "no route allows this account",
        "advisor-quota": "advisor model's weekly bucket spent",
        "advisor-route": "no route allows the advisor model",
    ]

    public static func label(_ code: String?) -> String? {
        guard let code else { return nil }
        return table[code].map { L($0) } ?? code
    }
}

public enum Derived {
    /// TUI `barColor`: at or above the switch threshold is red whatever the pace;
    /// below it, colour by how far usage runs ahead of the elapsed share of the window.
    public static func level(ratio: Double, resetAt: Date?, window: TimeInterval?, threshold: Double?, now: Date = Date()) -> Level {
        if let threshold, ratio >= threshold { return .red }
        let remaining = resetAt.map { $0.timeIntervalSince(now) } ?? 0
        if let window, window > 0, remaining > 0 {
            let elapsed = max(0, window - remaining)
            let diff = ratio * 100 - (elapsed / window) * 100
            if diff <= 0 { return .green }
            if diff <= 5 { return .yellow }
            if diff <= 15 { return .orange }
            return .red
        }
        return ratio < 0.7 ? .green : ratio < 0.9 ? .yellow : .red
    }

    /// Raw-fill colouring for a bucket with no window (fleet aggregates, tokens):
    /// the TUI's no-window fallback, green / yellow / red.
    public static func rawLevel(_ ratio: Double, warn: Double = 0.7, critical: Double = 0.9) -> Level {
        ratio < warn ? .green : ratio < critical ? .yellow : .red
    }

    /// Fraction of the window already elapsed (the tick on a bar), or nil without a window.
    public static func elapsedFraction(resetAt: Date?, window: TimeInterval, now: Date = Date()) -> Double? {
        guard let resetAt else { return nil }
        let remaining = resetAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= window else { return remaining <= 0 ? 1 : nil }
        return (window - remaining) / window
    }

    /// The m / h / d tiering every countdown shares; `separator` sits between the two units.
    static func tiered(minutes: Int, separator: String) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hrs = minutes / 60, rm = minutes % 60
        if hrs < 24 { return rm > 0 ? "\(hrs)h\(separator)\(rm)m" : "\(hrs)h" }
        let days = hrs / 24, rh = hrs % 24
        return rh > 0 ? "\(days)d\(separator)\(rh)h" : "\(days)d"
    }

    /// TUI `formatReset`: `45m`, `3h31m`, `2h`, `3d12h`, `3d`; empty when past or unknown.
    public static func formatReset(_ resetAt: Date?, now: Date = Date()) -> String {
        guard let resetAt else { return "" }
        let ms = resetAt.timeIntervalSince(now) * 1000
        // A date far enough out to overflow `Int` minutes comes from a broken clock, not a window.
        guard ms.isFinite, ms < 1e18, ms > 0 else { return "" }
        return tiered(minutes: Int((ms / 60000).rounded(.up)), separator: "")
    }

    /// status-renderer `formatDuration` for probe/uptime figures.
    public static func formatDuration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0, interval < 1e15 else { return "-" }
        let totalSeconds = max(1, Int(interval.rounded()))
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        return tiered(minutes: Int((Double(totalSeconds) / 60).rounded(.up)), separator: "")
    }

    public enum ResetStyle: String, Sendable, CaseIterable { case countdown, clock, both }

    /// "Resets in 3h 31m (Today 21:30)". Empty when the window has not started.
    public static func formatResetLong(_ resetAt: Date?, style: ResetStyle = .both, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let resetAt else { return "" }
        let remaining = resetAt.timeIntervalSince(now)
        if remaining <= 0 { return L("Reset overdue") }
        let spaced = spacedCountdown(remaining)
        let clock = clockText(resetAt, now: now, calendar: calendar)
        switch style {
        case .countdown: return L("Resets in %@", spaced)
        case .clock: return L("Resets %@", clock)
        case .both: return L("Resets in %@ (%@)", spaced, clock)
        }
    }

    static func spacedCountdown(_ remaining: TimeInterval) -> String {
        if remaining < 60 { return L("under a minute") }
        guard remaining.isFinite, remaining < 1e15 else { return "" }
        return tiered(minutes: Int((remaining / 60).rounded(.up)), separator: " ")
    }

    static func clockText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened))
        if calendar.isDate(date, inSameDayAs: now) { return L("Today %@", time) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return L("Tomorrow %@", time) }
        if date.timeIntervalSince(now) < 6 * 24 * 3600 {
            return "\(date.formatted(Date.FormatStyle().weekday(.abbreviated))) \(time)"
        }
        return "\(date.formatted(Date.FormatStyle().month(.abbreviated).day())), \(time)"
    }

    /// status-renderer `formatPercent`: whole percent unless a tenth is meaningful.
    public static func formatPercent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let pct = min(1e6, max(-1e6, value * 100))
        if abs(pct - pct.rounded()) < 0.05 { return "\(Int(pct.rounded()))%" }
        return String(format: "%.1f%%", pct)
    }

    /// Whole percent, clamped so a hostile ratio (±inf, 1e300) cannot trap the conversion.
    public static func percentInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(1e6, max(-1e6, (value * 100).rounded())))
    }

    /// `Int(_:)` traps past ±9.2e18; anything that came over the wire or from a hand-edited config goes through here.
    public static func safeInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(1e15, max(-1e15, value.rounded())))
    }

    /// `1 - remaining/limit` for token and request pools; nil when the pool has no size.
    public static func usedFraction(remaining: Double?, limit: Double?) -> Double? {
        guard let remaining, let limit, limit > 0, remaining.isFinite, limit.isFinite else { return nil }
        return 1 - remaining / limit
    }

    /// "Max 20x" / "Max 5x" / "Pro" / "Team 20x" / "tier ?".
    public static func tierBadge(_ tier: Tier?) -> String {
        guard let tier, let w = tier.weight else { return L("tier ?") }
        let team = (tier.seatTier ?? "").lowercased().hasPrefix("team")
        switch w {
        case 20: return team ? "Team 20x" : "Max 20x"
        case 5: return team ? "Team 5x" : "Max 5x"
        case 1: return team ? "Team" : "Pro"
        default: return "\(w)x"
        }
    }

    /// status-renderer `formatSessions`.
    public static func formatSessions(_ s: SessionsInfo) -> String {
        let mode: String
        if s.mode == "adaptive" { mode = L("adapting") }
        else if s.distribute { mode = L("distributing") }
        else if s.draining > 0 { mode = L("draining %d", s.draining) }
        else { mode = L("single-account") }
        return L("%d active / %d known · %@", s.active, s.known, mode)
    }

    /// Money from minor units (status-renderer / oauth.js `formatMoney`).
    public static func formatMoney(minor: Double, currency: String, exponent: Int) -> String {
        let major = minor / pow(10, Double(exponent))
        let symbol = currency.uppercased() == "USD" ? "$" : currency.uppercased() + " "
        return symbol + String(format: "%.2f", major)
    }

    /// status-renderer `BUCKET_LABELS`: what an operator calls a bucket.
    public static func bucketLabel(_ key: String) -> String {
        switch key {
        case Buckets.weekly: return "opus+"
        case Buckets.fable: return "fable"
        case Buckets.sonnet: return "sonnet"
        case Buckets.fiveHour: return "5h"
        default: return Text.safe(key, max: 24)
        }
    }

    /// status-renderer `formatSessionBuckets`: " (opus+ 2, fable 1)" once a second family is in play.
    public static func formatSessionBuckets(_ byBucket: [String: Int]) -> String {
        let entries = byBucket.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        guard entries.count >= 2 else { return "" }
        return " (" + entries.map { "\(bucketLabel($0.key)) \($0.value)" }.joined(separator: ", ") + ")"
    }

    /// status-renderer `formatAdaptive`, without the colour.
    public static func formatAdaptive(_ a: AdaptiveRow) -> String {
        var parts: [String] = []
        let family = bucketLabel(a.bucket ?? Buckets.weekly)
        let prefix = a.next ? L("next") + " · " : ""
        if let w = a.weight { parts.append(prefix + L("weight %d%% of %@", percentInt(w), family)) } else { parts.append(prefix + L("weight n/a (all reserved, %@)", family)) }
        parts.append(L("%d sess / %d inflight", a.sessions, a.inFlight))
        if let h = a.headroom { parts.append(L("headroom %@%% of %d%%", String(format: "%.1f", h * 100), percentInt(a.threshold ?? 0))) }
        parts.append(a.planWeight.map { L("plan %dx", safeInt($0)) } ?? L("plan unknown"))
        if let c = a.concCap { parts.append(L("conc %@", String(format: "%.1f", c))) }
        let line = parts.joined(separator: " · ")
        return a.competing ? line : L("(not competing)") + " " + line
    }

    /// The current account is out of rotation but traffic already moved on: ordinary rotation, not an emergency.
    public static func currentBlockedButRotated(_ s: StatusSnapshot) -> Bool {
        guard s.current?.unavailable != nil, let target = s.effectiveDefaultTarget else { return false }
        return target != s.currentAccount
    }

    /// Why rotation left `from` for `to`, in the order the router decides it: the old account's own
    /// reason, a strictly better priority, then expiry routing. Nil when nothing explains it.
    public static func rotationReason(from: String, to: String, previous: StatusSnapshot?, status: StatusSnapshot, now: Date = Date()) -> String? {
        let old = previous?.account(named: from) ?? status.account(named: from)
        let new = status.account(named: to)
        if let code = old?.unavailable, let label = UnavailableText.label(code) {
            let reset = code == "quota" ? old?.quota.unified5hReset.map { " · " + L("resets in %@", formatReset($0, now: now)) } ?? "" : ""
            return "\(from): \(label)\(reset)"
        }
        if let o = old, let n = new, n.priority < o.priority {
            return L("%@ outranks %@ (priority %d < %d)", to, from, n.priority, o.priority)
        }
        if status.expiryRouting?.enabled == true, status.expiryRouting?.preempt == true {
            return L("expiry routing preferred %@", to)
        }
        return nil
    }
}

// MARK: - Next-up, reset timeline, aliases

public struct NextUp: Sendable, Equatable {
    public var name: String
    /// "prio 0 · 1 sess · pressure 0.42/s", or the adaptive scorer's own line.
    public var reason: String
    public var isCurrent: Bool
}

public struct ResetEntry: Sendable, Equatable, Identifiable {
    public var id: String { "\(account)/\(bucket)" }
    public var account: String
    /// `5h`, `wk`, `F7`, `S7`.
    public var bucket: String
    public var resetAt: Date
    /// The account is out of rotation now, so this reset brings capacity back.
    public var freesCapacity: Bool
}

extension Derived {
    /// Where the next unrouted request goes and why (the server's `defaultTarget`, explained).
    public static func nextUp(_ s: StatusSnapshot) -> NextUp? {
        guard let target = s.effectiveDefaultTarget, let acc = s.account(named: target) else { return nil }
        var parts: [String] = []
        if let row = s.adaptive.first(where: { $0.name == target }), row.next {
            parts.append(formatAdaptive(row))
        } else {
            if target != s.currentAccount, let cur = s.currentAccount, let why = rotationReason(from: cur, to: target, previous: nil, status: s) {
                parts.append(why)
            }
            parts.append(L("prio %d", acc.priority))
            if acc.sessions > 0 { parts.append(L("%d sess", acc.sessions) + formatSessionBuckets(acc.sessionsByBucket)) }
            if let p = acc.pressure, p > 0 { parts.append(L("pressure %@/s", String(format: "%.2f", p))) }
        }
        return NextUp(name: target, reason: parts.joined(separator: " · "), isCurrent: target == s.currentAccount)
    }

    /// The fleet's elapsed share of a window: each known account's elapsed fraction, weighted by tier.
    public static func fleetElapsed(_ q: QuotaSnapshot, key: String, window: TimeInterval, now: Date = Date()) -> Double? {
        var weightSum = 0.0, acc = 0.0
        for a in q.accounts {
            guard let w = a.tier.weight, w > 0, let e = elapsedFraction(resetAt: a.buckets[key]?.resetAt, window: window, now: now) else { continue }
            weightSum += Double(w)
            acc += Double(w) * e
        }
        return weightSum > 0 ? acc / weightSum : nil
    }

    /// Every account's upcoming window resets, soonest first, so the fleet's capacity return is visible.
    public static func resetTimeline(_ q: QuotaSnapshot, status: StatusSnapshot?, now: Date = Date(), limit: Int = 6) -> [ResetEntry] {
        let labels: [(String, String, String?)] = [("fiveHour", "5h", nil), ("weeklyShared", L("wk"), nil), ("weeklyFable", "F7", Buckets.fable), ("weeklySonnet", "S7", Buckets.sonnet)]
        var out: [ResetEntry] = []
        for acc in q.accounts {
            let live = status?.account(named: acc.name)
            let frees = live?.unavailable != nil && live?.unavailable != "disabled"
            for (key, label, ownSource) in labels {
                guard let b = acc.buckets[key], let at = b.resetAt, at > now else { continue }
                // A family that falls back to the shared week resets with it; listing it twice says nothing new.
                if let ownSource, b.source != ownSource { continue }
                out.append(ResetEntry(account: acc.name, bucket: label, resetAt: at, freesCapacity: frees))
            }
        }
        return Array(out.sorted { $0.resetAt != $1.resetAt ? $0.resetAt < $1.resetAt : $0.account < $1.account }.prefix(limit))
    }

    /// Display aliases that stay unique: the local part, then the organization, then a number.
    /// `alice@x.com` and `alicia@y.com` are `alice` / `alicia`; two `alice`s in different orgs become
    /// `alice (Acme)` / `alice (Beta)`; otherwise `alice`, `alice 2`.
    public static func aliases(for accounts: [(name: String, org: String?)], base: (String) -> String = { String($0.split(separator: "@").first ?? Substring($0)) }) -> [String: String] {
        var groups: [String: [(String, String?)]] = [:]
        var order: [String] = []
        for a in accounts {
            let b = base(a.name)
            if groups[b] == nil { order.append(b) }
            groups[b, default: []].append((a.name, a.org))
        }
        var out: [String: String] = [:]
        for b in order {
            let members = groups[b] ?? []
            if members.count == 1 { out[members[0].0] = b; continue }
            let orgs = members.map { $0.1 ?? "" }
            let orgsUnique = Set(orgs).count == members.count && !orgs.contains("")
            for (i, m) in members.enumerated() {
                out[m.0] = orgsUnique ? "\(b) (\(m.1 ?? ""))" : (i == 0 ? b : "\(b) \(i + 1)")
            }
        }
        return out
    }
}

// MARK: - Rows the views render

public struct FamilyRow: Sendable, Equatable {
    public var family: String
    public var label: String
    public var utilization: Double?
    public var resetAt: Date?
}

public struct RouteRow: Sendable, Equatable {
    public enum Kind: Sendable { case route, `default` }
    public var kind: Kind
    public var name: String
    public var label: String
    public var match: String
    public var target: String?
    public var pinned: String?
    public var pinMismatch: Bool
    public var blocked: Bool
    public var autocreated: Bool
    public var eligible: [String]
    public var ineligible: [String]
    public var color: String?
    public var current: String?
    public var currentUnavailable: String?
}

public struct Problem: Sendable, Equatable {
    public enum Severity: Sendable { case bad, warn }
    public var severity: Severity
    public var kind: String
    public var text: String
}

public struct SwitchOutcome: Sendable, Equatable {
    public enum Kind: Sendable { case ok, warn, error }
    public var kind: Kind
    public var text: String
}

extension Derived {
    /// dashboard.js `scopedWeeklyRows`: one row per family upstream meters separately.
    public static func scopedWeeklyRows(_ q: Quota) -> [FamilyRow] {
        var rows: [FamilyRow] = []
        for (family, b) in q.scopedWeekly {
            rows.append(FamilyRow(family: family, label: family.prefix(1).uppercased() + family.dropFirst(), utilization: b.utilization, resetAt: b.resetAt))
        }
        let fallback: [(String, String, Double?, Date?)] = [
            ("fable", "Fable", q.unified7dFable, q.unified7dFableReset),
            ("sonnet", "Sonnet", q.unified7dSonnet, q.unified7dSonnetReset),
        ]
        for (family, label, u, r) in fallback where q.scopedWeekly[family] == nil && u != nil {
            rows.append(FamilyRow(family: family, label: label, utilization: u, resetAt: r))
        }
        return rows.sorted { $0.family < $1.family }
    }

    /// dashboard.js `routeRows`: the server's own routing answers, plus the default row.
    public static func routeRows(_ s: StatusSnapshot) -> [RouteRow] {
        var rows: [RouteRow] = s.routes.map { r in
            RouteRow(
                kind: .route,
                name: r.name,
                label: r.name.prefix(1).uppercased() + r.name.dropFirst(),
                match: r.match.joined(separator: ", "),
                target: r.target,
                pinned: r.pinned,
                pinMismatch: r.pinned != nil && r.pinned != r.target,
                blocked: !r.match.isEmpty && r.match.allSatisfy { s.blockedModels.contains($0) },
                autocreated: r.autocreated,
                eligible: r.accounts.filter(\.eligible).map(\.name),
                ineligible: r.accounts.filter { !$0.eligible }.map(\.name),
                color: r.color,
                current: nil,
                currentUnavailable: nil
            )
        }
        if !rows.isEmpty {
            // One default row per provider on 1.1.20+ (a mixed Claude/Codex fleet has two cursors); one row before.
            if s.defaultTargets.isEmpty {
                rows.append(RouteRow(
                    kind: .default, name: "", label: L("Everything else"), match: "",
                    target: s.effectiveDefaultTarget, pinned: nil, pinMismatch: false, blocked: false, autocreated: false,
                    eligible: [], ineligible: [], color: nil,
                    current: s.currentAccount, currentUnavailable: s.current?.unavailable
                ))
            } else {
                for provider in s.providers where s.defaultTargets[provider] != nil || s.currentAccounts[provider] != nil {
                    let current = s.currentAccounts[provider] ?? s.currentAccount
                    rows.append(RouteRow(
                        kind: .default, name: "", label: L("%@ default", Providers.label(provider)), match: "",
                        target: s.defaultTargets[provider], pinned: nil, pinMismatch: false, blocked: false, autocreated: false,
                        eligible: [], ineligible: [], color: nil,
                        current: current, currentUnavailable: s.account(named: current)?.unavailable
                    ))
                }
            }
        }
        return rows
    }

    public static let starvedMin = 5
    public static let starvedListMax = 3

    /// dashboard.js `problems`: what is wrong right now, worst first — only states
    /// that need a person, never ordinary rotation or back-off.
    public static func problems(_ s: StatusSnapshot) -> [Problem] {
        var out: [Problem] = []
        let stalled = s.accounts.filter { $0.unavailable == "quota" || $0.unavailable == "throttled" }
        let hasQuota = stalled.contains { $0.unavailable == "quota" }
        let hasThrottled = stalled.contains { $0.unavailable == "throttled" }
        let why: String
        if !s.accounts.isEmpty, stalled.count == s.accounts.count {
            let cause = hasQuota && hasThrottled ? L("over its quota threshold or in a rate-limit hold")
                : hasQuota ? L("over its quota threshold") : L("in a rate-limit hold")
            why = " — " + L("every account is %@.", cause)
        } else {
            why = " — " + L("it is failing, not idle.")
        }

        let items = (s.raw["sessions"]["items"].array ?? []).filter {
            ($0["active"].bool ?? false) && ($0["starved"].int ?? 0) >= starvedMin
        }.sorted { ($0["starved"].int ?? 0) > ($1["starved"].int ?? 0) }
        for it in items.prefix(starvedListMax) {
            let client = it["client"].string.map { Text.safe($0, max: 32) }
            let id = String((it["id"].string ?? "").prefix(8))
            let project = it["dimensions"]["project"].string.map { Text.safe($0, max: 48) }
            let head = client.map { L("Session %@", $0) } ?? L("Session")
            out.append(Problem(severity: .bad, kind: "starved-session",
                               text: L("%@ %@ has had %d requests in a row come back with nothing%@", head, id, it["starved"].int ?? 0, project.map { " (\($0))" } ?? "") + why))
        }
        if items.count > starvedListMax {
            out.append(Problem(severity: .bad, kind: "starved-more", text: L("and %d more sessions are getting nothing back.", items.count - starvedListMax)))
        }
        if items.isEmpty, let max = s.sessions?.starvedMax, max >= starvedMin {
            out.append(Problem(severity: .bad, kind: "starved-session",
                               text: L("A session has had %d requests in a row come back with nothing. Turn on proxy.sessionDetail to see which.", max)))
        }

        for a in s.accounts {
            if a.unavailable == "error" { out.append(Problem(severity: .warn, kind: "account", text: L("Account %@ needs a re-login.", a.name))) }
            if a.unavailable == "disabled" { out.append(Problem(severity: .warn, kind: "account", text: L("Account %@ is disabled.", a.name))) }
        }
        return out
    }

    /// dashboard.js `switchOutcome`: recorded and taking effect are two different things.
    public static func switchOutcome(_ r: SwitchResult) -> SwitchOutcome {
        if !r.ok { return SwitchOutcome(kind: .error, text: L("switch failed") + (r.error.map { ": \($0)" } ?? "")) }
        let name = r.account ?? ""
        if r.eligible == false {
            return SwitchOutcome(kind: .warn, text: L("switched to %@, but rotation will not use it", name) + (r.reason.map { ": \($0)" } ?? ""))
        }
        return SwitchOutcome(kind: .ok, text: L("switched to %@", name))
    }

    /// Every account is out of rotation: requests will queue or 429.
    public static func isHold(_ s: StatusSnapshot) -> Bool {
        !s.accounts.isEmpty && s.accounts.allSatisfy { $0.unavailable != nil }
    }

    /// Why nothing can serve, for the hold banner and the hold notification.
    public static func holdReason(_ s: StatusSnapshot) -> String {
        let stalled = s.accounts.filter { $0.unavailable == "quota" || $0.unavailable == "throttled" }
        return stalled.count == s.accounts.count ? L("every account is over its quota threshold or in a rate-limit hold") : L("every account is out of rotation")
    }
}
