import Foundation

/// What the app should notify about. `id` doubles as the dedupe key: the
/// notification centre replaces a pending notification with the same id.
public struct Alert: Sendable, Equatable {
    public enum Kind: String, Sendable { case fleetLevel, rotation, accountError, hold, proxyDown, proxyBack, spend }
    public var kind: Kind
    public var id: String
    public var title: String
    public var body: String
    public var sound: Bool
}

public struct AlertPrefs: Sendable, Equatable, Codable {
    public var levels: [Int] = [90, 95]
    public var fleetFiveHour = true
    public var fleetWeekly = true
    public var rotation = true
    public var accountError = true
    public var hold = true
    public var proxyDown = true
    public var proxyBack = false
    public var spend = true
    public var pausedUntil: Date? = nil

    public init() {}

    /// A blob written by an older build lacks the keys added since; they take their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        levels = try c.decodeIfPresent([Int].self, forKey: .levels) ?? levels
        fleetFiveHour = try c.decodeIfPresent(Bool.self, forKey: .fleetFiveHour) ?? fleetFiveHour
        fleetWeekly = try c.decodeIfPresent(Bool.self, forKey: .fleetWeekly) ?? fleetWeekly
        rotation = try c.decodeIfPresent(Bool.self, forKey: .rotation) ?? rotation
        accountError = try c.decodeIfPresent(Bool.self, forKey: .accountError) ?? accountError
        hold = try c.decodeIfPresent(Bool.self, forKey: .hold) ?? hold
        proxyDown = try c.decodeIfPresent(Bool.self, forKey: .proxyDown) ?? proxyDown
        proxyBack = try c.decodeIfPresent(Bool.self, forKey: .proxyBack) ?? proxyBack
        spend = try c.decodeIfPresent(Bool.self, forKey: .spend) ?? spend
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
    }

    public func isPaused(at now: Date) -> Bool { pausedUntil.map { $0 > now } ?? false }
}

/// Persisted between launches so a relaunch does not re-fire a level already announced.
public struct AlertState: Sendable, Equatable, Codable {
    public var seeded = false
    /// metric → levels already fired; a level re-arms once usage falls five points below it.
    public var fired: [String: [Int]] = [:]
    public var lastCurrent: String? = nil
    public var allOut = false
    public var errorAccounts: [String] = []
    public var downStreak = 0
    public var announcedDown = false
    public var spendSeen: [String] = []

    public init() {}

    /// Missing keys (a blob from before they existed) must not throw the whole state
    /// away, or every already-announced level fires again after an update.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? seeded
        fired = try c.decodeIfPresent([String: [Int]].self, forKey: .fired) ?? fired
        lastCurrent = try c.decodeIfPresent(String.self, forKey: .lastCurrent)
        allOut = try c.decodeIfPresent(Bool.self, forKey: .allOut) ?? allOut
        errorAccounts = try c.decodeIfPresent([String].self, forKey: .errorAccounts) ?? errorAccounts
        downStreak = try c.decodeIfPresent(Int.self, forKey: .downStreak) ?? downStreak
        announcedDown = try c.decodeIfPresent(Bool.self, forKey: .announcedDown) ?? announcedDown
        spendSeen = try c.decodeIfPresent([String].self, forKey: .spendSeen) ?? spendSeen
    }
}

public struct AlertInputs: Sendable {
    public var previous: StatusSnapshot?
    public var status: StatusSnapshot?
    public var quota: QuotaSnapshot?
    public var reachable: Bool
    /// The account the app itself just switched to (suppresses the rotation alert for it).
    public var appSwitchedTo: String?
    public var now: Date

    public init(previous: StatusSnapshot?, status: StatusSnapshot?, quota: QuotaSnapshot?, reachable: Bool, appSwitchedTo: String? = nil, now: Date = Date()) {
        self.previous = previous; self.status = status; self.quota = quota; self.reachable = reachable; self.appSwitchedTo = appSwitchedTo; self.now = now
    }
}

public enum AlertEngine {
    public static let downStreakToAnnounce = 2
    /// A level re-arms once utilization drops this many points below it.
    public static let hysteresisPoints = 5

