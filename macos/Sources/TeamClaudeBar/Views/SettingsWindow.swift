import AppKit
import SwiftUI
import TeamClaudeCore

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(store: AppStore, section: SettingsSection = .general) {
        let hosting = NSHostingController(rootView: SettingsRootView(section: section).environment(store))
        window = NSWindow(contentViewController: hosting)
        window.title = "TeamClaude Bar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 560))
        window.minSize = NSSize(width: 660, height: 440)
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var windowNumber: Int { window.windowNumber }
}

struct SettingsRootView: View {
    @Environment(AppStore.self) private var store
    @State private var section: SettingsSection

    init(section: SettingsSection = .general) { _section = State(initialValue: section) }

    var body: some View {
        // Reading the language here re-renders the whole window on a change: every label is an `L()` call.
        let _ = store.prefs.language
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { s in
                Label(s.title, systemImage: icon(s)).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 176, max: 220)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(section.title).font(.title2.bold())
                        if let err = store.configError {
                            Banner(kind: .bad, text: L("Config could not be read: %@", err))
                        }
                        if store.isDown {
                            Banner(kind: .warn, text: L("Proxy not reachable — edits are saved to the config and apply when the service starts."))
                        }
                        pane
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if !store.restartPending.isEmpty { restartBar }
            }
        }
        .onAppear {
            store.loadConfigRoot()
            Task { await store.refreshServiceHealth() }
        }
    }

    @ViewBuilder
    // `.id` remakes the pane on a language change, so panes that read nothing else from the store still relabel.
    private var pane: some View { SettingsPaneOnly(section: section).id(store.prefs.language) }
}

/// One pane without the split view chrome (also what the snapshot mode renders).
struct SettingsPaneOnly: View {
    @Environment(AppStore.self) private var store
    let section: SettingsSection

    var body: some View {
        switch section {
        case .general: GeneralPane()
        case .proxy: ProxyPane()
        case .accounts: AccountsPane()
        case .rotation: RotationPane()
        case .quota: QuotaPane()
        case .routing: RoutingPane()
        case .logging: LoggingPane()
        case .history: HistoryPane()
        case .advanced: AdvancedPane()
        }
    }
}

extension SettingsRootView {
    private var restartBar: some View {
        HStack {
            Label(store.restartPendingText ?? "", systemImage: "arrow.clockwise")
                .font(.system(size: 12)).foregroundStyle(Level.orange.color)
            Spacer()
            Button(L("Later")) { store.clearRestartPending() }.controlSize(.small)
            Button(L("Restart service")) { Task { await store.restartService() } }.controlSize(.small).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Level.orange.color.opacity(0.1))
        .overlay(alignment: .top) { Divider() }
    }

