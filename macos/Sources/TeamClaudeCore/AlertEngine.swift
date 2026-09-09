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

    public func isPaused(at now: Date) -> Bool { pausedUntil.map { $0 > now } ?? false }
}

/// Persisted between launches so a relaunch does not re-fire a level already announced.
public struct AlertState: Sendable, Equatable, Codable {
    public var seeded = false
    /// metric → levels already fired in the current window.
    public var fired: [String: [Int]] = [:]
    /// metric → the `nextResetAt` the fired levels belong to.
    public var windowIds: [String: Double] = [:]
    public var lastCurrent: String? = nil
    public var allOut = false
    public var errorAccounts: [String] = []
    public var downStreak = 0
    public var announcedDown = false
    public var spendSeen: [String] = []

    public init() {}
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

        // Fleet levels (5h / 7d), once per level per reset window.
        if let quota = inputs.quota {
            let metrics: [(String, String, Bool, String)] = [
                ("fiveHour", "fleet.5h", prefs.fleetFiveHour, "Fleet 5-hour usage"),
                ("weeklyShared", "fleet.7d", prefs.fleetWeekly, "Fleet weekly usage"),
            ]
            for (bucket, key, enabled, title) in metrics {
                guard let agg = quota.aggregate[bucket], let util = agg.utilization else { continue }
                let windowId = agg.nextResetAt?.timeIntervalSince1970 ?? 0
                if s.windowIds[key] != windowId { s.windowIds[key] = windowId; s.fired[key] = [] }
                var fired = s.fired[key] ?? []
                let pct = util * 100
                for level in prefs.levels.sorted() {
                    if pct >= Double(level) {
                        if !fired.contains(level) {
                            fired.append(level)
                            if enabled, !seeding {
                                let reset = agg.nextResetAt.map { " · next reset in \(Derived.formatReset($0, now: inputs.now))" } ?? ""
                                emit(Alert(kind: .fleetLevel, id: "\(key).\(level).\(Int(windowId))", title: "\(title) at \(Derived.percentInt(util))%",
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
            let stalled = status.accounts.filter { $0.unavailable == "quota" || $0.unavailable == "throttled" }
            let why = stalled.count == status.accounts.count ? "every account is over its quota threshold or in a rate-limit hold" : "every account is out of rotation"
            emit(Alert(kind: .hold, id: "hold", title: "No account can serve requests", body: why, sound: true))
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
