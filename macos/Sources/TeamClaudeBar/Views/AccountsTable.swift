import SwiftUI
import AppKit
import TeamClaudeCore

/// Per-account rows as a dense table: one column per bucket (session, weekly,
/// Fable, Sonnet), a segmented bar with the number and reset under it, and a
/// fleet total row at the bottom — the TUI's account table, in the popover.
struct AccountsTable: View {
    @Environment(AppStore.self) private var store
    var status: StatusSnapshot
    var quota: QuotaSnapshot?
    var now: Date

    static let nameWidth: CGFloat = 64
    static let wideCol: CGFloat = 46
    static let narrowCol: CGFloat = 30
    static let gap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(status.accountsByPriority, id: \.name) { a in
                Divider().padding(.vertical, 2)
                AccountTableRow(account: a, status: status, tier: quota?.account(named: a.name)?.tier, now: now)
            }
            if let quota, let five = quota.aggregate["fiveHour"] {
                Divider().padding(.vertical, 2)
                fleetRow(quota, five)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: Self.gap) {
            Text("ACCOUNT").frame(width: Self.nameWidth, alignment: .leading)
            Text("SES").frame(width: Self.wideCol, alignment: .leading)
            Text("WK").frame(width: Self.wideCol, alignment: .leading)
            Text("F7").frame(width: Self.narrowCol, alignment: .leading)
            Text("S7").frame(width: Self.narrowCol, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func fleetRow(_ quota: QuotaSnapshot, _ five: Aggregate) -> some View {
        HStack(spacing: Self.gap) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Fleet total").font(.system(size: 11, weight: .bold))
                Text("\(five.knownAccounts)/\(quota.accounts.count) · w\(Int(five.capacityWeight))").font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: Self.nameWidth, alignment: .leading)
            total(quota.aggregate["fiveHour"], threshold: status.switchThreshold).frame(width: Self.wideCol, alignment: .leading)
            total(quota.aggregate["weeklyShared"], threshold: status.switchThreshold).frame(width: Self.wideCol, alignment: .leading)
            familyTotal(quota, key: "weeklyFable", source: Buckets.fable, bucket: Buckets.fable).frame(width: Self.narrowCol, alignment: .leading)
            familyTotal(quota, key: "weeklySonnet", source: Buckets.sonnet, bucket: Buckets.sonnet).frame(width: Self.narrowCol, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func total(_ agg: Aggregate?, threshold: Double) -> some View {
        if let agg, let u = agg.utilization {
            let level: Level = u >= threshold ? .red : Derived.rawLevel(u)
            Text("\(Derived.percentInt(u))%").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(level.color)
        } else {
            Text("—").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func familyTotal(_ quota: QuotaSnapshot, key: String, source: String, bucket: String) -> some View {
        if quota.accounts.contains(where: { $0.buckets[key]?.source == source }) {
            total(quota.aggregate[key], threshold: status.thresholdFor(bucket: bucket))
        } else {
            Text("=wk").font(.system(size: 8.5, design: .monospaced)).foregroundStyle(.tertiary).help("Shares the weekly bucket")
        }
    }
}

struct AccountTableRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.snapshotMode) private var snapshotMode
    var account: Account
    var status: StatusSnapshot
    var tier: Tier?
    var now: Date
    @State private var priorityText = ""
    @State private var askPriority = false
    @State private var confirmRemove = false

    var isCurrent: Bool { account.name == status.currentAccount }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: AccountsTable.gap) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7)).foregroundStyle(isCurrent ? Color.accentColor : Color.clear)
                        Text(store.compactName(account.name)).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    }
                    Text(subtitle).font(.system(size: 8.5)).foregroundStyle(statusColor).lineLimit(1)
                }
                .frame(width: AccountsTable.nameWidth, alignment: .leading)
                .help(account.name + (account.orgName.map { " · \($0)" } ?? ""))

                if account.isApiKey {
                    let t = account.quota.tokensLimit.flatMap { l in account.quota.tokensRemaining.map { 1 - $0 / l } }
                    let r = account.quota.requestsLimit.flatMap { l in account.quota.requestsRemaining.map { 1 - $0 / l } }
                    cell(t, reset: account.quota.resetsAt, window: nil, bucket: "tokens", width: AccountsTable.wideCol, segments: 8)
                    cell(r, reset: account.quota.resetsAt, window: nil, bucket: "requests", width: AccountsTable.wideCol, segments: 8)
                    placeholder(AccountsTable.narrowCol); placeholder(AccountsTable.narrowCol)
                } else {
                    cell(account.quota.unified5h, reset: account.quota.unified5hReset, window: Window.fiveHour, bucket: Buckets.fiveHour, width: AccountsTable.wideCol, segments: 8)
                    cell(account.quota.unified7d, reset: account.quota.unified7dReset, window: Window.sevenDay, bucket: Buckets.weekly, width: AccountsTable.wideCol, segments: 8)
                    family(account.quota.unified7dFable, reset: account.quota.unified7dFableReset, bucket: Buckets.fable)
                    family(account.quota.unified7dSonnet, reset: account.quota.unified7dSonnetReset, bucket: Buckets.sonnet)
                }
                Spacer(minLength: 0)
                if !snapshotMode { rowMenu } else { Image(systemName: "ellipsis.circle").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if let why = UnavailableText.label(account.unavailable) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
                    Text(why + holdSuffix).font(.system(size: 9)).lineLimit(1)
                }
                .foregroundStyle(account.unavailable == "error" || account.unavailable == "disabled" ? Color.red : Color.yellow)
                .padding(.leading, AccountsTable.nameWidth + AccountsTable.gap)
            }
        }
        .padding(.vertical, 2)
        .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .alert("Priority for \(account.name)", isPresented: $askPriority) {
            TextField("0", text: $priorityText)
            Button("Set") { if let n = Int(priorityText) { Task { await store.apply(.priority(account: account.name, org: nil, value: .number(n)), label: "Priority of \(account.name)") } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Lower is preferred. A strictly lower value preempts a healthy current account.") }
        .confirmationDialog("Remove \(account.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await store.apply(.removeAccount(name: account.name, org: nil), label: "Remove \(account.name)") } }
        } message: { Text("The account is removed from the config; the proxy keeps serving it until it restarts.") }
    }

    private var rowMenu: some View {
        Menu {
            if !isCurrent { Button("Make current") { store.switchTo(account.name) } }
            Button(account.disabled ? "Enable" : "Disable") {
                Task { await store.apply(.enabled(account: account.name, org: nil, enabled: account.disabled), label: account.disabled ? "Enable \(account.name)" : "Disable \(account.name)") }
            }
            Button("Set priority…") { priorityText = String(account.priority); askPriority = true }
            Button("Move to top") { Task { await store.apply(.priority(account: account.name, org: nil, value: .first), label: "Priority of \(account.name)") } }
            Button("Move to bottom") { Task { await store.apply(.priority(account: account.name, org: nil, value: .last), label: "Priority of \(account.name)") } }
            Divider()
            Button("Copy name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(account.name, forType: .string) }
            Button("Remove…", role: .destructive) { confirmRemove = true }
        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 11)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(isCurrent ? "Actions" : "Make current, enable/disable, priority, remove")
    }

    @ViewBuilder
    private func cell(_ ratio: Double?, reset: Date?, window: TimeInterval?, bucket: String, width: CGFloat, segments: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let ratio {
                let level = Derived.level(ratio: ratio, resetAt: reset, window: window, threshold: status.thresholdFor(bucket: bucket), now: now)
                SegmentBar(ratio: ratio, level: level, segments: segments, width: width - 4)
                Text(label(ratio, reset)).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(level == .red ? Color.red : Color.secondary).lineLimit(1)
            } else {
                SegmentBar(ratio: 0, level: .green, segments: segments, width: width - 4)
                Text("—").font(.system(size: 8.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, alignment: .leading)
        .help(ratio.map { "\(Derived.formatPercent($0))" + (Derived.formatResetLong(reset, style: .both, now: now).isEmpty ? "" : " · " + Derived.formatResetLong(reset, style: .both, now: now)) } ?? "unknown")
    }

    @ViewBuilder
    private func family(_ ratio: Double?, reset: Date?, bucket: String) -> some View {
        if let ratio {
            let level = Derived.level(ratio: ratio, resetAt: reset, window: Window.sevenDay, threshold: status.thresholdFor(bucket: bucket), now: now)
            VStack(alignment: .leading, spacing: 2) {
                SegmentBar(ratio: ratio, level: level, segments: 6, width: AccountsTable.narrowCol - 4)
                Text("\(Derived.percentInt(ratio))%").font(.system(size: 8.5, design: .monospaced)).foregroundStyle(level == .red ? Color.red : Color.secondary)
            }
            .frame(width: AccountsTable.narrowCol, alignment: .leading)
            .help("\(Derived.formatPercent(ratio)) · \(Derived.formatResetLong(reset, style: .both, now: now))")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                SegmentBar(ratio: 0, level: .green, segments: 6, width: AccountsTable.narrowCol - 4)
                Text("=wk").font(.system(size: 8.5, design: .monospaced)).foregroundStyle(.tertiary)
            }.frame(width: AccountsTable.narrowCol, alignment: .leading).help("Shares the weekly bucket")
        }
    }

    private func placeholder(_ width: CGFloat) -> some View {
        Text("—").font(.system(size: 8.5, design: .monospaced)).foregroundStyle(.tertiary).frame(width: width, alignment: .leading)
    }

    private func label(_ ratio: Double, _ reset: Date?) -> String {
        let r = Derived.formatReset(reset, now: now)
        return r.isEmpty ? "\(Derived.percentInt(ratio))%" : "\(Derived.percentInt(ratio))·\(r)"
    }

    private var subtitle: String {
        var parts = [Derived.tierBadge(tier)]
        if account.disabled { parts.append("disabled") }
        else if account.status == "throttled", let until = account.rateLimitedUntil {
            let r = Derived.formatReset(until, now: now)
            parts.append(r.isEmpty ? "throttled" : "throttled \(r)")
        } else if account.status != "active" { parts.append(account.status) }
        if account.priority != 0 { parts.append("prio \(account.priority)") }
        if account.sessions > 0 { parts.append("\(account.sessions) sess") }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        if account.disabled { return .secondary }
        switch account.status {
        case "active": return .secondary
        case "throttled": return .yellow
        default: return .red
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
