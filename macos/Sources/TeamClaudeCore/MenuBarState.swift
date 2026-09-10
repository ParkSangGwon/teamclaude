import Foundation

public enum IconState: Sendable, Equatable {
    case normal, warning, critical
    case rotating(to: String)
    case proxyDown, noAccounts, stale
    /// No answer yet and no failure either: the first poll is in flight.
    case starting
}

public struct IconInputs: Sendable {
    public var status: StatusSnapshot?
    public var quota: QuotaSnapshot?
    public var reachable: Bool
    public var lastSuccessAt: Date?
    public var now: Date
    public var pollInterval: TimeInterval
    public var rotatedAt: Date?
    public var rotatedTo: String?
    public var pinCurrent: Bool
    public var showRemaining: Bool

    public init(status: StatusSnapshot?, quota: QuotaSnapshot?, reachable: Bool, lastSuccessAt: Date?, now: Date = Date(),
                pollInterval: TimeInterval = 30, rotatedAt: Date? = nil, rotatedTo: String? = nil,
                pinCurrent: Bool = false, showRemaining: Bool = false) {
        self.status = status; self.quota = quota; self.reachable = reachable; self.lastSuccessAt = lastSuccessAt; self.now = now
        self.pollInterval = pollInterval; self.rotatedAt = rotatedAt; self.rotatedTo = rotatedTo
        self.pinCurrent = pinCurrent; self.showRemaining = showRemaining
    }
}

/// What the status item draws. `Equatable` so the image is only re-rendered on change.
public struct IconModel: Sendable, Equatable {
    public var state: IconState
    /// Bar fills (0–1), already flipped to "remaining" when the preference says so.
    public var fiveHour: Double?
    public var weekly: Double?
    public var label: String?
    public var tooltip: String
    /// Three-letter tag drawn under the bars when pinned to the current account.
    public var tag: String?
}

public enum MenuBarState {
    public static let rotatingFlashSeconds: TimeInterval = 6

