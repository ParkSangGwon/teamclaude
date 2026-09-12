import SwiftUI
import AppKit
import TeamClaudeCore

struct ProxyPane: View {
    @Environment(AppStore.self) private var store
    @State private var cliPath = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var confirmUninstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            card(L("Connection")) {
                row(L("Endpoint"), store.endpoint.label)
                row(L("State"), connectionText)
                if let s = store.status?.server {
                    row(L("Started"), s.startedAt.map { Derived.localizedDate($0, date: .abbreviated, time: .shortened) } ?? "—")
                    row(L("Upstream"), s.upstream ?? "—")
                    row(L("Version"), s.version.map { L("%@ (reported by the proxy)", $0) } ?? (store.cliVersion.map { L("%@ (from the CLI; the proxy predates version reporting)", $0) } ?? "—"))
                    if let loop = s.eventLoop {
                        row(L("Event loop"), L("lag %d ms · max %d ms · %@", loop.lastLagMs, loop.maxLagMs, loop.stallCount == 1 ? L("1 stall") : L("%d stalls", loop.stallCount))
                            + (loop.lastStallAt.map { " · " + L("last %@ ago", Derived.formatDuration(Date().timeIntervalSince($0))) } ?? "")
                            + (loop.lagging ? " · " + L("above the %d ms warning line", loop.warnLagMs) : ""))
                    }
                }
                if let pool = store.status?.upstreamPool {
                    row(L("Upstream pool"), L("%d active · %d queued · %@ · limit %d/origin, queue %d", pool.active, pool.queued, pool.origins == 1 ? L("1 origin") : L("%d origins", pool.origins), pool.perOriginLimit, pool.maxQueue))
                }
                row(L("Key in use"), store.endpoint.apiKey.map { $0.prefix(5) + "…" } ?? L("none (loopback exempt)"))
                HStack {
                    Button(L("Poll now")) { store.refreshNow() }.controlSize(.small)
                    Button(L("Open dashboard")) { Actions.openDashboard(store) }.controlSize(.small)
                    Button(L("Open log")) { NSWorkspace.shared.open(ProxyLocator.logPath()) }.controlSize(.small)
                }
            }
            card(L("Service (LaunchAgent)")) {
                if let d = store.serviceDiagnosis {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: diagnosisIcon(d)).foregroundStyle(diagnosisColor(d))
                        Text(d.text).fixedSize(horizontal: false, vertical: true)
                    }
                    if let h = store.serviceHealth, h.loaded {
                        row("launchctl", [h.state.map { L("state %@", $0) }, h.pid.map { L("pid %d", $0) }, h.runs.map { L("runs %d", $0) }, h.lastExitCode.map { L("last exit %d", $0) }].compactMap { $0 }.joined(separator: " · "))
                    }
                } else {
                    Text(L("Checking…")).foregroundStyle(.secondary)
                }
                HStack {
                    switch store.serviceDiagnosis {
                    case .portHeldElsewhere(let pid, let command, _) where command.isEmpty || command.contains("node") || command.contains("teamclaude"):
                        Button(L("Quit that process and start the service")) { Task { await store.quitPortOwnerAndRestart(pid: pid) } }.controlSize(.small).buttonStyle(.borderedProminent)
                    case .portHeldElsewhere:
                        Text(L("Quit that program or change the port above.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    case .notInstalled:
                        Button(L("Install service")) { Task { await store.service("install") } }.controlSize(.small).buttonStyle(.borderedProminent)
                    default:
                        Button(L("Restart")) { Task { await store.restartService(); try? await Task.sleep(for: .seconds(3)); await store.refreshServiceHealth() } }.controlSize(.small)
                        Button(L("Reinstall")) { Task { await store.service("install") } }.controlSize(.small)
                        Button(L("Uninstall…")) { confirmUninstall = true }.controlSize(.small)
                    }
                    Button(L("Refresh")) { Task { await store.refreshServiceHealth() } }.controlSize(.small)
                }
                Text(L("Reinstall rewrites the plist with the current CLI path and the Standard process type; the proxy restarts once.")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .confirmationDialog(L("Uninstall the LaunchAgent?"), isPresented: $confirmUninstall) {
                Button(L("Uninstall"), role: .destructive) { Task { await store.service("uninstall") } }
            } message: { Text(L("The proxy stops and no longer starts at login. The config and accounts are kept; reinstall from this pane.")) }
            card(L("teamclaude CLI")) {
                row(L("Detected"), store.cliLocation.map { "\($0.describe) (\(sourceLabel($0.source)))" } ?? L("not found"))
                row(L("Version"), store.cliVersion ?? "—")
                HStack {
                    TextField(L("Override path to teamclaude"), text: $cliPath).textFieldStyle(.roundedBorder).frame(maxWidth: 380)
                    Button(L("Apply")) { store.prefs.cliPath = cliPath.isEmpty ? nil : cliPath; Task { await store.resolveCLI() } }.controlSize(.small)
                    Button(L("Test")) { test() }.controlSize(.small).disabled(testing)
                }
                if let testResult { Text(testResult).font(.system(size: 11)).foregroundStyle(.secondary) }
                Text(L("Order: this override → LaunchAgent plist → login shell PATH. Settings that have a CLI command go through it; the rest edit the config file directly.")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            Text(L("Network & keys")).font(.system(size: 13, weight: .semibold))
            SchemaPane(section: .proxy)
        }
        .onAppear {
            cliPath = store.prefs.cliPath ?? ""
            Task { await store.refreshServiceHealth() }
        }
    }
    private func sourceLabel(_ s: CLILocation.Source) -> String {
        switch s {
        case .launchAgent: return "LaunchAgent"
        case .loginShell: return L("login shell")
        case .manual: return L("manual override")
        }
    }


    private var connectionText: String {
        switch store.connection {
        case .starting: return store.failureStreak > 0 ? L("no answer yet — retrying…") : L("connecting…")
        case .up: return L("reachable") + (store.lastSuccessAt.map { " · " + L("updated %@ ago", Derived.formatDuration(Date().timeIntervalSince($0))) } ?? "")
        case .down(let since, let e): return "\(e.message) (" + L("since %@", Derived.localizedDate(since, date: .omitted, time: .shortened)) + ")"
        }
    }

    private func test() {
        testing = true
        Task {
            do {
                let r = try await store.runCLI(["version"], timeout: 15)
                testResult = r.succeeded ? "teamclaude \(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))" : L("failed: %@", r.failureMessage)
            } catch let e as CLIError {
                testResult = e.message
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }

    private func diagnosisIcon(_ d: ServiceDiagnosis) -> String {
        switch d { case .healthy: return "checkmark.circle.fill"; case .notInstalled, .notLoaded, .stopped: return "circle.dashed"; default: return "exclamationmark.triangle.fill" }
    }
    private func diagnosisColor(_ d: ServiceDiagnosis) -> Color {
        switch d { case .healthy: return .green; case .notInstalled, .notLoaded, .stopped: return .secondary; default: return .orange }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        TitledGroup(title: title, content: content)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled)
        }.font(.system(size: 12))
    }
}

// MARK: - Quota

struct QuotaPane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let probe = store.status?.probe {
                ProbeStatusView(probe: probe)
                Divider()
            }
            SchemaPane(section: .quota)
            WarmupEditor()
            if let warm = store.status?.warm {
                Divider()
                WarmStatusView(warm: warm, quotaWarmup: store.quota?.warmup ?? .null)
            }
        }
    }
}

