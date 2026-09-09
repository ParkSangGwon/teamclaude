import AppKit
import Observation
import TeamClaudeCore

enum Connection: Equatable {
    case starting
    case up
    case down(since: Date, error: ProxyError)
}

struct Toast: Equatable {
    enum Kind { case ok, warn, error, info }
    var kind: Kind
    var text: String
    var at: Date
}

/// Single source of truth for the UI: polls the proxy, keeps the last snapshots,
/// runs the alert engine, and exposes the actions the views call.
@MainActor
@Observable
final class AppStore {
    private(set) var status: StatusSnapshot?
    private(set) var quota: QuotaSnapshot?
    private(set) var previousStatus: StatusSnapshot?
    private(set) var connection: Connection = .starting
    private(set) var lastSuccessAt: Date?
    private(set) var lastAttemptAt: Date?
    private(set) var quotaSupported = true
    private(set) var switchSupported = true
    private(set) var endpoint: ProxyEndpoint
    private(set) var configFile: ConfigFile
    private(set) var cliLocation: CLILocation?
    private(set) var serverVersion: String?
    private(set) var rotatedAt: Date?
    private(set) var rotatedTo: String?
    private(set) var restartPending: Set<String> = []
    /// The config document as last read, for the settings screens.
    private(set) var configRoot: JSON?
    private(set) var configError: String?
    private(set) var serviceDiagnosis: ServiceDiagnosis?
    private(set) var serviceHealth: ServiceHealth?
    var toast: Toast?
    var popoverOpen = false
    /// Bumped when an app preference changes so the icon re-renders (Preferences itself is not observable).
    var prefsVersion = 0

    let prefs = Preferences.shared
    private var client: ProxyClient
    private var runner: CLIRunner
    private var pollTask: Task<Void, Never>?
    private var failureStreak = 0
    private var appSwitchedTo: (name: String, at: Date)?
    private var restartWatchUntil: Date?
    private var startedAtBeforeRestart: Date?

    init() {
        let file = ConfigFile(path: ConfigFile.resolvePath())
        configFile = file
        let settings = (try? file.load().root).map(ConfigFile.proxySettings) ?? ConfigFile.ProxySettings(port: 3456, host: "127.0.0.1", apiKey: nil, trustLoopback: true)
        let ep = ProxyEndpoint(host: "127.0.0.1", port: settings.port, apiKey: settings.apiKey)
        endpoint = ep
        client = ProxyClient(endpoint: ep)
        cliLocation = nil
        runner = CLIRunner(location: nil)
        Task { await self.resolveCLI() }
    }

    // MARK: - lifecycle

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let delay = self.nextDelay()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    func stop() { pollTask?.cancel() }

    private func nextDelay() -> TimeInterval {
        if let until = restartWatchUntil, Date() < until { return 1 }
        if case .down = connection { return min(30, pow(2, Double(min(failureStreak, 5)))) }
        return popoverOpen ? prefs.pollOpen : prefs.pollClosed
    }

    /// Re-read port/key from the config (after a key rotation or a port change).
    func reloadEndpoint() {
        let file = ConfigFile(path: ConfigFile.resolvePath(env: mergedEnv()))
        configFile = file
        guard let root = try? file.load().root else { return }
        let s = ConfigFile.proxySettings(root)
        let ep = ProxyEndpoint(host: "127.0.0.1", port: s.port, apiKey: s.apiKey)
        if ep != endpoint {
            endpoint = ep
            Task { await client.update(endpoint: ep) }
        }
    }