    public static func compute(_ i: IconInputs) -> IconModel {
        let staleAfter = max(3 * i.pollInterval, 90)
        let age = i.lastSuccessAt.map { i.now.timeIntervalSince($0) }

        if !i.reachable, age == nil || age! > 10 {
            return IconModel(state: .proxyDown, fiveHour: nil, weekly: nil, label: "—",
                             tooltip: L("TeamClaude proxy not reachable") + (age.map { " · " + L("last data %@ ago", Derived.formatDuration($0)) } ?? ""), tag: nil)
        }
        guard let status = i.status else {
            return IconModel(state: .starting, fiveHour: nil, weekly: nil, label: nil, tooltip: L("TeamClaude: connecting to the proxy…"), tag: nil)
        }
        if status.accounts.isEmpty {
            return IconModel(state: .noAccounts, fiveHour: 0, weekly: 0, label: "5h 0", tooltip: L("No accounts configured — open Settings → Accounts"), tag: nil)
        }

        // Source of the bars: fleet aggregate by default, the current account when pinned
        // or when the server has no /quota endpoint.
        let current = status.current
        var fiveHour: Double?
        var weekly: Double?
        var fiveReset: Date?
        var weekReset: Date?
        var tag: String?
        if i.pinCurrent || i.quota == nil, let cur = current {
            fiveHour = cur.quota.unified5h
            weekly = cur.quota.unified7d
            fiveReset = cur.quota.unified5hReset
            weekReset = cur.quota.unified7dReset
            tag = shortName(cur.name)
        } else if let q = i.quota {
            fiveHour = q.aggregate["fiveHour"]?.utilization
            weekly = q.aggregate["weeklyShared"]?.utilization
            fiveReset = q.aggregate["fiveHour"]?.nextResetAt
            weekReset = q.aggregate["weeklyShared"]?.nextResetAt
        }

        // Severity from the colour rule the bars use (the TUI's pace rule), so the icon and the
        // popover never disagree; critical is the fleet's inability to serve or a bar at its threshold.
        let hold = Derived.isHold(status)
        let fiveLevel = fiveHour.map { Derived.level(ratio: $0, resetAt: fiveReset, window: Window.fiveHour, threshold: status.thresholdFor(bucket: Buckets.fiveHour), now: i.now) }
        let weekLevel = weekly.map { Derived.level(ratio: $0, resetAt: weekReset, window: Window.sevenDay, threshold: status.thresholdFor(bucket: Buckets.weekly), now: i.now) }
        let worstLevel = [fiveLevel, weekLevel].compactMap { $0 }.max { Level.allCases.firstIndex(of: $0)! < Level.allCases.firstIndex(of: $1)! } ?? .green
        let atThreshold = (fiveHour ?? 0) >= status.thresholdFor(bucket: Buckets.fiveHour) - 0.05 || (weekly ?? 0) >= status.thresholdFor(bucket: Buckets.weekly) - 0.05
        // A blocked current account is only an emergency while nothing else can take the traffic.
        let stuck = current?.unavailable != nil && !Derived.currentBlockedButRotated(status)
        let state: IconState
        if let age, age > staleAfter {
            state = .stale
        } else if let at = i.rotatedAt, let to = i.rotatedTo, i.now.timeIntervalSince(at) < rotatingFlashSeconds {
            state = .rotating(to: to)
        } else if hold || stuck || atThreshold {
            state = .critical
        } else if worstLevel == .orange || worstLevel == .red {
            state = .warning
        } else {
            state = .normal
        }

        // The window's name leads the number: a battery never says "5h", so the item reads as usage at a glance.
        var label: String? = fiveHour.map { "5h \(Derived.percentInt(i.showRemaining ? 1 - $0 : $0))%" }
        if case .rotating(let to) = state { label = "→ \(shortName(to))" }
        if state == .critical, let l = label, !l.hasSuffix("!") { label = l + "!" }

        var parts: [String] = ["TeamClaude"]
        if let cur = current { parts.append(L("current %@", cur.name)) }
        if let f = fiveHour { parts.append("5h \(Derived.percentInt(f))%") }
        if let w = weekly { parts.append("7d \(Derived.percentInt(w))%") }
        if let cur = current, let fable = cur.quota.unified7dFable { parts.append("Fable \(Derived.percentInt(fable))%") }
        if let cur = current, let reset = cur.quota.unified5hReset {
            let r = Derived.formatReset(reset, now: i.now)
            if !r.isEmpty { parts.append(L("5h resets in %@", r)) }
        }
        let available = status.accounts.filter { $0.unavailable == nil }.count
        parts.append(L("%d/%d accounts available", available, status.accounts.count))
        var tooltip = parts.joined(separator: " · ")
        switch state {
        case .critical: tooltip = (hold ? L("Critical: every account is out of rotation") : stuck ? L("Critical: the current account cannot serve and nothing else can take over") : L("Critical: at the switch threshold")) + " · " + tooltip
        case .warning: tooltip = L("Warning") + " · " + tooltip
        case .stale: tooltip = L("Data is %@ old — the proxy answered slowly or not at all", Derived.formatDuration(age ?? 0)) + " · " + tooltip
        case .rotating(let to): tooltip = L("Rotated to %@", to) + " · " + tooltip
        default: break
        }

        return IconModel(state: state,
                         fiveHour: fiveHour.map { i.showRemaining ? 1 - $0 : $0 },
                         weekly: weekly.map { i.showRemaining ? 1 - $0 : $0 },
                         label: label, tooltip: tooltip, tag: tag)
    }

    /// First three letters of an account's local part: `alice@example.com` → `ali`.
    public static func shortName(_ name: String) -> String {
        let local = name.split(separator: "@").first.map(String.init) ?? name
        let letters = local.filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(3)).lowercased()
    }
}