/// What keep-warm did and will do: it spends quota on every idle account, so its silence needs explaining.
struct WarmStatusView: View {
    @Environment(AppStore.self) private var store
    var warm: JobState
    var quotaWarmup: JSON

    var summary: String {
        guard warm.enabled else { return L("off") }
        var parts = [warm.mode.map { L("mode %@", L($0)) } ?? L("on")]
        if warm.intervalSeconds > 0 { parts.append(L("every %d s", warm.intervalSeconds)) }
        if let tz = quotaWarmup["timezone"].string { parts.append(tz) }
        if let next = warm.nextRunAt ?? quotaWarmup["nextWarmupAt"].date, case let r = Derived.formatReset(next), !r.isEmpty { parts.append(L("next in %@", r)) }
        if let reset = quotaWarmup["nextResetAt"].date, case let r = Derived.formatReset(reset), !r.isEmpty { parts.append(L("target reset in %@", r)) }
        if let last = warm.lastRunFinishedAt { parts.append(L("last %@ ago", Derived.formatDuration(Date().timeIntervalSince(last)))) }
        if warm.running { parts.append(L("running now")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Keep-warm status")).font(.system(size: 13, weight: .semibold))
            Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(warm.accounts, id: \.name) { a in
                let when = a.lastAt.map { L("warmed %@ ago", Derived.formatDuration(Date().timeIntervalSince($0))) } ?? L("never warmed")
                let text = "\(store.compactName(a.name)): \(a.status.map { L($0) } ?? "—") · \(when)" + (a.error.map { " · \($0)" } ?? "")
                Text(text).font(.system(size: 11)).foregroundStyle(a.error == nil ? Color.secondary : Color.red)
            }
        }
    }
}

struct ProbeStatusView: View {
    @Environment(AppStore.self) private var store
    var probe: JobState

