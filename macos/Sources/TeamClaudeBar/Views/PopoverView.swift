import SwiftUI
import AppKit
import TeamClaudeCore

struct PopoverView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.snapshotMode) private var snapshotMode

    static let width = StatusItemController.popoverWidth

    var body: some View {
        // Only the "updated Ns ago" line needs seconds; everything else counts minutes, so the
        // tree re-evaluates every 30 s (and hourly while the popover is closed) instead of every second.
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: store.popoverOpen ? 1 : 3600)) { context in header(now: context.date) }
            Divider()
            TimelineView(.periodic(from: .now, by: store.popoverOpen ? 30 : 3600)) { context in
                let now = context.date
                VStack(alignment: .leading, spacing: 10) {
                    banners
                    if let status = store.status, status.accounts.isEmpty {
                        emptyState
                    } else if let status = store.status {
                        if let current = status.current { currentCard(current, status: status, now: now) }
                        // One account: the fleet is that account, already on the card above.
                        if status.accounts.count > 1, let quota = store.freshQuota { fleetCard(quota, status: status, now: now) }
                        let rows = Derived.routeRows(status)
                        if !rows.isEmpty { routing(rows, status: status) }
                        accounts(status, now: now)
                        sessions(status, now: now)
                        rotationHistory(now: now)
                    } else {
                        Text(store.isDown ? "The proxy is not reachable. Start it with `teamclaude service install` or `teamclaude server`." : "Connecting to the proxy…")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }

    /// A reachable proxy with nothing to serve: the one line that tells a new install what to do next.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No accounts yet — add a Claude subscription or an API key.").font(.system(size: 12))
            Button("Open Accounts…") {
                NSApp.sendAction(#selector(AppDelegate.showAccountsSettings), to: nil, from: nil)
            }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: header

    @ViewBuilder
    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(store.isDown ? Level.orange.color : (store.status == nil ? Color.gray : Level.green.color)).frame(width: 6, height: 6)
                accountMenu
                Spacer()
                Button { store.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh (⌘R)").keyboardShortcut("r")
                Button { NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil) } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings (⌘,)").keyboardShortcut(",")
            }
            Text(subline(now: now)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var accountMenu: some View {
        if snapshotMode {
            HStack(spacing: 4) {
                Text(store.status?.currentAccount.map(store.displayName) ?? "No current account").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        } else {
            accountMenuControl
        }
    }

    private var accountMenuControl: some View {
        Menu {
            if let status = store.status {
                ForEach(status.accountsByPriority, id: \.name) { a in
                    Button {
                        store.switchTo(a.name)
                    } label: {
                        let mark = a.name == status.currentAccount ? "✓ " : (a.name == status.effectiveDefaultTarget ? "→ " : "   ")
                        let why = UnavailableText.label(a.unavailable).map { " · \($0)" } ?? ""
                        Text(mark + store.displayName(a.name) + why)
                    }
                }
                if status.accounts.count > 1 {
                    Divider()
                    Button("Next available account  \(HotKeyCenter.Key.nextAccount.title)") { store.switchToNextAvailable() }
                }
            }
        } label: {
            Text(store.status?.currentAccount.map(store.displayName) ?? "No current account").font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible)
        .frame(maxWidth: 240, alignment: .leading)
        .disabled(store.isDown || !store.switchSupported)
        .help(store.isDown ? "The proxy is not reachable" : store.switchSupported ? "Switch the current account" : "This proxy version cannot switch accounts")
    }

    /// Freshness first: it is the part that changes.
    private func subline(now: Date) -> String {
        var parts: [String] = []
        if let t = store.lastSuccessAt { parts.append("updated \(Derived.formatDuration(now.timeIntervalSince(t))) ago") }
        if let n = store.status?.accounts.count { parts.append("\(n) account\(n == 1 ? "" : "s")") }
        parts.append(store.endpoint.label)
        if let loop = store.status?.server?.eventLoop, loop.lagging { parts.append("loop lag \(loop.lastLagMs) ms") }
        if let pool = store.status?.upstreamPool, pool.queued > 0 { parts.append("\(pool.queued) queued upstream") }
        if let up = store.status?.server?.uptimeSeconds { parts.append("up \(Derived.formatDuration(TimeInterval(up)))") }
        return parts.joined(separator: " · ")
    }

    // MARK: banners

    /// At most three, worst first, and a banner with a button is never the one dropped.
    @ViewBuilder
    private var banners: some View {
        let items = bannerItems
        if !items.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, b in b }
                if items.count > 3 {
                    Text("+\(items.count - 3) more").font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var bannerItems: [Banner] {
        var out: [Banner] = []
        func rank(_ b: Banner) -> Int {
            let severity = b.kind == .bad ? 0 : b.kind == .warn ? 1 : b.kind == .ok ? 2 : 3
            return severity * 2 + (b.action == nil ? 1 : 0)
        }
        if case .down(let since, let error) = store.connection {
            out.append(Banner(kind: .bad, text: "\(error.message) — showing data from \(Derived.formatDuration(Date().timeIntervalSince(since))) ago", action: { store.refreshNow() }, actionTitle: "Retry"))
        }
        if let status = store.status {
            for p in Derived.problems(status) { out.append(Banner(kind: p.severity == .bad ? .bad : .warn, text: p.text)) }
            if Derived.isHold(status) {
                out.append(Banner(kind: .bad, text: "No account can serve — \(Derived.holdReason(status))."))
            } else if let cur = status.current, let why = UnavailableText.label(cur.unavailable), !Derived.currentBlockedButRotated(status) {
                // Traffic that already moved to another account is ordinary rotation (the routing row says so); this is the stuck case.
                out.append(Banner(kind: .warn, text: "Rotation cannot use \(store.displayName(cur.name)): \(why), and no other account can take over."))
            }
            if !status.hasDefaultTarget, !status.routes.isEmpty, !store.dismissedNotices.contains("skew") {
                out.append(Banner(kind: .info, text: "Proxy older than 1.1.18 — routing targets are estimated from the current account. `teamclaude update` clears this.",
                                  onDismiss: { store.dismissedNotices.insert("skew") }))
            }
        }
        if let text = store.restartPendingText {
            out.append(Banner(kind: .warn, text: text, action: { Task { await store.restartService() } }, actionTitle: "Restart"))
        }
        // Stable sort: severity, then actionable first; the toast always leads because it answers what the user just did.
        out = out.enumerated().sorted { a, b in rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset }.map(\.element)
        if let toast = store.toast {
            out.insert(Banner(kind: toast.kind == .error ? .bad : toast.kind == .warn ? .warn : toast.kind == .ok ? .ok : .info, text: toast.text), at: 0)
        }
        return out
    }

    // MARK: current account

    @ViewBuilder
    private func currentCard(_ a: Account, status: StatusSnapshot, now: Date) -> some View {
        let tier = store.quota?.account(named: a.name)?.tier
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Current account", trailing: [Derived.tierBadge(tier), a.priority != 0 ? "prio \(a.priority)" : nil].compactMap { $0 }.joined(separator: " · "))
            Card {
                if a.isApiKey {
                    let tokens = Derived.usedFraction(remaining: a.quota.tokensRemaining, limit: a.quota.tokensLimit)
                    let requests = Derived.usedFraction(remaining: a.quota.requestsRemaining, limit: a.quota.requestsLimit)
                    UsageRow(title: "Tokens", subtitle: a.quota.tokensLimit.map { "of \(Derived.safeInt($0))" }, tag: nil, ratio: tokens, resetAt: a.quota.resetsAt, window: nil, threshold: status.thresholdFor(bucket: "tokens"), cap: nil, resetStyle: store.prefs.resetStyle, now: now)
                    UsageRow(title: "Requests", subtitle: a.quota.requestsLimit.map { "of \(Derived.safeInt($0))" }, tag: nil, ratio: requests, resetAt: a.quota.resetsAt, window: nil, threshold: status.thresholdFor(bucket: "requests"), cap: nil, resetStyle: store.prefs.resetStyle, now: now)
                } else if let backend = a.quota.backend {
                    UsageRow(title: backend.label, subtitle: backend.text, tag: nil, ratio: backend.utilization, resetAt: nil, window: nil, threshold: nil, cap: nil, resetStyle: store.prefs.resetStyle, now: now)
                } else if a.quota.isEmpty {
                    Text("Quota unknown (no traffic observed yet)").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    UsageRow(title: "Session", subtitle: "5-hour window", tag: nil, ratio: a.quota.unified5h, resetAt: a.quota.unified5hReset, window: Window.fiveHour,
                             threshold: status.thresholdFor(bucket: Buckets.fiveHour), cap: capFor(a, Buckets.fiveHour), resetStyle: store.prefs.resetStyle, now: now)
                    UsageRow(title: "All models", subtitle: nil, tag: "Weekly", ratio: a.quota.unified7d, resetAt: a.quota.unified7dReset, window: Window.sevenDay,
                             threshold: status.thresholdFor(bucket: Buckets.weekly), cap: capFor(a, Buckets.weekly), resetStyle: store.prefs.resetStyle, now: now)
                    ForEach(Derived.scopedWeeklyRows(a.quota), id: \.family) { row in
                        let bucket = row.family == "fable" ? Buckets.fable : row.family == "sonnet" ? Buckets.sonnet : Buckets.weekly
                        UsageRow(title: row.label, subtitle: nil, tag: "Weekly", ratio: row.utilization, resetAt: row.resetAt, window: Window.sevenDay,
                                 threshold: status.thresholdFor(bucket: bucket), cap: capFor(a, bucket), resetStyle: store.prefs.resetStyle, now: now,
                                 footNote: sharedNote(a, row.family))
                    }
                }
                if let spend = a.quota.spend, spend.enabled {
                    // Overage is the one bucket that costs money instead of quota; the bar is used against the limit.
                    let used = spend.usedMinor ?? 0
                    let ratio = spend.limitMinor.flatMap { $0 > 0 ? used / $0 : nil }
                    let usedText = Derived.formatMoney(minor: used, currency: spend.currency, exponent: spend.exponent)
                    let limitText = spend.limitMinor.map { " / " + Derived.formatMoney(minor: $0, currency: spend.currency, exponent: spend.exponent) } ?? " · no limit"
                    UsageRow(title: "Extra usage", subtitle: usedText + limitText, tag: "$", ratio: ratio, resetAt: nil, window: nil, threshold: nil, cap: nil, resetStyle: store.prefs.resetStyle, now: now)
                }
                if let next = Derived.nextUp(status), !next.isCurrent || status.accounts.count > 1 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.accentColor)
                        Text(next.isCurrent ? "Next request stays here" : "Next → \(store.compactName(next.name))").font(.system(size: 11, weight: .medium))
                        Text("· " + next.reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .help(next.isCurrent ? "The next unrouted request goes to the current account. \(next.reason)" : "The next unrouted request goes to \(next.name). \(next.reason)")
                }
            }
        }
    }

    private func capFor(_ a: Account, _ bucket: String) -> Double? {
        if let n = a.maxUsage.double { return n }
        if let table = a.maxUsage.object { return (table[bucket] ?? table["default"])?.double }
        return nil
    }

    private func sharedNote(_ a: Account, _ family: String) -> String? {
        guard let q = store.quota?.account(named: a.name) else { return nil }
        let key = family == "fable" ? "weeklyFable" : family == "sonnet" ? "weeklySonnet" : nil
        guard let key, q.buckets[key]?.source == Buckets.weekly else { return nil }
        return "shares the weekly bucket"
    }

    // MARK: fleet

    @ViewBuilder
    private func fleetCard(_ quota: QuotaSnapshot, status: StatusSnapshot, now: Date) -> some View {
        let known = quota.aggregate["fiveHour"]?.knownAccounts ?? 0
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Fleet", trailing: "weighted by tier · \(known)/\(quota.accounts.count) known" + (quota.unknownTiers.isEmpty ? "" : " · \(quota.unknownTiers.count) tier unknown"))
            Card {
                fleetRow("Session", quota, key: "fiveHour", window: Window.fiveHour, threshold: status.thresholdFor(bucket: Buckets.fiveHour), now: now)
                fleetRow("Weekly", quota, key: "weeklyShared", window: Window.sevenDay, threshold: status.thresholdFor(bucket: Buckets.weekly), now: now)
                if quota.accounts.contains(where: { $0.buckets["weeklyFable"]?.source == Buckets.fable }) {
                    fleetRow("Fable", quota, key: "weeklyFable", window: Window.sevenDay, threshold: status.thresholdFor(bucket: Buckets.fable), now: now)
                }
                if quota.accounts.contains(where: { $0.buckets["weeklySonnet"]?.source == Buckets.sonnet }) {
                    fleetRow("Sonnet", quota, key: "weeklySonnet", window: Window.sevenDay, threshold: status.thresholdFor(bucket: Buckets.sonnet), now: now)
                } else if quota.aggregate["weeklySonnet"] != nil {
                    Text("Sonnet · shares the weekly bucket").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                resetStrip(quota, status: status, now: now)
            }
        }
    }

    /// The fleet bar coloured by the same pace rule as an account bar, with the tier-weighted elapsed tick.
    @ViewBuilder
    private func fleetRow(_ label: String, _ quota: QuotaSnapshot, key: String, window: TimeInterval, threshold: Double, now: Date) -> some View {
        if let agg = quota.aggregate[key], let u = agg.utilization {
            let elapsed = Derived.fleetElapsed(quota, key: key, window: window, now: now)
            let level = Derived.level(ratio: u, resetAt: agg.nextResetAt, window: window, threshold: threshold, now: now)
            HStack(spacing: 10) {
                Text(label).font(.system(size: 11)).frame(width: 56, alignment: .leading)
                QuotaBar(ratio: u, level: level, elapsed: elapsed, cap: nil)
                Text("\(Derived.percentInt(u))%").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(level.color).frame(width: 40, alignment: .trailing).fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Fleet \(label) \(Derived.percentInt(u)) percent")
        }
    }

    /// Every account's coming resets, soonest first: when capacity returns, and whose.
    @ViewBuilder
    private func resetStrip(_ quota: QuotaSnapshot, status: StatusSnapshot, now: Date) -> some View {
        let entries = Derived.resetTimeline(quota, status: status, now: now, limit: 6)
        VStack(alignment: .leading, spacing: 3) {
            if entries.isEmpty {
                Text("No reset in sight · " + warmText(quota)).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                // One wrapped line: "↑" marks a reset that brings an account back into rotation.
                let line = entries.map { e in
                    (e.freesCapacity ? "↑ " : "") + "\(store.compactName(e.account)) \(e.bucket) \(Derived.formatReset(e.resetAt, now: now))"
                }.joined(separator: "  ·  ")
                Text("Resets: " + line).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .help(entries.map { "\($0.account) · \($0.bucket) resets \(Derived.formatResetLong($0.resetAt, style: .both, now: now))" + ($0.freesCapacity ? " · brings the account back into rotation" : "") }.joined(separator: "\n"))
                Text(warmText(quota)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func warmText(_ quota: QuotaSnapshot) -> String {
        let warm = quota.warmup
        guard warm["enabled"].bool == true else { return "Keep-warm off" }
        var s = "Keep-warm \(warm["mode"].string ?? "on")"
        if let next = warm["nextWarmupAt"].date { s += " · next in \(Derived.formatReset(next))" }
        return s
    }

    // MARK: routing

    @ViewBuilder
    private func routing(_ rows: [RouteRow], status: StatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: "Routing")
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 6) {
                    Circle().fill(Color.route(r.color)).frame(width: 6, height: 6)
                    Text(r.label).font(.system(size: 11))
                    Text("→").foregroundStyle(.secondary).font(.system(size: 11))
                    Text(r.blocked ? "blocked" : r.target.map(store.compactName) ?? "—").font(.system(size: 11)).foregroundStyle(r.blocked ? .red : .primary).lineLimit(1)
                    Spacer()
                    Text(routeNote(r)).font(.system(size: 10)).foregroundStyle(r.pinMismatch ? .orange : .secondary).lineLimit(1)
                }
                .help(r.ineligible.isEmpty ? "" : "Not eligible: \(r.ineligible.joined(separator: ", "))")
            }
        }
    }

    private func routeNote(_ r: RouteRow) -> String {
        switch r.kind {
        case .route:
            if r.pinMismatch { return "pinned to \(r.pinned ?? "") (not eligible)" }
            if r.pinned != nil { return "pinned" }
            let total = r.eligible.count + r.ineligible.count
            return total > 0 ? "\(r.eligible.count) of \(total) eligible" : ""
        case .default:
            if let why = UnavailableText.label(r.currentUnavailable), r.target != r.current { return "current \(r.current.map(store.compactName) ?? "") is blocked: \(why)" }
            if r.target == r.current { return "current" }
            return r.target == nil ? "" : "outranks \(r.current.map(store.compactName) ?? "")"
        }
    }

    // MARK: accounts (Ops-Board style table)

    @ViewBuilder
    private func accounts(_ status: StatusSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Accounts", trailing: status.sessions.map(Derived.formatSessions))
            AccountsTable(status: status, quota: store.freshQuota, now: now)
        }
    }

    // MARK: sessions (with proxy.sessionDetail)

    @ViewBuilder
    private func sessions(_ status: StatusSnapshot, now: Date) -> some View {
        if let info = status.sessions {
            let active = info.items.filter(\.active).sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
            if !active.isEmpty {
                SessionsSection(items: Array(active.prefix(8)), total: active.count, status: status, now: now)
            } else if info.active > 0, info.items.isEmpty, !store.dismissedNotices.contains("sessionDetail") {
                HStack(spacing: 6) {
                    Text("\(info.active) active session\(info.active == 1 ? "" : "s") — which account each one uses needs per-session detail.").font(.system(size: 10)).foregroundStyle(.secondary)
                    Button("Turn on") { Task { await store.apply(.json(path: ["proxy", "sessionDetail"], value: .bool(true), applies: .live), label: "Per-session detail") } }.controlSize(.mini)
                    Button { store.dismissedNotices.insert("sessionDetail") } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: rotation history

    @ViewBuilder
    private func rotationHistory(now: Date) -> some View {
        let events = store.prefs.rotationLog.latest
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Rotation", trailing: "\(store.prefs.rotationLog.count(within: 86400, now: now)) in 24 h")
                ForEach(events.prefix(5)) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Derived.formatDuration(now.timeIntervalSince(e.at)) + " ago").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        Text("\(e.from.map(store.compactName) ?? "—") → \(store.compactName(e.to))").font(.system(size: 11, weight: e.manual ? .regular : .medium)).lineLimit(1)
                        if let reason = e.reason { Text(reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer(minLength: 0)
                    }
                    .help(e.at.formatted(date: .abbreviated, time: .shortened) + (e.reason.map { " · \($0)" } ?? "") + (e.manual ? " · manual" : ""))
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button("Dashboard") { Actions.openDashboard(store) }.keyboardShortcut("d")
            Button("Attach") { Actions.attachInTerminal(store) }.keyboardShortcut("t")
            Spacer()
            Button("Settings…") { NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil) }
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
    }
}

/// Which Claude Code session is pinned to which account: client/project, the pins, in-flight work.
struct SessionsSection: View {
    @Environment(AppStore.self) private var store
    var items: [SessionItem]
    var total: Int
    var status: StatusSnapshot
    var now: Date
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionHeader(title: "Sessions", trailing: "\(total) active")
                Button(expanded ? "Hide" : "Show") { expanded.toggle() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if expanded {
                ForEach(items, id: \.id) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(s.project ?? s.client ?? s.shortId).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
                        Text("→ " + pinnedAccounts(s)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        if s.inFlight > 0 { Chip(text: "\(s.inFlight) in flight", color: Level.green.color) }
                        if s.starved > 0 { Chip(text: "starved \(s.starved)", color: Level.red.color) }
                        Text(s.lastSeen.map { Derived.formatDuration(now.timeIntervalSince($0)) + " ago" } ?? "").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .help("session \(s.id)\n\(s.requests) requests · " + pinnedAccounts(s) + (s.context.isEmpty ? "" : "\ncontext " + s.context.map { "\(Derived.bucketLabel($0.key)) \($0.value / 1000)k" }.sorted().joined(separator: ", ")))
                }
                if total > items.count { Text("+\(total - items.count) more").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
    }

    private func pinnedAccounts(_ s: SessionItem) -> String {
        let names = s.pins.sorted { $0.key < $1.key }.compactMap { bucket, index -> String? in
            guard status.accounts.indices.contains(index) else { return nil }
            return "\(store.compactName(status.accounts[index].name)) (\(Derived.bucketLabel(bucket)))"
        }
        return names.isEmpty ? "unpinned" : names.joined(separator: ", ")
    }
}