    public static func evaluate(_ inputs: AlertInputs, state: AlertState, prefs: AlertPrefs) -> (alerts: [Alert], state: AlertState) {
        var s = state
        var out: [Alert] = []
        let paused = prefs.isPaused(at: inputs.now)
        // Hold and proxy-down stay audible while paused; everything else is muted.
        func emit(_ a: Alert) {
            if paused && a.kind != .hold && a.kind != .proxyDown { return }
            out.append(a)
        }

        // Reachability first: it does not need a snapshot.
        if inputs.reachable {
            if s.announcedDown {
                if prefs.proxyBack { emit(Alert(kind: .proxyBack, id: "proxy.back", title: "TeamClaude proxy is back", body: "Status is updating again.", sound: false)) }
                s.announcedDown = false
            }
            s.downStreak = 0
        } else {
            s.downStreak += 1
            if s.downStreak >= downStreakToAnnounce, !s.announcedDown {
                s.announcedDown = true
                if prefs.proxyDown { emit(Alert(kind: .proxyDown, id: "proxy.down", title: "TeamClaude proxy is not responding", body: "No answer from the proxy. Open the log or restart the service.", sound: true)) }
            }
        }

        guard let status = inputs.status else { return (out, s) }
        let seeding = !s.seeded
        s.seeded = true

        // Fleet levels (5h / 7d): once per crossing, re-armed by the hysteresis band only.
        // The aggregate's `nextResetAt` is the earliest of every account's windows, so
        // keying on it would re-announce "at 90%" each time any one account resets.
        if let quota = inputs.quota {
            let metrics: [(String, String, Bool, String)] = [
                ("fiveHour", "fleet.5h", prefs.fleetFiveHour, "Fleet 5-hour usage"),
                ("weeklyShared", "fleet.7d", prefs.fleetWeekly, "Fleet weekly usage"),
            ]
            for (bucket, key, enabled, title) in metrics {
                guard let agg = quota.aggregate[bucket], let util = agg.utilization else { continue }
                var fired = s.fired[key] ?? []
                let pct = util * 100
                for level in prefs.levels.sorted() {
                    if pct >= Double(level) {
                        if !fired.contains(level) {
                            fired.append(level)
                            if enabled, !seeding {
                                let reset = agg.nextResetAt.map { " · next reset in \(Derived.formatReset($0, now: inputs.now))" } ?? ""
                                // One id per metric and level: the next window's alert replaces the last instead of piling up.
                                emit(Alert(kind: .fleetLevel, id: "\(key).\(level)", title: "\(title) at \(Derived.percentInt(util))%",
                                           body: "\(agg.knownAccounts) accounts weighted by tier\(reset)", sound: false))
                            }
                        }
                    } else if pct < Double(level - hysteresisPoints) {
                        fired.removeAll { $0 == level }
                    }
                }
                s.fired[key] = fired
            }
        }

        // Rotation: the account carrying new requests changed.
        let current = status.effectiveDefaultTarget
        if let prev = s.lastCurrent, let cur = current, prev != cur, !seeding, cur != inputs.appSwitchedTo {
            if prefs.rotation {
                let reason = inputs.previous?.account(named: prev)?.unavailable.flatMap(UnavailableText.label)
                    ?? status.account(named: prev)?.unavailable.flatMap(UnavailableText.label)
                emit(Alert(kind: .rotation, id: "rotate.\(prev).\(cur)", title: "Rotated: \(prev) → \(cur)",
                           body: reason.map { "\(prev): \($0)" } ?? "Rotation moved to \(cur).", sound: true))
            }
        }
        s.lastCurrent = current

        // An account that needs a person.
        let errors = status.accounts.filter { $0.unavailable == "error" }.map(\.name)
        for name in errors where !s.errorAccounts.contains(name) && !seeding && prefs.accountError {
            emit(Alert(kind: .accountError, id: "acct.error.\(name)", title: "\(name) needs a re-login", body: "The account is in an error state. Open Settings → Accounts.", sound: false))
        }
        s.errorAccounts = errors

        // Every account out of rotation.
        let hold = Derived.isHold(status)
        if hold, !s.allOut, !seeding, prefs.hold {
            emit(Alert(kind: .hold, id: "hold", title: "No account can serve requests", body: Derived.holdReason(status), sound: true))
        }
        s.allOut = hold

        // First billable overage seen this month, per account.
        let month = Calendar.current.dateComponents([.year, .month], from: inputs.now)
        let monthKey = "\(month.year ?? 0)-\(month.month ?? 0)"
        for a in status.accounts {
            guard let spend = a.quota.spend, spend.enabled, let used = spend.usedMinor, used > 0 else { continue }
            let key = "spend.\(a.name).\(monthKey)"
            if !s.spendSeen.contains(key) {
                s.spendSeen.append(key)
                if !seeding, prefs.spend {
                    emit(Alert(kind: .spend, id: key, title: "\(a.name) is billing overage", body: "\(Derived.formatMoney(minor: used, currency: spend.currency, exponent: spend.exponent)) used this month", sound: false))
                }
            }
        }
        if s.spendSeen.count > 64 { s.spendSeen.removeFirst(s.spendSeen.count - 64) }

        return (out, s)
    }
}