    private func mergedEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let c = cliLocation?.configPathOverride { env["TEAMCLAUDE_CONFIG"] = c }
        return env
    }

    func resolveCLI() async {
        let override = prefs.cliPath
        let loc = await Task.detached { ProxyLocator.resolve(manualOverride: override) }.value
        cliLocation = loc
        runner = CLIRunner(location: loc)
        if loc?.configPathOverride != nil { reloadEndpoint() }
        if loc != nil, let r = try? await runner.run(["version"], timeout: 10), r.succeeded {
            serverVersion = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
        }
    }

    // MARK: - polling

    func poll() async {
        lastAttemptAt = Date()
        let client = self.client
        let statusTask = Task { () -> Result<StatusSnapshot, Error> in
            do { return .success(try await client.status()) } catch { return .failure(error) }
        }
        let quotaTask = Task { () -> Result<QuotaSnapshot, Error> in
            do { return .success(try await client.quota()) } catch { return .failure(error) }
        }
        let sr = await statusTask.value
        applyStatus(sr)
        // Quota is the slower reply on a busy proxy; the status render must not wait for it.
        let qr = await quotaTask.value
        applyQuota(qr)
        evaluateAlerts()
    }

    private func applyStatus(_ sr: Result<StatusSnapshot, Error>) {
        switch sr {
        case .success(let s):
            previousStatus = status
            status = s
            failureStreak = 0
            lastSuccessAt = Date()
            let wasDown = { if case .down = connection { return true } else { return false } }()
            connection = .up
            if wasDown { showToast(.ok, "Proxy is back") }
            if let before = startedAtBeforeRestart, let now = s.server?.startedAt, now != before {
                startedAtBeforeRestart = nil
                restartWatchUntil = nil
                restartPending.removeAll()
                showToast(.ok, "Proxy restarted")
            }
            let prevTarget = previousStatus?.effectiveDefaultTarget
            if let prev = prevTarget, let cur = s.effectiveDefaultTarget, prev != cur, appSwitchedTo?.name != cur {
                rotatedAt = Date()
                rotatedTo = cur
            }
        case .failure(let e):
            failureStreak += 1
            let err = (e as? ProxyError) ?? .badReply(e.localizedDescription)
            NSLog("[TeamClaudeBar] status poll failed: %@ (%@)", err.message, String(describing: e))
            if case .down = connection {} else { connection = .down(since: Date(), error: err) }
            if err == .unauthorized { reloadEndpoint() }
        }
    }

    private func applyQuota(_ qr: Result<QuotaSnapshot, Error>) {
        switch qr {
        case .success(let q):
            quota = q
            quotaSupported = true
        case .failure(let e):
            if case .notTeamClaude = e as? ProxyError { quotaSupported = false }
            if case .unsupported = e as? ProxyError { quotaSupported = false }
        }
    }

    private func evaluateAlerts() {
        let reachable = { if case .up = connection { return true } else { return false } }()
        let inputs = AlertInputs(previous: previousStatus, status: status, quota: quota, reachable: reachable,
                                 appSwitchedTo: appSwitchedTo.flatMap { Date().timeIntervalSince($0.at) < 10 ? $0.name : nil })
        let (alerts, state) = AlertEngine.evaluate(inputs, state: prefs.alertState, prefs: prefs.alertPrefs)
        prefs.alertState = state
        for a in alerts { Notifier.shared.post(a) }
    }

    var reachable: Bool { if case .up = connection { return true } else { return false } }

    var iconModel: IconModel {
        MenuBarState.compute(IconInputs(status: status, quota: quotaSupported ? quota : nil, reachable: reachable, lastSuccessAt: lastSuccessAt,
                                        pollInterval: popoverOpen ? prefs.pollOpen : prefs.pollClosed, rotatedAt: rotatedAt, rotatedTo: rotatedTo,
                                        pinCurrent: prefs.pinCurrent, showRemaining: prefs.showRemaining, warnLevel: prefs.warnLevel))
    }

    // MARK: - actions

    func refreshNow() { Task { await poll() } }

    func switchTo(_ name: String) {
        Task {
            do {
                let r = try await client.switchTo(name)
                appSwitchedTo = (name, Date())
                let outcome = Derived.switchOutcome(r)
                showToast(outcome.kind == .ok ? .ok : outcome.kind == .warn ? .warn : .error, outcome.text)
                await poll()
            } catch let e as ProxyError {
                if e == .unsupported { switchSupported = false }
                showToast(.error, "Switch failed: \(e.message)")
            } catch {
                showToast(.error, "Switch failed: \(error.localizedDescription)")
            }
        }
    }

    func reloadConfig() {
        Task {
            do {
                let r = try await client.reload()
                showToast(.ok, r.added > 0 ? "Reloaded (+\(r.added) new account)" : "Reloaded")
                await poll()
            } catch let e as ProxyError {
                showToast(.error, "Reload failed: \(e.message)")
            } catch {
                showToast(.error, "Reload failed: \(error.localizedDescription)")
            }
        }
    }

    var settingsOps: SettingsOps {
        let runner = self.runner
        let file = self.configFile
        let client = self.client
        return SettingsOps(
            run: { args, stdin in try await runner.run(args, stdin: stdin) },
            update: { mutate in try file.update(mutate) },
            reload: { try await client.reload() },
            serverVersion: serverVersion
        )
    }

    /// Apply a change and report through the toast; returns the outcome for callers that need it.
    @discardableResult
    func apply(_ change: SettingChange, label: String) async -> ApplyOutcome? {
        do {
            let outcome = try await settingsOps.apply(change)
            if outcome.restartRequired {
                restartPending.insert(label)
                showToast(.warn, "\(label) saved — restart the proxy to apply")
            } else if let note = outcome.note {
                showToast(.warn, "\(label): \(note)")
            } else {
                showToast(.ok, "\(label) applied")
            }
            if case .json(let path, _, _) = change, path.first == "proxy" { reloadEndpoint() }
            loadConfigRoot()
            await poll()
            return outcome
        } catch let e as CLIError {
            showToast(.error, "\(label): \(e.message)")
        } catch let e as SettingsError {
            showToast(.error, "\(label): \(e.message)")
        } catch let e as ConfigError {
            showToast(.error, "\(label): \(e)")
        } catch {
            showToast(.error, "\(label): \(error.localizedDescription)")
        }
        return nil
    }

    func runCLI(_ args: [String], stdin: String? = nil, timeout: TimeInterval = 30, onLine: (@Sendable (OutputLine) -> Void)? = nil) async throws -> CLIResult {
        try await runner.run(args, stdin: stdin, timeout: timeout, onLine: onLine)
    }

    /// `launchctl kickstart -k` on the agent, then poll fast until `startedAt` changes.
    func restartService() async {
        startedAtBeforeRestart = status?.server?.startedAt
        restartWatchUntil = Date().addingTimeInterval(30)
        let uid = getuid()
        let result = try? await CLIRunner.execute(executable: URL(fileURLWithPath: "/bin/launchctl"),
                                                  arguments: ["kickstart", "-k", "gui/\(uid)/\(ProxyLocator.launchAgentLabel)"],
                                                  environment: ProcessInfo.processInfo.environment, timeout: 15)
        if let result, !result.succeeded {
            showToast(.error, "launchctl: \(result.failureMessage)")
            restartWatchUntil = nil
        } else {
            showToast(.info, "Restarting the proxy…")
        }
    }

    // MARK: - config document & service health (settings screens)

    func loadConfigRoot() {
        do {
            configRoot = try configFile.load().root
            configError = nil
        } catch let e as ConfigError {
            configError = "\(e)"
        } catch {
            configError = error.localizedDescription
        }
    }

    func configValue(_ path: [String]) -> JSON {
        configRoot.map { ConfigFile.value($0, path: path) } ?? .null
    }

    func refreshServiceHealth() async {
        let uid = getuid()
        let plist = ProxyLocator.launchAgentPath()
        let installed = FileManager.default.fileExists(atPath: plist.path)
        let env = ProcessInfo.processInfo.environment
        async let print = try? CLIRunner.execute(executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: ["print", "gui/\(uid)/\(ProxyLocator.launchAgentLabel)"], environment: env, timeout: 10)
        async let lsof = try? CLIRunner.execute(executable: URL(fileURLWithPath: "/usr/sbin/lsof"), arguments: ["-nP", "-iTCP:\(endpoint.port)", "-sTCP:LISTEN", "-Fpc"], environment: env, timeout: 10)
        let (p, l) = await (print, lsof)
        let health = ServiceHealth.parse(launchctlPrint: (p?.succeeded ?? false) ? p?.stdout : nil, installed: installed)
        let owner = l.flatMap { $0.succeeded ? PortOwner.parse(lsofFields: $0.stdout) : nil }
        serviceHealth = health
        serviceDiagnosis = ServiceDiagnosis.diagnose(health: health, portOwner: owner)
    }

    /// `teamclaude service install|uninstall` through the CLI, then re-diagnose.
    func service(_ verb: String) async {
        do {
            let r = try await runner.run(["service", verb], timeout: 30)
            if r.succeeded { showToast(.ok, "Service \(verb) done") } else { showToast(.error, "service \(verb): \(r.failureMessage)") }
        } catch let e as CLIError {
            showToast(.error, e.message)
        } catch {
            showToast(.error, error.localizedDescription)
        }
        await resolveCLI()
        await refreshServiceHealth()
        await poll()
    }

    /// Send SIGTERM to the process holding the port (a foreground `teamclaude server`), then kickstart the agent.
    func quitPortOwnerAndRestart(pid: Int) async {
        kill(pid_t(pid), SIGTERM)
        try? await Task.sleep(for: .seconds(2))
        await restartService()
        try? await Task.sleep(for: .seconds(3))
        await refreshServiceHealth()
    }

    func clearRestartPending() { restartPending.removeAll() }

    func showToast(_ kind: Toast.Kind, _ text: String) {
        toast = Toast(kind: kind, text: text, at: Date())
        let stamp = toast?.at
        Task {
            try? await Task.sleep(for: .seconds(kind == .error ? 12 : 6))
            if toast?.at == stamp { toast = nil }
        }
    }

    func displayName(_ name: String) -> String {
        guard prefs.hidePII else { return name }
        return MenuBarState.shortName(name) + "…"
    }

    /// The local part of an email for tight spots (`alice` for `alice@example.com`).
    func compactName(_ name: String) -> String {
        if prefs.hidePII { return MenuBarState.shortName(name) + "…" }
        if let at = name.firstIndex(of: "@") { return String(name[..<at]) }
        return name
    }
}
