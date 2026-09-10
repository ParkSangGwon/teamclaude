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
                            Banner(kind: .bad, text: "Config could not be read: \(err)")
                        }
                        if store.isDown {
                            Banner(kind: .warn, text: "Proxy not reachable — edits are saved to the config and apply when the service starts.")
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
    private var pane: some View { SettingsPaneOnly(section: section) }
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
        case .rotation: SchemaPane(section: .rotation)
        case .quota: QuotaPane()
        case .routing: RoutingPane()
        case .logging: SchemaPane(section: .logging)
        case .advanced: AdvancedPane()
        }
    }
}

extension SettingsRootView {
    private var restartBar: some View {
        HStack {
            Label("\(store.restartPending.count) change\(store.restartPending.count == 1 ? "" : "s") need a proxy restart (\(store.restartPending.sorted().joined(separator: ", ")))", systemImage: "arrow.clockwise")
                .font(.system(size: 12)).foregroundStyle(.yellow)
            Spacer()
            Button("Later") { store.clearRestartPending() }.controlSize(.small)
            Button("Restart service") { Task { await store.restartService() } }.controlSize(.small).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.yellow.opacity(0.1))
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
        case .advanced: return "slider.horizontal.3"
        }
    }
}

// MARK: - General (app preferences)

struct GeneralPane: View {
    @Environment(AppStore.self) private var store
    @State private var launchAtLogin = false
    @State private var iconStyle = Preferences.IconStyle.barsPercent
    @State private var pinCurrent = false
    @State private var showRemaining = false
    @State private var monochrome = true
    @State private var keepRight = true
    @State private var warnLevel = 0.7
    @State private var pollOpen = 2.0
    @State private var pollClosed = 30.0
    @State private var resetStyle = Derived.ResetStyle.both
    @State private var hidePII = false
    @State private var alerts = AlertPrefs()
    @State private var levelsText = "90, 95"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, on in LaunchAtLogin.set(on) }
                if Bundle.main.bundleIdentifier == nil { Text("Available from the app bundle (make app), not from swift run.").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            group("Menu bar") {
                Picker("Style", selection: $iconStyle) {
                    Text("Bars + %").tag(Preferences.IconStyle.barsPercent)
                    Text("Bars only").tag(Preferences.IconStyle.bars)
                    Text("% only").tag(Preferences.IconStyle.percent)
                    Text("Bars + 5h · 7d").tag(Preferences.IconStyle.barsBoth)
                    Text("Quiet (text only when warning)").tag(Preferences.IconStyle.quiet)
                }.frame(maxWidth: 360)
                Toggle("Show the current account instead of the fleet", isOn: $pinCurrent)
                Toggle("Show remaining instead of used", isOn: $showRemaining)
                Toggle("Monochrome (follows the menu bar)", isOn: $monochrome)
                HStack {
                    Toggle("Keep next to the system items (a full menu bar otherwise hides it)", isOn: $keepRight)
                    Button("Reposition now") { keepRight = true; store.prefs.keepRight = true; (NSApp.delegate as? AppDelegate)?.repositionStatusItem() }.controlSize(.small)
                }
                HStack { Text("Warning level"); Slider(value: $warnLevel, in: 0.5...0.95, step: 0.05).frame(width: 200); Text("\(Int(warnLevel * 100))%").monospacedDigit() }
            }
            group("Refresh") {
                Picker("Popover open", selection: $pollOpen) { Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0) }.frame(maxWidth: 300)
                Picker("Popover closed", selection: $pollClosed) { Text("15 s").tag(15.0); Text("30 s").tag(30.0); Text("60 s").tag(60.0) }.frame(maxWidth: 300)
                Picker("Reset display", selection: $resetStyle) { Text("Countdown").tag(Derived.ResetStyle.countdown); Text("Clock").tag(Derived.ResetStyle.clock); Text("Both").tag(Derived.ResetStyle.both) }.frame(maxWidth: 300)
                Toggle("Hide account e-mails (show 3-letter tags)", isOn: $hidePII)
            }
            group("Notifications") {
                Toggle("Fleet 5-hour thresholds", isOn: $alerts.fleetFiveHour)
                Toggle("Fleet weekly thresholds", isOn: $alerts.fleetWeekly)
                HStack { Text("Levels (%)"); TextField("90, 95", text: $levelsText).textFieldStyle(.roundedBorder).frame(width: 120).onSubmit(commitLevels) }
                Toggle("Rotation (current account changed)", isOn: $alerts.rotation)
                Toggle("Account needs a re-login", isOn: $alerts.accountError)
                Toggle("No account can serve (hold)", isOn: $alerts.hold)
                Toggle("Proxy not responding", isOn: $alerts.proxyDown)
                Toggle("Proxy is back", isOn: $alerts.proxyBack)
                Toggle("Overage billing started", isOn: $alerts.spend)
                HStack {
                    if let until = alerts.pausedUntil, until > Date() {
                        Text("Paused until \(until.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                        Button("Resume") { alerts.pausedUntil = nil }
                    } else {
                        Button("Pause for 1 hour") { alerts.pausedUntil = Date().addingTimeInterval(3600) }
                    }
                }
            }
            group("teamclaude updates") {
                HStack(spacing: 10) {
                    Text("Installed \(store.serverVersion ?? "?") · latest \(store.latestVersion ?? "?")").font(.system(size: 12))
                    Button("Check now") { Task { await store.checkForUpdates(force: true) } }.controlSize(.small)
                    if store.updateAvailable { Button(store.updateRunning ? "Updating…" : "Update to \(store.latestVersion ?? "")") { Task { await store.runUpdate() } }.controlSize(.small).buttonStyle(.borderedProminent).disabled(store.updateRunning) }
                }
                if let note = store.updateNote { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
                Text("Runs `teamclaude update` (npm install -g). The proxy runs the new version after a restart; a git checkout is left alone.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            group("About") {
                Text("TeamClaude Bar \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "(dev)") · MIT").font(.system(size: 12)).foregroundStyle(.secondary)
                Link("KarpelesLab/teamclaude on GitHub", destination: URL(string: "https://github.com/KarpelesLab/teamclaude")!).font(.system(size: 12))
            }
        }
        .onAppear(perform: load)
        .onChange(of: iconStyle) { _, v in store.prefs.iconStyle = v; store.prefsVersion += 1 }
        .onChange(of: pinCurrent) { _, v in store.prefs.pinCurrent = v; store.prefsVersion += 1 }
        .onChange(of: showRemaining) { _, v in store.prefs.showRemaining = v; store.prefsVersion += 1 }
        .onChange(of: monochrome) { _, v in store.prefs.monochrome = v; store.prefsVersion += 1 }
        .onChange(of: keepRight) { _, v in store.prefs.keepRight = v }
        .onChange(of: warnLevel) { _, v in store.prefs.warnLevel = v; store.prefsVersion += 1 }
        .onChange(of: pollOpen) { _, v in store.prefs.pollOpen = v }
        .onChange(of: pollClosed) { _, v in store.prefs.pollClosed = v }
        .onChange(of: resetStyle) { _, v in store.prefs.resetStyle = v }
        .onChange(of: hidePII) { _, v in store.prefs.hidePII = v; store.prefsVersion += 1 }
        .onChange(of: alerts) { _, v in store.prefs.alertPrefs = v }
    }

    private func load() {
        launchAtLogin = LaunchAtLogin.isEnabled
        iconStyle = store.prefs.iconStyle
        pinCurrent = store.prefs.pinCurrent
        showRemaining = store.prefs.showRemaining
        monochrome = store.prefs.monochrome
        keepRight = store.prefs.keepRight
        warnLevel = store.prefs.warnLevel
        pollOpen = store.prefs.pollOpen
        pollClosed = store.prefs.pollClosed
        resetStyle = store.prefs.resetStyle
        hidePII = store.prefs.hidePII
        alerts = store.prefs.alertPrefs
        levelsText = alerts.levels.map(String.init).joined(separator: ", ")
    }

    private func commitLevels() {
        let levels = levelsText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { (1...100).contains($0) }.sorted()
        if !levels.isEmpty { alerts.levels = levels }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Config file").font(.system(size: 13, weight: .semibold))
                HStack {
                    Text(store.configFile.path.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([store.configFile.path]) }.controlSize(.small)
                    Button("Reload from disk") { store.loadConfigRoot() }.controlSize(.small)
                }
                Text("Hand-editable JSON. Keys the app writes are re-sorted; the proxy keeps that order afterwards.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("State file").font(.system(size: 13, weight: .semibold))
                HStack {
                    Text(store.configFile.statePath.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Button("Delete…") { confirmState = true }.controlSize(.small)
                }
                Text("Observed quota and usage counters. Safe to delete: quota is re-learned from traffic.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .confirmationDialog("Delete the state file?", isPresented: $confirmState) {
                Button("Delete", role: .destructive) { try? FileManager.default.removeItem(at: store.configFile.statePath); store.showToast(.ok, "State file deleted") }
            }
            Divider()
            SchemaPane(section: .advanced)
            VStack(alignment: .leading, spacing: 6) {
                Text("Environment variables").font(.system(size: 13, weight: .semibold))
                Text("TEAMCLAUDE_CONFIG comes from the LaunchAgent (\(store.cliLocation?.configPathOverride ?? "not set")). TEAMCLAUDE_HOST, TEAMCLAUDE_UPSTREAM_* and the proxy env vars apply per process; the service runs with a minimal environment, so prefer the config keys above. TC_ACCT pins one `teamclaude run` session to an account.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
