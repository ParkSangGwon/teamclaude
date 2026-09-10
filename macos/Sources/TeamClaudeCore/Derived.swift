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
        return table[code] ?? code
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

    /// TUI `formatReset`: `45m`, `3h31m`, `2h`, `3d12h`, `3d`; empty when past or unknown.
    public static func formatReset(_ resetAt: Date?, now: Date = Date()) -> String {
        guard let resetAt else { return "" }
        let ms = resetAt.timeIntervalSince(now) * 1000
        // A date far enough out to overflow `Int` minutes comes from a broken clock, not a window.
        guard ms.isFinite, ms < 1e18 else { return "" }
        if ms <= 0 { return "" }
        let mins = Int((ms / 60000).rounded(.up))
        if mins < 60 { return "\(mins)m" }
        let hrs = mins / 60, rm = mins % 60
        if hrs < 24 { return rm > 0 ? "\(hrs)h\(rm)m" : "\(hrs)h" }
        let days = hrs / 24, rh = hrs % 24
        return rh > 0 ? "\(days)d\(rh)h" : "\(days)d"
    }

    /// status-renderer `formatDuration` for probe/uptime figures.
    public static func formatDuration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "-" }
        let totalSeconds = max(1, Int(interval.rounded()))
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let totalMinutes = Int((Double(totalSeconds) / 60).rounded(.up))
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let hours = totalMinutes / 60, minutes = totalMinutes % 60
        if hours < 24 { return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h" }
        let days = hours / 24, rem = hours % 24
        return rem > 0 ? "\(days)d\(rem)h" : "\(days)d"
    }

    public enum ResetStyle: String, Sendable, CaseIterable { case countdown, clock, both }

    /// "Resets in 3h 31m (Today 21:30)". Empty when the window has not started.
    public static func formatResetLong(_ resetAt: Date?, style: ResetStyle = .both, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let resetAt else { return "" }
        let remaining = resetAt.timeIntervalSince(now)
        if remaining <= 0 { return "Reset due" }
        let spaced = spacedCountdown(remaining)
        let clock = clockText(resetAt, now: now, calendar: calendar)
        switch style {
        case .countdown: return "Resets in \(spaced)"
        case .clock: return "Resets \(clock)"
        case .both: return "Resets in \(spaced) (\(clock))"
        }
    }

    static func spacedCountdown(_ remaining: TimeInterval) -> String {
        if remaining < 60 { return "under a minute" }
        let mins = Int((remaining / 60).rounded(.up))
        if mins < 60 { return "\(mins)m" }
        let hrs = mins / 60, rm = mins % 60
        if hrs < 24 { return rm > 0 ? "\(hrs)h \(rm)m" : "\(hrs)h" }
        let days = hrs / 24, rh = hrs % 24
        return rh > 0 ? "\(days)d \(rh)h" : "\(days)d"
    }

    static func clockText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened))
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow \(time)" }
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
        guard let tier, let w = tier.weight else { return "tier ?" }
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
        if s.mode == "adaptive" { mode = "adapting" }
        else if s.distribute { mode = "distributing" }
        else if s.draining > 0 { mode = "draining \(s.draining)" }
        else { mode = "single-account" }
        return "\(s.active) active / \(s.known) known · \(mode)"
    }

    /// Money from minor units (status-renderer / oauth.js `formatMoney`).
    public static func formatMoney(minor: Double, currency: String, exponent: Int) -> String {
        let major = minor / pow(10, Double(exponent))
        let symbol = currency.uppercased() == "USD" ? "$" : currency.uppercased() + " "
        return symbol + String(format: "%.2f", major)
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
            rows.append(RouteRow(
                kind: .default, name: "", label: "Everything else", match: "",
                target: s.effectiveDefaultTarget, pinned: nil, pinMismatch: false, blocked: false, autocreated: false,
                eligible: [], ineligible: [], color: nil,
                current: s.currentAccount, currentUnavailable: s.current?.unavailable
            ))
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
            let cause = hasQuota && hasThrottled ? "over its quota threshold or in a rate-limit hold"
                : hasQuota ? "over its quota threshold" : "in a rate-limit hold"
            why = " — every account is \(cause)."
        } else {
            why = " — it is failing, not idle."
        }

        let items = (s.raw["sessions"]["items"].array ?? []).filter {
            ($0["active"].bool ?? false) && ($0["starved"].int ?? 0) >= starvedMin
        }.sorted { ($0["starved"].int ?? 0) > ($1["starved"].int ?? 0) }
        for it in items.prefix(starvedListMax) {
            let client = it["client"].string.map { Text.safe($0, max: 32) }
            let id = String((it["id"].string ?? "").prefix(8))
            let project = it["dimensions"]["project"].string.map { Text.safe($0, max: 48) }
            let head = client.map { "\($0)'s session " } ?? "Session "
            out.append(Problem(severity: .bad, kind: "starved-session",
                               text: "\(head)\(id) has had \(it["starved"].int ?? 0) requests in a row come back with nothing\(project.map { " (\($0))" } ?? "")\(why)"))
        }
        if items.count > starvedListMax {
            out.append(Problem(severity: .bad, kind: "starved-more", text: "and \(items.count - starvedListMax) more sessions are getting nothing back."))
        }
        if items.isEmpty, let max = s.sessions?.starvedMax, max >= starvedMin {
            out.append(Problem(severity: .bad, kind: "starved-session",
                               text: "A session has had \(max) requests in a row come back with nothing. Turn on proxy.sessionDetail to see which."))
        }

        let attention = ["error": "needs a re-login", "disabled": "is disabled"]
        for a in s.accounts {
            if let code = a.unavailable, let text = attention[code] {
                out.append(Problem(severity: .warn, kind: "account", text: "Account \(a.name) \(text)."))
            }
        }
        return out
    }

    /// dashboard.js `switchOutcome`: recorded and taking effect are two different things.
    public static func switchOutcome(_ r: SwitchResult) -> SwitchOutcome {
        if !r.ok { return SwitchOutcome(kind: .error, text: "switch failed" + (r.error.map { ": \($0)" } ?? "")) }
        let name = r.account ?? ""
        if r.eligible == false {
            return SwitchOutcome(kind: .warn, text: "switched to \(name), but rotation will not use it" + (r.reason.map { ": \($0)" } ?? ""))
        }
        return SwitchOutcome(kind: .ok, text: "switched to \(name)")
    }

    /// Every account is out of rotation: requests will queue or 429.
    public static func isHold(_ s: StatusSnapshot) -> Bool {
        !s.accounts.isEmpty && s.accounts.allSatisfy { $0.unavailable != nil }
    }

    /// Why nothing can serve, for the hold banner and the hold notification.
    public static func holdReason(_ s: StatusSnapshot) -> String {
        let stalled = s.accounts.filter { $0.unavailable == "quota" || $0.unavailable == "throttled" }
        return stalled.count == s.accounts.count ? "every account is over its quota threshold or in a rate-limit hold" : "every account is out of rotation"
    }
}
