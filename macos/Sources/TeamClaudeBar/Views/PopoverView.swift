import SwiftUI
import AppKit
import TeamClaudeCore

struct PopoverView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 10) {
                header(now: now)
                Divider()
                banners
                if let status = store.status, status.accounts.isEmpty {
                    emptyState
                } else if let status = store.status {
                    if let current = status.current { currentCard(current, status: status, now: now) }
                    if let quota = store.freshQuota { fleetCard(quota, status: status, now: now) }
                    let rows = Derived.routeRows(status)
                    if !rows.isEmpty { routing(rows, status: status) }
                    accounts(status, now: now)
                } else {
                    Text(store.isDown ? "The proxy is not reachable. Start it with `teamclaude service install` or `teamclaude server`." : "Connecting to the proxy…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Divider()
                footer
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
        .frame(width: 300, alignment: .leading)
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
            }
        } label: {
            Text(store.status?.currentAccount.map(store.displayName) ?? "No current account").font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible)
        .frame(maxWidth: 200, alignment: .leading)
        .disabled(store.isDown || !store.switchSupported)
        .help(store.isDown ? "The proxy is not reachable" : store.switchSupported ? "Switch the current account" : "This proxy version cannot switch accounts")
    }

    /// Freshness first: it is the part that changes, and the part a 300 pt line used to cut off.
    private func subline(now: Date) -> String {
        var parts: [String] = []
        if let t = store.lastSuccessAt { parts.append("updated \(Derived.formatDuration(now.timeIntervalSince(t))) ago") }
        if let n = store.status?.accounts.count { parts.append("\(n) account\(n == 1 ? "" : "s")") }
        parts.append(store.endpoint.label)
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
            } else if let cur = status.current, let why = UnavailableText.label(cur.unavailable) {
                let target = status.effectiveDefaultTarget.map { " Requests go to \(store.displayName($0))." } ?? ""
                out.append(Banner(kind: .warn, text: "Rotation cannot use \(store.displayName(cur.name)): \(why).\(target)"))
            }
            if store.updateAvailable, let latest = store.latestVersion, !store.dismissedNotices.contains("update-\(latest)") {
                let text = store.updateRunning ? "Updating teamclaude to \(latest)…" : "teamclaude \(latest) is available (installed \(store.serverVersion ?? "?"))."
                out.append(Banner(kind: .info, text: text, action: store.updateRunning ? nil : { Task { await store.runUpdate() } }, actionTitle: store.updateRunning ? nil : "Update",
                                  onDismiss: { store.dismissedNotices.insert("update-\(latest)") }))
            } else if !status.hasDefaultTarget, store.status?.routes.isEmpty == false, !store.dismissedNotices.contains("skew") {
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
                if let spend = a.quota.spend, spend.enabled, let used = spend.usedMinor, used > 0 {
                    Text("Overage this month: \(Derived.formatMoney(minor: used, currency: spend.currency, exponent: spend.exponent))").font(.system(size: 10)).foregroundStyle(.orange)
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
                fleetRow("Session", quota.aggregate["fiveHour"], threshold: status.thresholdFor(bucket: Buckets.fiveHour))
                fleetRow("Weekly", quota.aggregate["weeklyShared"], threshold: status.thresholdFor(bucket: Buckets.weekly))
                if quota.accounts.contains(where: { $0.buckets["weeklyFable"]?.source == Buckets.fable }) {
                    fleetRow("Fable", quota.aggregate["weeklyFable"], threshold: status.thresholdFor(bucket: Buckets.fable))
                }
                if quota.accounts.contains(where: { $0.buckets["weeklySonnet"]?.source == Buckets.sonnet }) {
                    fleetRow("Sonnet", quota.aggregate["weeklySonnet"], threshold: status.thresholdFor(bucket: Buckets.sonnet))
                } else if quota.aggregate["weeklySonnet"] != nil {
                    Text("Sonnet · shares the weekly bucket").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(fleetFoot(quota, now: now)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func fleetRow(_ label: String, _ agg: Aggregate?, threshold: Double) -> some View {
        if let agg, let u = agg.utilization {
            let level: Level = u >= threshold ? .red : Derived.rawLevel(u, warn: store.prefs.warnLevel)
            HStack(spacing: 10) {
                Text(label).font(.system(size: 11)).frame(width: 56, alignment: .leading)
                QuotaBar(ratio: u, level: level, elapsed: nil, cap: nil)
                Text("\(Derived.percentInt(u))%").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(level.color).frame(width: 34, alignment: .trailing).fixedSize()
            }
        }
    }

    private func fleetFoot(_ quota: QuotaSnapshot, now: Date) -> String {
        var parts: [String] = []
        let next = quota.aggregate.values.compactMap(\.nextResetAt).min()
        if let next {
            let owner = quota.accounts.first(where: { acc in acc.buckets.values.contains(where: { $0.resetAt == next }) })
            let which: (String, String)? = owner.flatMap { acc in
                guard let entry = acc.buckets.first(where: { $0.value.resetAt == next }) else { return nil }
                return (entry.key == "fiveHour" ? "5-hour" : "weekly", acc.name)
            }
            let r = Derived.formatReset(next, now: now)
            if !r.isEmpty { parts.append("Next reset in \(r)" + (which.map { " (\(store.compactName($0.1)), \($0.0))" } ?? "")) }
        }
        let warm = quota.warmup
        if warm["enabled"].bool == true { parts.append("Keep-warm \(warm["mode"].string ?? "on")") } else { parts.append("Keep-warm off") }
        return parts.joined(separator: " · ")
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