    var summary: String {
        guard probe.enabled else { return L("off (quota is read from responses; idle accounts stay unknown until rotation reaches them)") }
        var s = L("every %d s", probe.intervalSeconds)
        if let next = probe.nextRunAt, case let r = Derived.formatReset(next), !r.isEmpty { s += " · " + L("next in %@", r) }
        if let last = probe.lastRunFinishedAt { s += " · " + L("last %@ ago", Derived.formatDuration(Date().timeIntervalSince(last))) }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Probe status")).font(.system(size: 13, weight: .semibold))
            Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(probe.accounts, id: \.name) { a in
                let text = "\(store.compactName(a.name)): \(a.status.map { L($0) } ?? "—")" + (a.error.map { " · \($0)" } ?? "")
                Text(text).font(.system(size: 11)).foregroundStyle(a.error == nil ? Color.secondary : Color.red)
            }
        }
    }
}

struct WarmupEditor: View {
    @Environment(AppStore.self) private var store
    @State private var warmMode = "off"
    @State private var interval = "600"
    @State private var time = "15:30"
    @State private var timezone = TimeZone.current.identifier
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(L("Keep-warm schedule")).font(.system(size: 13, weight: .semibold)); Spacer(); AppliesTag(applies: .live) }
            modePicker
            if warmMode == "interval" { intervalRow }
            if warmMode == "reset" || warmMode == "rolling" { scheduleRows }
            HStack {
                Button(L("Apply")) { apply() }.controlSize(.small)
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            }
            Text(L("Keep-warm sends a minimal request per idle account so its 5-hour timer keeps running. It spends a little quota and needs `claude` on the service PATH. Mutually exclusive with the interval above."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: load)
        .onChange(of: store.configRoot) { _, _ in load() }
    }

    private var modePicker: some View {
        Picker("", selection: $warmMode) {
            Text(L("Off")).tag("off")
            Text(L("Interval")).tag("interval")
            Text(L("Daily reset")).tag("reset")
            Text(L("Rolling")).tag("rolling")
        }
        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
    }

    private var intervalRow: some View {
        HStack {
            Text(L("Every"))
            TextField("600", text: $interval).textFieldStyle(.roundedBorder).frame(width: 80)
            Text(L("s (min 60)"))
        }
    }

    private var scheduleRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Time"))
                TextField("15:30", text: $time).textFieldStyle(.roundedBorder).frame(width: 80)
                Text(L("Time zone"))
                TextField("Area/City", text: $timezone).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            Text(warmMode == "reset" ? L("Warm up before a daily target reset in that zone.") : L("Anchor resets at that time, then continue every five hours."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func load() {
        let sched = store.configValue(["warmupSchedule"])
        if sched.object != nil {
            warmMode = sched["mode"].string == "rolling" ? "rolling" : "reset"
            time = sched["resetTime"].string ?? "15:30"
            timezone = sched["timezone"].string ?? TimeZone.current.identifier
        } else if let secs = store.configValue(["warmupSeconds"]).int, secs > 0 {
            warmMode = "interval"
            interval = String(secs)
        } else {
            warmMode = "off"
        }
    }

    private func apply() {
        error = nil
        let change: SettingChange
        switch warmMode {
        case "off":
            change = .warmupInterval(seconds: 0)
        case "interval":
            guard let secs = Int(interval), secs >= 60 else { error = L("Interval must be at least 60 s"); return }
            change = .warmupInterval(seconds: secs)
        default:
            if let e = SettingsValidation.timeHHMM(time) { error = e; return }
            if let e = SettingsValidation.timezone(timezone) { error = e; return }
            change = warmMode == "reset" ? .warmupReset(time: time, timezone: timezone) : .warmupRolling(time: time, timezone: timezone)
        }
        Task { await store.apply(change, label: L("Keep-warm")) }
    }
}
