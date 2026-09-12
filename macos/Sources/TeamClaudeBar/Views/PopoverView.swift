import SwiftUI
import AppKit
import TeamClaudeCore

struct PopoverView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.snapshotMode) private var snapshotMode

    static let width = StatusItemController.popoverWidth

    var body: some View {
        // The language read makes a change re-render every `L()` label without a relaunch.
        let _ = store.prefs.language
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
                        // The accounts table is the one place every number lives; the current account is its highlighted row.
                        accounts(status, now: now)
                        // One account: the fleet is that account, already in the row above.
                        if status.accounts.count > 1, let quota = store.freshQuota { fleetCard(quota, status: status, now: now) }
                        let rows = Derived.routeRows(status)
                        if !rows.isEmpty { routing(rows, status: status) }
                        sessions(status, now: now)
                        rotationHistory(now: now)
                    } else {
                        Text(store.isDown ? L("The proxy is not reachable. Start it with `teamclaude service install` or `teamclaude server`.") : L("Connecting to the proxy…"))
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
            Text(L("No accounts yet — add a Claude subscription or an API key.")).font(.system(size: 12))
            Button(L("Open Accounts…")) {
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
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Refresh (⌘R)")).keyboardShortcut("r")
                Button { NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil) } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Settings (⌘,)")).keyboardShortcut(",")
            }
            Text(subline(now: now)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var accountMenu: some View {
        if snapshotMode {
            HStack(spacing: 4) {
                Text(currentTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
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
                        let mark = status.isCurrent(a) ? "✓ " : (status.isNext(a) ? "→ " : "   ")
                        let why = UnavailableText.label(a.unavailable).map { " · \($0)" } ?? ""
                        Text(mark + store.displayName(a.name) + why)
                    }
                }
                if status.accounts.count > 1 {
                    Divider()
                    Button(L("Next available account") + "  \(HotKeyCenter.Key.nextAccount.title)") { store.switchToNextAvailable() }
                }
            }
        } label: {
            Text(currentTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible)
        .frame(maxWidth: 240, alignment: .leading)
        .disabled(store.isDown || !store.switchSupported)
        .help(store.isDown ? L("The proxy is not reachable") : store.switchSupported ? L("Switch the current account") : L("This proxy version cannot switch accounts"))
    }

    /// The account carrying traffic; a mixed fleet names one per provider, as the dashboard does.
    private var currentTitle: String {
        guard let status = store.status else { return L("No current account") }
        if status.currentAccounts.count > 1 {
            return status.providers.compactMap { p in status.currentAccounts[p].map { Providers.label(p) + ": " + store.compactName($0) } }.joined(separator: " · ")
        }
        return status.currentAccount.map(store.displayName) ?? L("No current account")
    }

    /// Freshness first: it is the part that changes.
    private func subline(now: Date) -> String {
        var parts: [String] = []
        if let t = store.lastSuccessAt { parts.append(L("updated %@ ago", Derived.formatDuration(now.timeIntervalSince(t)))) }
        if let n = store.status?.accounts.count { parts.append(n == 1 ? L("1 account") : L("%d accounts", n)) }
        parts.append(store.endpoint.label)
        if let loop = store.status?.server?.eventLoop, loop.lagging { parts.append(L("loop lag %d ms", loop.lastLagMs)) }
        if let pool = store.status?.upstreamPool, pool.queued > 0 { parts.append(L("%d queued upstream", pool.queued)) }
        if let up = store.status?.server?.uptimeSeconds { parts.append(L("up %@", Derived.formatDuration(TimeInterval(up)))) }
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
                    Text(L("+%d more", items.count - 3)).font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
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
            out.append(Banner(kind: .bad, text: L("%@ — showing data from %@ ago", error.message, Derived.formatDuration(Date().timeIntervalSince(since))), action: { store.refreshNow() }, actionTitle: L("Retry")))
        }
        if let status = store.status {
            for p in Derived.problems(status) { out.append(Banner(kind: p.severity == .bad ? .bad : .warn, text: p.text)) }
            if Derived.isHold(status) {
                out.append(Banner(kind: .bad, text: L("No account can serve — %@.", Derived.holdReason(status))))
            } else if let cur = status.current, let why = UnavailableText.label(cur.unavailable), !Derived.currentBlockedButRotated(status) {
                // Traffic that already moved to another account is ordinary rotation (the routing row says so); this is the stuck case.
                out.append(Banner(kind: .warn, text: L("Rotation cannot use %@: %@, and no other account can take over.", store.displayName(cur.name), why)))
            }
            if !status.hasDefaultTarget, !status.routes.isEmpty, !store.dismissedNotices.contains("skew") {
                out.append(Banner(kind: .info, text: L("Proxy older than 1.1.18 — routing targets are estimated from the current account. `teamclaude update` clears this."),
                                  onDismiss: { store.dismissedNotices.insert("skew") }))
            }
        }
        if let text = store.restartPendingText {
            out.append(Banner(kind: .warn, text: text, action: { Task { await store.restartService() } }, actionTitle: L("Restart")))
        }
        // Stable sort: severity, then actionable first; the toast always leads because it answers what the user just did.
        out = out.enumerated().sorted { a, b in rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset }.map(\.element)
        if let toast = store.toast {
            out.insert(Banner(kind: toast.kind == .error ? .bad : toast.kind == .warn ? .warn : toast.kind == .ok ? .ok : .info, text: toast.text), at: 0)
        }
        return out
    }

    // MARK: fleet

    @ViewBuilder
    private func fleetCard(_ quota: QuotaSnapshot, status: StatusSnapshot, now: Date) -> some View {
        let known = quota.aggregate["fiveHour"]?.knownAccounts ?? 0
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L("Fleet"), trailing: L("weighted by tier · %d/%d known", known, quota.accounts.count) + (quota.unknownTiers.isEmpty ? "" : " · " + L("%d without a tier", quota.unknownTiers.count)))
            Card {
                fleetRow(L("Session"), quota, key: "fiveHour", window: Window.fiveHour, threshold: status.thresholdFor(bucket: Buckets.fiveHour), now: now)
                fleetRow(L("Weekly"), quota, key: "weeklyShared", window: Window.sevenDay, threshold: status.thresholdFor(bucket: Buckets.weekly), now: now)
                if quota.accounts.contains(where: { $0.buckets["weeklyFable"]?.source == Buckets.fable }) {
                    fleetRow("Fable", quota, key: "weeklyFable", window: Window.sevenDay, threshold: status.thresholdFor(bucket: Buckets.fable), now: now)
                }
                if quota.accounts.contains(where: { $0.buckets["weeklySonnet"]?.source == Buckets.sonnet }) {
                    fleetRow("Sonnet", quota, key: "weeklySonnet", window: Window.sevenDay, threshold: status.thresholdFor(bucket: Buckets.sonnet), now: now)
                } else if quota.aggregate["weeklySonnet"] != nil {
                    Text(L("Sonnet · shares the weekly bucket")).font(.system(size: 10)).foregroundStyle(.secondary)
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
            .accessibilityLabel(L("Fleet %@ %d percent", label, Derived.percentInt(u)))
        }
    }

    /// Every account's coming resets, soonest first: when capacity returns, and whose.
    @ViewBuilder
    private func resetStrip(_ quota: QuotaSnapshot, status: StatusSnapshot, now: Date) -> some View {
        let entries = Derived.resetTimeline(quota, status: status, now: now, limit: 6)
        VStack(alignment: .leading, spacing: 3) {
            if entries.isEmpty {
                Text(L("No reset in sight") + " · " + warmText(quota)).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                // One wrapped line: "↑" marks a reset that brings an account back into rotation.
                let line = entries.map { e in
                    (e.freesCapacity ? "↑ " : "") + "\(store.compactName(e.account)) \(e.bucket) \(Derived.formatReset(e.resetAt, now: now))"
                }.joined(separator: "  ·  ")
                Text(L("Resets:") + " " + line).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .help(entries.map { L("%@ · %@: %@", $0.account, $0.bucket, Derived.formatResetLong($0.resetAt, style: .both, now: now)) + ($0.freesCapacity ? " · " + L("brings the account back into rotation") : "") }.joined(separator: "\n"))
                Text(warmText(quota)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func warmText(_ quota: QuotaSnapshot) -> String {
        let warm = quota.warmup
        guard warm["enabled"].bool == true else { return L("Keep-warm off") }
        var s = L("Keep-warm %@", warm["mode"].string.map { L($0) } ?? L("on"))
        if let next = warm["nextWarmupAt"].date { s += " · " + L("next in %@", Derived.formatReset(next)) }
        return s
    }

    // MARK: routing

    @ViewBuilder
    private func routing(_ rows: [RouteRow], status: StatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: L("Routing"))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 6) {
                    Circle().fill(Color.route(r.color)).frame(width: 6, height: 6)
                    Text(r.label).font(.system(size: 11))
                    Text("→").foregroundStyle(.secondary).font(.system(size: 11))
                    Text(r.blocked ? L("blocked") : r.target.map(store.compactName) ?? "—").font(.system(size: 11)).foregroundStyle(r.blocked ? .red : .primary).lineLimit(1)
                    Spacer()
                    Text(routeNote(r)).font(.system(size: 10)).foregroundStyle(r.pinMismatch ? .orange : .secondary).lineLimit(1)
                }
                .help(r.ineligible.isEmpty ? "" : L("Not eligible: %@", r.ineligible.joined(separator: ", ")))
            }
        }
    }

    private func routeNote(_ r: RouteRow) -> String {
        switch r.kind {
        case .route:
            if r.pinMismatch { return L("pinned to %@ (not eligible)", r.pinned ?? "") }
            if r.pinned != nil { return L("pinned") }
            let total = r.eligible.count + r.ineligible.count
            return total > 0 ? L("%d of %d eligible", r.eligible.count, total) : ""
        case .default:
            if let why = UnavailableText.label(r.currentUnavailable), r.target != r.current { return L("current %@ is blocked: %@", r.current.map(store.compactName) ?? "", why) }
            if r.target == r.current { return L("current") }
            return r.target == nil ? "" : L("outranks %@", r.current.map(store.compactName) ?? "")
        }
    }

    // MARK: accounts (Ops-Board style table)

    @ViewBuilder
    private func accounts(_ status: StatusSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L("Accounts"), trailing: status.sessions.map(Derived.formatSessions))
            AccountsTable(status: status, quota: store.freshQuota, now: now)
            if status.accounts.count > 1, let next = Derived.nextUp(status) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.accentColor)
                    Text(next.isCurrent ? L("Next request stays on %@", store.compactName(next.name)) : L("Next → %@", store.compactName(next.name))).font(.system(size: 11, weight: .medium))
                    Text("· " + next.reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.leading, 2)
                .help(L("The next unrouted request goes to %@.", next.name) + " " + next.reason)
            }
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
                    Text(L("%d active sessions — which account each one uses needs per-session detail.", info.active)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Button(L("Turn on")) { Task { await store.apply(.json(path: ["proxy", "sessionDetail"], value: .bool(true), applies: .live), label: L("Per-session detail")) } }.controlSize(.mini)
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
                SectionHeader(title: L("Rotation"), trailing: L("%d in 24 h", store.prefs.rotationLog.count(within: 86400, now: now)))
                ForEach(events.prefix(5)) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(L("%@ ago", Derived.formatDuration(now.timeIntervalSince(e.at)))).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        Text("\(e.from.map(store.compactName) ?? "—") → \(store.compactName(e.to))").font(.system(size: 11, weight: e.manual ? .regular : .medium)).lineLimit(1)
                        if let reason = e.reason { Text(reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer(minLength: 0)
                    }
                    .help(e.at.formatted(date: .abbreviated, time: .shortened) + (e.reason.map { " · \($0)" } ?? "") + (e.manual ? " · " + L("manual") : ""))
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button(L("Dashboard")) { Actions.openDashboard(store) }.keyboardShortcut("d")
            Button(L("Attach")) { Actions.attachInTerminal(store) }.keyboardShortcut("t")
            Spacer()
            Button(L("Settings…")) { NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil) }
            Button(L("Quit")) { NSApp.terminate(nil) }.keyboardShortcut("q")
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
                SectionHeader(title: L("Sessions"), trailing: L("%d active", total))
                Button(expanded ? L("Hide") : L("Show")) { expanded.toggle() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if expanded {
                ForEach(items, id: \.id) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(s.project ?? s.client ?? s.shortId).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
                        Text("→ " + pinnedAccounts(s)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        if s.inFlight > 0 { Chip(text: L("%d in flight", s.inFlight), color: Level.green.color) }
                        if s.starved > 0 { Chip(text: L("starved %d", s.starved), color: Level.red.color) }
                        Text(s.lastSeen.map { L("%@ ago", Derived.formatDuration(now.timeIntervalSince($0))) } ?? "").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .help(sessionHelp(s))
                }
                if total > items.count { Text(L("+%d more", total - items.count)).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
    }

    private func sessionHelp(_ s: SessionItem) -> String {
        var text = L("session %@", s.id) + "\n" + L("%d requests", s.requests) + " · " + pinnedAccounts(s)
        if !s.context.isEmpty {
            let ctx = s.context.map { "\(Derived.bucketLabel($0.key)) \($0.value / 1000)k" }.sorted().joined(separator: ", ")
            text += "\n" + L("context") + " " + ctx
        }
        return text
    }

    private func pinnedAccounts(_ s: SessionItem) -> String {
        let names = s.pins.sorted { $0.key < $1.key }.compactMap { bucket, index -> String? in
            guard status.accounts.indices.contains(index) else { return nil }
            return "\(store.compactName(status.accounts[index].name)) (\(Derived.bucketLabel(bucket)))"
        }
        return names.isEmpty ? L("unpinned") : names.joined(separator: ", ")
    }
}