    private func icon(_ s: SettingsSection) -> String {
        switch s {
        case .general: return "gearshape"
        case .proxy: return "server.rack"
        case .accounts: return "person.2"
        case .rotation: return "arrow.triangle.2.circlepath"
        case .quota: return "gauge.with.dots.needle.33percent"
        case .routing: return "point.topleft.down.to.point.bottomright.curvepath"
        case .logging: return "doc.text"
        case .history: return "clock.arrow.circlepath"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

// MARK: - General (app preferences)

struct GeneralPane: View {
    @Environment(AppStore.self) private var store
    @State private var launchAtLogin = false
    @State private var levelsText = "90, 95"

    var body: some View {
        @Bindable var prefs = store.prefs
        VStack(alignment: .leading, spacing: 14) {
            TitledGroup(title: L("Startup")) {
                Toggle(L("Launch at login"), isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, on in LaunchAtLogin.set(on) }
                if Bundle.main.bundleIdentifier == nil { Text(L("Available from the app bundle (make app), not from swift run.")).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            TitledGroup(title: L("Language")) {
                Picker(L("Language"), selection: Binding(get: { prefs.language ?? "" }, set: { prefs.language = $0.isEmpty ? nil : $0 })) {
                    Text(L("System (%@)", L10n.supported.first { $0.code == L10n.systemDefault() }?.name ?? "English")).tag("")
                    Divider()
                    ForEach(L10n.supported) { Text($0.name).tag($0.code) }
                }.frame(maxWidth: 300)
                if L10n.translationMissing, let missing = L10n.supported.first(where: { $0.code == prefs.language }) {
                    Text(L("The translation for %@ is not in this build; showing English.", missing.name)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            TitledGroup(title: L("Menu bar")) {
                Picker(L("Style"), selection: $prefs.iconStyle) {
                    Text(L("Bars + %")).tag(Preferences.IconStyle.barsPercent)
                    Text(L("Bars only")).tag(Preferences.IconStyle.bars)
                    Text(L("% only")).tag(Preferences.IconStyle.percent)
                    Text(L("Bars + 5h · 7d")).tag(Preferences.IconStyle.barsBoth)
                    Text(L("Quiet (text only when warning)")).tag(Preferences.IconStyle.quiet)
                }.frame(maxWidth: 360)
                Toggle(L("Show the current account instead of the fleet (its three-letter tag leads the title)"), isOn: $prefs.pinCurrent)
                Toggle(L("Show remaining instead of used"), isOn: $prefs.showRemaining)
                Toggle(L("Monochrome (follows the menu bar)"), isOn: $prefs.monochrome)
                Text(L("The icon turns orange when a bar runs ahead of its window (the same rule that colours the bars) and red at the switch threshold or when nothing can serve.")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TitledGroup(title: L("Refresh")) {
                Picker(L("Refresh (popover open / closed)"), selection: $prefs.refresh) {
                    ForEach(Preferences.Refresh.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(maxWidth: 420)
                Picker(L("Reset display"), selection: $prefs.resetStyle) { Text(L("Countdown")).tag(Derived.ResetStyle.countdown); Text(L("Clock")).tag(Derived.ResetStyle.clock); Text(L("Both")).tag(Derived.ResetStyle.both) }.frame(maxWidth: 300)
                Toggle(L("Hide account e-mails (show short tags)"), isOn: $prefs.hidePII)
                Text(L("Polling slows to every 5 minutes while the display is off or the session is locked, and halves in Low Power Mode.")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TitledGroup(title: L("Shortcuts")) {
                Toggle("\(HotKeyCenter.Key.nextAccount.title)  " + L("Switch to the next available account"), isOn: $prefs.hotkeyNextAccount)
                Toggle("\(HotKeyCenter.Key.togglePopover.title)  " + L("Show or hide the popover"), isOn: $prefs.hotkeyTogglePopover)
                Text(L("Global — they work from any app. No Accessibility permission is needed.")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            TitledGroup(title: L("Notifications")) {
                Toggle(L("Fleet 5-hour thresholds"), isOn: $prefs.alertPrefs.fleetFiveHour)
                Toggle(L("Fleet weekly thresholds"), isOn: $prefs.alertPrefs.fleetWeekly)
                HStack { Text(L("Levels (%)")); TextField(L("Levels"), text: $levelsText, prompt: Text("90, 95")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 120).onSubmit(commitLevels) }
                Toggle(L("Rotation (the account carrying requests changed, with the reason)"), isOn: $prefs.alertPrefs.rotation)
                Toggle(L("An account left rotation (threshold, 429 hold, cap)"), isOn: $prefs.alertPrefs.accountLeft)
                Toggle(L("An account is back in rotation (window reset, hold cleared)"), isOn: $prefs.alertPrefs.accountBack)
                Toggle(L("Account needs a re-login"), isOn: $prefs.alertPrefs.accountError)
                Toggle(L("Quota probe failing for an account"), isOn: $prefs.alertPrefs.probeFailed)
                Toggle(L("No account can serve (hold)"), isOn: $prefs.alertPrefs.hold)
                Toggle(L("Proxy not responding"), isOn: $prefs.alertPrefs.proxyDown)
                Toggle(L("Proxy is back"), isOn: $prefs.alertPrefs.proxyBack)
                Toggle(L("Overage billing started"), isOn: $prefs.alertPrefs.spend)
                HStack {
                    if let until = prefs.alertPrefs.pausedUntil, until > Date() {
                        Text(L("Paused until %@", Derived.localizedDate(until, date: .omitted, time: .shortened))).foregroundStyle(.secondary)
                        Button(L("Resume")) { prefs.alertPrefs.pausedUntil = nil }
                    } else {
                        Button(L("Pause for 1 hour")) { prefs.alertPrefs.pausedUntil = Date().addingTimeInterval(3600) }
                    }
                }
            }
            TitledGroup(title: L("teamclaude updates")) {
                HStack(spacing: 10) {
                    Text(L("CLI %@", store.cliVersion ?? "?") + (store.status?.server?.version.map { " · " + L("proxy %@", $0) } ?? "")).font(.system(size: 12))
                    Button(store.updateRunning ? L("Updating…") : L("Update now")) { Task { await store.runUpdate() } }.controlSize(.small).buttonStyle(.borderedProminent).disabled(store.updateRunning)
                }
                if let note = store.updateNote { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
                Text(L("Runs `teamclaude update`: it asks npm whether a newer release exists and installs it (a git checkout is left alone). The proxy runs the new version after a restart; its own daily check is the `autoUpdate` setting under Advanced.")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TitledGroup(title: L("About")) {
                Text("TeamClaude Bar \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "(dev)") · MIT").font(.system(size: 12)).foregroundStyle(.secondary)
                Link(L("%@ on GitHub", "KarpelesLab/teamclaude"), destination: URL(string: "https://github.com/KarpelesLab/teamclaude")!).font(.system(size: 12))
            }
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            levelsText = store.prefs.alertPrefs.levels.map(String.init).joined(separator: ", ")
        }
    }

    private func commitLevels() {
        let levels = levelsText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { (1...100).contains($0) }.sorted()
        if !levels.isEmpty { store.prefs.alertPrefs.levels = levels }
    }
}

import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return SMAppService.mainApp.status == .enabled
    }
    static func set(_ on: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[TeamClaudeBar] launch at login: %@", error.localizedDescription)
        }
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    @Environment(AppStore.self) private var store
    @State private var confirmState = false
    @State private var editingRaw = false
    @State private var exportedTo: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Config file")).font(.system(size: 13, weight: .semibold))
                HStack {
                    Text(store.configFile.path.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Button(L("Reveal")) { NSWorkspace.shared.activateFileViewerSelecting([store.configFile.path]) }.controlSize(.small)
                    Button(L("Reload from disk")) { store.loadConfigRoot() }.controlSize(.small)
                    Button(L("Edit as JSON…")) { editingRaw = true }.controlSize(.small)
                }
                Text(L("Hand-editable JSON. The editor shows secrets as %@ and puts them back on save; unknown keys are kept and the file is written the way the proxy writes it (temp, fsync, rename, 0600), then reloaded.", ConfigRedaction.placeholder)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .sheet(isPresented: $editingRaw) { RawConfigEditor { editingRaw = false } }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Diagnostics")).font(.system(size: 13, weight: .semibold))
                HStack {
                    Button(L("Export diagnostics…")) { Task { exportedTo = await store.exportDiagnostics() } }.controlSize(.small)
                    if let exportedTo { Button(L("Reveal")) { NSWorkspace.shared.activateFileViewerSelecting([exportedTo]) }.controlSize(.small) }
                }
                Text(L("Writes status.json, quota.json, the config with every secret replaced, `launchctl print` and the app's state to a folder in Downloads — what a bug report needs, without tokens.")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L("State file")).font(.system(size: 13, weight: .semibold))
                HStack {
                    Text(store.configFile.statePath.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Button(L("Delete…")) { confirmState = true }.controlSize(.small)
                }
                Text(L("Observed quota and usage counters. Safe to delete: quota is re-learned from traffic.")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .confirmationDialog(L("Delete the state file?"), isPresented: $confirmState) {
                Button(L("Delete"), role: .destructive) { store.deleteStateFile() }
            }
            Divider()
            SchemaPane(section: .advanced)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Environment variables")).font(.system(size: 13, weight: .semibold))
                Text(L("TEAMCLAUDE_CONFIG comes from the LaunchAgent (%@). TEAMCLAUDE_HOST, TEAMCLAUDE_UPSTREAM_* and the proxy env vars apply per process; the service runs with a minimal environment, so prefer the config keys above. TC_ACCT pins one `teamclaude run` session to an account.", store.cliLocation?.configPathOverride ?? L("not set")))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Rotation (schema + the rotation log)

struct RotationPane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SchemaPane(section: .rotation)
            RotationLogView()
        }
    }
}

/// Every rotation the app saw, newest first, with the router's reason.
struct RotationLogView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let events = store.prefs.rotationLog.latest
        TitledGroup(title: L("Rotation log")) {
            if events.isEmpty {
                Text(L("No rotation observed yet. Entries are recorded while the app runs (the proxy itself keeps no history).")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(L("%d in the last 24 h · %d kept", store.prefs.rotationLog.count(within: 86400), events.count)).font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(events) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Derived.localizedDate(e.at, date: .abbreviated, time: .shortened)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        Text("\(e.from.map(store.displayName) ?? "—") → \(store.displayName(e.to))").font(.system(size: 12, weight: e.manual ? .regular : .medium))
                        if e.manual { Chip(text: L("manual")) }
                        if let reason = e.reasonText { Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer(minLength: 0)
                    }
                }
                Button(L("Clear log")) { store.prefs.rotationLog = RotationLog() }.controlSize(.small)
            }
        }
    }
}

// MARK: - Logging (schema + who consumed what)

struct LoggingPane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SchemaPane(section: .logging)
            if let status = store.status {
                if !status.clients.isEmpty {
                    TitledGroup(title: L("Consumption by client key")) {
                        UsageTable(rows: status.clients.map { UsageTable.Row(name: $0.name, requests: $0.requests, input: $0.inputTokens, output: $0.outputTokens, lastUsed: $0.lastUsed) })
                    }
                }
                if !status.usageDimensions.isEmpty {
                    ForEach(Array(Set(status.usageDimensions.map(\.dimension))).sorted(), id: \.self) { dim in
                        TitledGroup(title: L("Consumption by %@", dim)) {
                            UsageTable(rows: status.usageDimensions.filter { $0.dimension == dim }.map { UsageTable.Row(name: $0.value, requests: $0.requests, input: $0.inputTokens, output: $0.outputTokens, lastUsed: $0.lastUsed) })
                        }
                    }
                }
                if status.clients.isEmpty, status.usageDimensions.isEmpty {
                    Text(L("Consumption tables appear here once a client key or a usage dimension above has seen traffic.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Requests and tokens per name, most requests first.
struct UsageTable: View {
    struct Row: Identifiable {
        var id: String { name }
        var name: String
        var requests: Int
        var input: Int
        var output: Int
        var lastUsed: Date?
    }
    var rows: [Row]

    var body: some View {
        let sorted = rows.sorted { $0.requests != $1.requests ? $0.requests > $1.requests : $0.name < $1.name }
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                Text(L("NAME")); Text(L("REQUESTS")); Text(L("IN")); Text(L("OUT")); Text(L("LAST USED"))
            }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(sorted) { r in
                GridRow {
                    Text(r.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("\(r.requests)").monospacedDigit()
                    Text(UsageTable.compact(r.input)).monospacedDigit()
                    Text(UsageTable.compact(r.output)).monospacedDigit()
                    Text(r.lastUsed.map { L("%@ ago", Derived.formatDuration(Date().timeIntervalSince($0))) } ?? "—").foregroundStyle(.secondary)
                }.font(.system(size: 12))
            }
        }
    }

    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Raw config editor

/// The whole file as text, secrets replaced by a placeholder that is swapped back on save.
struct RawConfigEditor: View {
    @Environment(AppStore.self) private var store
    var dismiss: () -> Void
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false
    @State private var disk: JSON?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Edit %@", store.configFile.path.lastPathComponent)).font(.headline)
            Text(L("Secrets show as %@; leave them and they are kept. Unknown keys survive. The proxy reloads after the save.", ConfigRedaction.placeholder)).font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).frame(minWidth: 640, minHeight: 420)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
            HStack {
                Spacer()
                Button(L("Cancel"), action: dismiss)
                Button(saving ? L("Saving…") : L("Save")) { save() }.keyboardShortcut(.defaultAction).disabled(saving || disk == nil)
            }
        }
        .padding(20)
        .onAppear(perform: load)
    }

    private func load() {
        do {
            let root = try store.configFile.load().root
            disk = root
            text = ConfigRedaction.redact(root).pretty()
        } catch {
            self.error = L("Could not read the config: %@", String(describing: error))
        }
    }

    private func save() {
        guard let disk else { return }
        let parsed: JSON
        do { parsed = try JSON.parse(Data(text.utf8)) } catch { self.error = L("Not valid JSON: %@", String(describing: error)); return }
        guard parsed.object != nil else { self.error = L("The config must be a JSON object"); return }
        if let raw = parsed["upstreamProxy"].string, let why = SettingsValidation.upstreamProxy(raw) { self.error = "upstreamProxy: \(why)"; return }
        let restored = ConfigRedaction.restore(parsed, from: disk)
        saving = true
        error = nil
        Task {
            let ok = await store.writeConfigDocument(restored)
            saving = false
            if ok { dismiss() } else { error = L("The proxy did not reload the new config; see the message above.") }
        }
    }
}
