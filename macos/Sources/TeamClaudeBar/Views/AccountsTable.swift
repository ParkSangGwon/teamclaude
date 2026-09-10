import SwiftUI
import AppKit
import TeamClaudeCore

/// Per-account rows as a dense table: one column per bucket (session, weekly,
/// and the per-family weeks when any account has one), a segmented bar with the
/// number and reset under it — the TUI's account table, in the popover.
struct AccountsTable: View {
    @Environment(AppStore.self) private var store
    var status: StatusSnapshot
    var quota: QuotaSnapshot?
    var now: Date

    static let wideCol: CGFloat = 62
    static let narrowCol: CGFloat = 40
    static let gap: CGFloat = 4
    static let menuWidth: CGFloat = 22

    /// A family column only exists when some account meters that family separately (the fleet card's rule).
    var showFable: Bool { quota?.accounts.contains { $0.buckets["weeklyFable"]?.source == Buckets.fable } ?? status.accounts.contains { $0.quota.unified7dFable != nil } }
    var showSonnet: Bool { quota?.accounts.contains { $0.buckets["weeklySonnet"]?.source == Buckets.sonnet } ?? status.accounts.contains { $0.quota.unified7dSonnet != nil } }

    /// Whatever the bucket columns do not need goes to the name.
    var nameWidth: CGFloat {
        let inner = StatusItemController.popoverWidth - 28 - 20 - Self.menuWidth
        let cols = 2 * Self.wideCol + (showFable ? Self.narrowCol : 0) + (showSonnet ? Self.narrowCol : 0)
        let gaps = Self.gap * CGFloat(3 + (showFable ? 1 : 0) + (showSonnet ? 1 : 0))
        return max(90, inner - cols - gaps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(status.accountsByPriority, id: \.name) { a in
                Divider().padding(.vertical, 2)
                AccountTableRow(account: a, status: status, quotaAccount: quota?.account(named: a.name), now: now,
                                nameWidth: nameWidth, showFable: showFable, showSonnet: showSonnet)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: Self.gap) {
            Text("ACCOUNT").frame(width: nameWidth, alignment: .leading)
            Text("SES").frame(width: Self.wideCol, alignment: .leading)
            Text("WK").frame(width: Self.wideCol, alignment: .leading)
            if showFable { Text("F7").frame(width: Self.narrowCol, alignment: .leading) }
            if showSonnet { Text("S7").frame(width: Self.narrowCol, alignment: .leading) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
    }
}

struct AccountTableRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.snapshotMode) private var snapshotMode
    var account: Account
    var status: StatusSnapshot
    var quotaAccount: QuotaAccount?
    var now: Date
    var nameWidth: CGFloat
    var showFable: Bool
    var showSonnet: Bool
    @State private var priorityText = ""
    @State private var askPriority = false
    @State private var confirmRemove = false

    var isCurrent: Bool { account.name == status.currentAccount }
    var isNext: Bool { status.effectiveDefaultTarget == account.name && !isCurrent }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: AccountsTable.gap) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Image(systemName: isNext ? "arrow.turn.down.right" : "arrowtriangle.right.fill").font(.system(size: 7)).foregroundStyle(isCurrent || isNext ? Color.accentColor : Color.clear)
                        Text(store.compactName(account.name)).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        if let spend = account.quota.spend, spend.enabled { Chip(text: "$", color: (spend.usedMinor ?? 0) > 0 ? Level.orange.color : .secondary) }
                    }
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(statusColor).lineLimit(1)
                }
                .frame(width: nameWidth, alignment: .leading)
                .help(nameHelp)

                if account.isApiKey {
                    // The column headers say session/weekly; an API-key account has tokens and requests instead (the TUI relabels too).
                    let t = Derived.usedFraction(remaining: account.quota.tokensRemaining, limit: account.quota.tokensLimit)
                    let r = Derived.usedFraction(remaining: account.quota.requestsRemaining, limit: account.quota.requestsLimit)
                    cell(t, reset: account.quota.resetsAt, window: nil, bucket: "tokens", name: "Tokens", prefix: "Tok ", width: AccountsTable.wideCol, segments: 8)
                    cell(r, reset: account.quota.resetsAt, window: nil, bucket: "requests", name: "Requests", prefix: "Req ", width: AccountsTable.wideCol, segments: 8)
                    if showFable { placeholder(AccountsTable.narrowCol) }
                    if showSonnet { placeholder(AccountsTable.narrowCol) }
                } else {
                    cell(account.quota.unified5h, reset: account.quota.unified5hReset, window: Window.fiveHour, bucket: Buckets.fiveHour, name: "Session", width: AccountsTable.wideCol, segments: 8)
                    cell(account.quota.unified7d, reset: account.quota.unified7dReset, window: Window.sevenDay, bucket: Buckets.weekly, name: "Weekly", width: AccountsTable.wideCol, segments: 8)
                    if showFable { family(account.quota.unified7dFable, reset: account.quota.unified7dFableReset, bucket: Buckets.fable, name: "Fable weekly") }
                    if showSonnet { family(account.quota.unified7dSonnet, reset: account.quota.unified7dSonnetReset, bucket: Buckets.sonnet, name: "Sonnet weekly") }
                }
                Spacer(minLength: 0)
                if !snapshotMode { rowMenu } else { Image(systemName: "ellipsis.circle").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if let why = UnavailableText.label(account.unavailable) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
                    Text(why + holdSuffix).font(.system(size: 10)).lineLimit(1)
                }
                .foregroundStyle(account.unavailable == "error" || account.unavailable == "disabled" ? Level.red.color : Level.yellow.color)
                .padding(.leading, nameWidth + AccountsTable.gap)
            }
        }
        .padding(.vertical, 2)
        .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(account.name)\(isCurrent ? ", current" : isNext ? ", next" : ""), \(subtitle)")
        .alert("Priority for \(store.displayName(account.name))", isPresented: $askPriority) {
            TextField("0", text: $priorityText)
            Button("Set") { if let n = Int(priorityText) { Task { await store.setPriority(account.name, .number(n)) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Lower is preferred. A strictly lower value preempts a healthy current account.") }
        .confirmationDialog("Remove \(store.displayName(account.name))?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await store.removeAccount(account.name) } }
        } message: { Text(AppStore.removeAccountMessage) }
    }

    private var rowMenu: some View {
        Menu {
            if !isCurrent { Button("Make current") { store.switchTo(account.name) }.disabled(store.isDown || !store.switchSupported) }
            Button(account.disabled ? "Enable" : "Disable") { Task { await store.setEnabled(account.name, account.disabled) } }
            Button("Set priority…") { priorityText = String(account.priority); askPriority = true }
            Button("Move to top") { Task { await store.setPriority(account.name, .first) } }
            Button("Move to bottom") { Task { await store.setPriority(account.name, .last) } }
            Divider()
            Button("Copy name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(account.name, forType: .string) }
            Button("Remove…", role: .destructive) { confirmRemove = true }
        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 11)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(isCurrent ? "Actions" : "Make current, enable/disable, priority, remove")
    }

    @ViewBuilder
    private func cell(_ ratio: Double?, reset: Date?, window: TimeInterval?, bucket: String, name: String, prefix: String = "", width: CGFloat, segments: Int) -> some View {
        let resetLong = Derived.formatResetLong(reset, style: .both, now: now)
        VStack(alignment: .leading, spacing: 2) {
            if let ratio {
                let level = Derived.level(ratio: ratio, resetAt: reset, window: window, threshold: status.thresholdFor(bucket: bucket), now: now)
                SegmentBar(ratio: ratio, level: level, segments: segments, width: width - 4)
                Text(prefix + label(ratio, reset)).font(.system(size: 10, design: .monospaced)).foregroundStyle(level == .red ? Level.red.color : Color.secondary).lineLimit(1)
            } else {
                SegmentBar(ratio: 0, level: .green, segments: segments, width: width - 4)
                Text(prefix + "—").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, alignment: .leading)
        .help(ratio.map { "\(name) \(Derived.formatPercent($0))" + (resetLong.isEmpty ? "" : " · " + resetLong) } ?? "\(name) unknown")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ratio.map { "\(name) \(Derived.formatPercent($0))" + (resetLong.isEmpty ? "" : ", " + resetLong) } ?? "\(name) unknown")
    }

    @ViewBuilder
    private func family(_ ratio: Double?, reset: Date?, bucket: String, name: String) -> some View {
        if let ratio {
            let level = Derived.level(ratio: ratio, resetAt: reset, window: Window.sevenDay, threshold: status.thresholdFor(bucket: bucket), now: now)
            let resetLong = Derived.formatResetLong(reset, style: .both, now: now)
            VStack(alignment: .leading, spacing: 2) {
                SegmentBar(ratio: ratio, level: level, segments: 6, width: AccountsTable.narrowCol - 4)
                Text("\(Derived.percentInt(ratio))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(level == .red ? Level.red.color : Color.secondary)
            }
            .frame(width: AccountsTable.narrowCol, alignment: .leading)
            .help("\(name) \(Derived.formatPercent(ratio)) · \(resetLong)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name) \(Derived.formatPercent(ratio)), \(resetLong)")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                SegmentBar(ratio: 0, level: .green, segments: 6, width: AccountsTable.narrowCol - 4)
                Text("=wk").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .frame(width: AccountsTable.narrowCol, alignment: .leading)
            .help("\(name) shares the weekly bucket")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name) shares the weekly bucket")
        }
    }

    private func placeholder(_ width: CGFloat) -> some View {
        Text("—").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).frame(width: width, alignment: .leading).accessibilityHidden(true)
    }

    private func label(_ ratio: Double, _ reset: Date?) -> String {
        let r = Derived.formatReset(reset, now: now)
        return r.isEmpty ? "\(Derived.percentInt(ratio))%" : "\(Derived.percentInt(ratio))%·\(r)"
    }

    private var subtitle: String {
        var parts = [Derived.tierBadge(quotaAccount?.tier)]
        if account.disabled { parts.append("disabled") }
        else if account.status == "throttled", let until = account.rateLimitedUntil {
            let r = Derived.formatReset(until, now: now)
            parts.append(r.isEmpty ? "throttled" : "throttled \(r)")
        } else if account.status != "active" { parts.append(account.status) }
        if account.priority != 0 { parts.append("prio \(account.priority)") }
        if account.sessions > 0 { parts.append("\(account.sessions) sess" + Derived.formatSessionBuckets(account.sessionsByBucket)) }
        return parts.joined(separator: " · ")
    }

    /// Everything that does not fit the row: the full name, the organization, expiry pressure, the adaptive scorer's line.
    private var nameHelp: String {
        var lines = [account.name + (account.orgName.map { " · \($0)" } ?? "")]
        if isNext { lines.append("Next: the next unrouted request goes here") }
        if let p = account.pressure, p > 0 { lines.append("Expiry pressure \(String(format: "%.2f", p))/s") }
        if let row = status.adaptive.first(where: { $0.name == account.name }) { lines.append(Derived.formatAdaptive(row)) }
        if let spend = account.quota.spend, spend.enabled {
            let used = spend.usedMinor.map { Derived.formatMoney(minor: $0, currency: spend.currency, exponent: spend.exponent) } ?? "$0.00"
            let limit = spend.limitMinor.map { " / " + Derived.formatMoney(minor: $0, currency: spend.currency, exponent: spend.exponent) } ?? ""
            lines.append("Overage \(used)\(limit) this month")
        }
        return lines.joined(separator: "\n")
    }

    private var statusColor: Color {
        if account.disabled { return .secondary }
        switch account.status {
        case "active": return .secondary
        case "throttled": return Level.yellow.color
        default: return Level.red.color
        }
    }

    private var holdSuffix: String {
        if account.unavailable == "entitlement", let until = account.entitlementDeniedUntil {
            let r = Derived.formatReset(until, now: now)
            return r.isEmpty ? "" : " \(r)"
        }
        return ""
    }
}

/// Ten-ish segments, the TUI bar in miniature.
struct SegmentBar: View {
    var ratio: Double
    var level: Level
    var segments: Int
    var width: CGFloat

    var body: some View {
        let gap: CGFloat = 1
        let segW = (width - gap * CGFloat(segments - 1)) / CGFloat(segments)
        let filled = Int((min(1, max(0, ratio)) * Double(segments)).rounded(.up))
        HStack(spacing: gap) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < filled ? level.color : Color.primary.opacity(0.12))
                    .frame(width: segW, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}
