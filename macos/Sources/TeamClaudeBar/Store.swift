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
    private(set) var quotaAt: Date?
    private(set) var previousStatus: StatusSnapshot?
    private(set) var connection: Connection = .starting
    private(set) var lastSuccessAt: Date?
    private(set) var quotaSupported = true
    private(set) var switchSupported = true
    private(set) var endpoint: ProxyEndpoint
    private(set) var configFile: ConfigFile
    private(set) var cliLocation: CLILocation?
    /// What `teamclaude version` printed for the CLI the app runs.
    private(set) var cliVersion: String?
    /// What `teamclaude update` installed while the proxy still runs the previous version.
    private(set) var installedVersion: String?
    private(set) var rotatedAt: Date?
    private(set) var rotatedTo: String?
    private(set) var restartPending: Set<String> = []
    /// The config document as last read, for the settings screens.
    private(set) var configRoot: JSON?
    private(set) var configError: String?
    private(set) var serviceDiagnosis: ServiceDiagnosis?
    private(set) var serviceHealth: ServiceHealth?
    var toast: Toast?
    /// The loop switches to the fast cadence at once, not when the closed-interval sleep ends.
    var popoverOpen = false { didSet { if popoverOpen != oldValue { rescheduleLoop() } } }
    /// Informational banners the user closed this session.
    var dismissedNotices: Set<String> = []
    private(set) var updateRunning = false
    private(set) var updateNote: String?
    private(set) var failureStreak = 0
    /// Display names that stay unique per account (see `Derived.aliases`).
    private(set) var aliases: [String: String] = [:]
    private(set) var shortAliases: [String: String] = [:]
    private(set) var history = HistoryStore()
    /// The display is asleep or the session is locked: nobody is looking, poll rarely.
    private(set) var displayAsleep = false

    let prefs = Preferences.shared
    private var client: ProxyClient
    private var runner: CLIRunner
    private var pollTask: Task<Void, Never>?
    private var pollInFlight = false
    private var pollAgain = false
    private var appSwitchedTo: (name: String, at: Date)?
    private var restartWatchUntil: Date?
    private var restartRequestedAt: Date?
    private var alertState: AlertState
    private var observers: [any NSObjectProtocol] = []
    private var historySavedAt = Date()

    nonisolated static let historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "TeamClaudeBar/history.json")

    init() {
        let ep = ProxyEndpoint()
        endpoint = ep
        configFile = ConfigFile(path: ConfigFile.resolvePath())
        client = ProxyClient(endpoint: ep)
        cliLocation = nil
        runner = CLIRunner(location: nil)
        alertState = Preferences.shared.alertState
        reloadEndpoint()
        Task { await self.resolveCLI() }
        Task.detached { [url = AppStore.historyURL] in
            let loaded = HistoryStore.load(from: url)
            await MainActor.run { [weak self] in if let self, self.history.samples.isEmpty { self.history = loaded } }
        }
    }

    /// The running proxy's version when it reports one (1.1.19+), else the CLI's: what the
    /// "applies live since" gates compare against.
    var serverVersion: String? { status?.server?.version ?? cliVersion }

    // MARK: - lifecycle

    func start() {
        rescheduleLoop(pollNow: true)
        guard observers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        })
        // Display off or session locked: stretch the cadence; back on: poll now.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.displayAsleep = true; self?.rescheduleLoop() }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.displayAsleep = false; self?.rescheduleLoop(pollNow: true) }
            })
        }
    }

    func stop() {
        pollTask?.cancel()
        saveHistory()
    }

    /// Restart the loop so the next sleep uses the current cadence; `pollNow` also polls first.
    private func rescheduleLoop(pollNow: Bool = false) {
        guard pollTask != nil || pollNow else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var skipPoll = !pollNow
            while !Task.isCancelled {
                guard let self else { return }
                if !skipPoll { await self.poll() }
                skipPoll = false
                let delay = self.nextDelay()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func nextDelay() -> TimeInterval {
        if let until = restartWatchUntil, Date() < until { return 1 }
        if case .down = connection { return min(30, pow(2, Double(min(failureStreak, 5)))) }
        if popoverOpen { return prefs.pollOpen }
        if displayAsleep { return 300 }
        // Low Power Mode or a hot machine: half as often, the proxy sweeps quotas on every status call.
        let info = ProcessInfo.processInfo
        let eased = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        return eased ? prefs.pollClosed * 2 : prefs.pollClosed
    }

    /// Re-read port/host/key from the config (after a key rotation or a restart that changed the port).
    func reloadEndpoint() {
        let file = ConfigFile(path: ConfigFile.resolvePath(env: mergedEnv()))
        configFile = file
        guard let root = try? file.load().root else { return }
        let s = ConfigFile.proxySettings(root)
        // The CLI's rule: a wildcard bind is not an address to dial, any other host is where the proxy actually is.
        var host = (s.host == "0.0.0.0" || s.host == "::" || s.host.isEmpty) ? "127.0.0.1" : s.host
        var port = s.port
        if !ProxyEndpoint.isValid(host: host, port: port) {
            // A hand-edited value the app cannot dial must not become a crash loop; say so and use the defaults.
            configError = L("proxy.host/port in the config (%@) cannot be dialled; using 127.0.0.1:3456", "\(s.host):\(s.port)")
            host = "127.0.0.1"; port = 3456
        }
        let ep = ProxyEndpoint(host: host, port: port, apiKey: s.apiKey)
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
            cliVersion = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
        }
    }

    // MARK: - updates

    /// `teamclaude update` (npm install -g) through the CLI; its output says whether there was anything to install.
    func runUpdate() async {
        guard !updateRunning else { return }
        updateRunning = true
        updateNote = nil
        showToast(.info, L("Checking npm for a newer teamclaude…"))
        do {
            let r = try await runner.run(["update"], timeout: 600)
            let installed = UpdateCheck.installedVersion(fromUpdateOutput: r.stdout)
            if r.succeeded, let installed {
                // The running proxy is still the old version until it restarts; the version gate must not move early.
                installedVersion = installed
                restartPending.insert("teamclaude \(installed)")
                updateNote = L("Updated to %@ — restart the proxy to run it", installed)
                showToast(.ok, updateNote!)
            } else if r.succeeded {
                updateNote = r.stdout.split(separator: "\n").last.map(String.init) ?? L("Already up to date")
                showToast(.info, updateNote!)
            } else {
                updateNote = r.failureMessage
                showToast(.error, L("Update failed: %@", r.failureMessage))
            }
        } catch let e as CLIError {
            updateNote = e.message
            showToast(.error, e.message)
        } catch {
            updateNote = error.localizedDescription
            showToast(.error, error.localizedDescription)
        }
        updateRunning = false
    }

    // MARK: - polling

    /// One poll at a time: a second request while one is in flight runs once more
    /// afterwards, so a slow earlier reply can never land on top of a newer one.
    func poll() async {
        if pollInFlight { pollAgain = true; return }
        pollInFlight = true
        defer { pollInFlight = false }
        repeat {
            pollAgain = false
            await pollOnce()
        } while pollAgain
    }

    private func pollOnce() async {
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
        recordHistory()
    }

    /// True only while the restart the user asked for is still expected to land.
    private var restartInProgress: Bool {
        guard restartRequestedAt != nil, let until = restartWatchUntil else { return false }
        if Date() < until { return true }
        // The window passed without a restart being seen: from here on a missed poll is an outage again.
        restartRequestedAt = nil
        restartWatchUntil = nil
        return false
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
            if wasDown { showToast(.ok, L("Proxy is back")) }
            refreshAliases(s)
            // A `startedAt` later than the restart request is the restart, whether or not the proxy answered before it.
            // A server that reports no `startedAt` cannot be watched, so any answer after the request counts.
            if let requested = restartRequestedAt, s.server?.startedAt.map({ $0 > requested }) ?? true {
                restartRequestedAt = nil
                restartWatchUntil = nil
                restartPending.removeAll()
                if let installedVersion { cliVersion = installedVersion; self.installedVersion = nil }
                showToast(.ok, L("Proxy restarted"))
            }
            let prevTarget = previousStatus?.effectiveDefaultTarget
            // The same ten-second window the alert engine uses for "the app did this itself".
            let justSwitchedTo = appSwitchedTo.flatMap { Date().timeIntervalSince($0.at) < 10 ? $0.name : nil }
            if let prev = prevTarget, let cur = s.effectiveDefaultTarget, prev != cur {
                if justSwitchedTo != cur {
                    rotatedAt = Date()
                    rotatedTo = cur
                }
                let reason = Derived.rotationReason(from: prev, to: cur, previous: previousStatus, status: s)
                prefs.rotationLog.append(RotationEvent(at: Date(), from: prev, to: cur, reason: justSwitchedTo == cur ? L("switched from the app") : reason, manual: justSwitchedTo == cur))
            }
        case .failure(let e):
            failureStreak += 1
            let err = (e as? ProxyError) ?? .badReply(e.localizedDescription)
            NSLog("[TeamClaudeBar] status poll failed: %@ (%@)", err.message, String(describing: e))
            // A restart the user asked for is expected to miss a few polls (launchd throttle, cold start); if the
            // port changed in the config, the new one is where it comes back. Only for the 30 s watch window.
            if restartInProgress { reloadEndpoint(); return }
            // One missed poll is a blip (a busy proxy answers late); two in a row is down.
            if failureStreak >= 2 {
                if case .down = connection {} else { connection = .down(since: Date(), error: err) }
                // A port changed by hand and a restart the app did not request: the new address is in the file.
                if case .unreachable = err { reloadEndpoint() }
            }
            if err == .unauthorized { reloadEndpoint() }
        }
    }

    private func applyQuota(_ qr: Result<QuotaSnapshot, Error>) {
        switch qr {
        case .success(let q):
            quota = q
            quotaAt = Date()
            quotaSupported = true
        case .failure(let e):
            if case .notTeamClaude = e as? ProxyError { quotaSupported = false }
            if case .unsupported = e as? ProxyError { quotaSupported = false }
        }
    }

    /// The fleet numbers are only as fresh as the last `/quota` reply, which is the slow one on a busy proxy.
    var freshQuota: QuotaSnapshot? {
        guard quotaSupported, let quota, let at = quotaAt else { return nil }
        let staleAfter = max(3 * (popoverOpen ? prefs.pollOpen : prefs.pollClosed), 90)
        return Date().timeIntervalSince(at) > staleAfter ? nil : quota
    }

    private func evaluateAlerts() {
        // While a restart is expected (30 s), a missed poll is not an outage.
        let reachable = !isDown || restartInProgress
        let inputs = AlertInputs(previous: previousStatus, status: status, quota: freshQuota, reachable: reachable,
                                 appSwitchedTo: appSwitchedTo.flatMap { Date().timeIntervalSince($0.at) < 10 ? $0.name : nil })
        let (alerts, state) = AlertEngine.evaluate(inputs, state: alertState, prefs: prefs.alertPrefs)
        // Persisting is a plist rewrite through cfprefsd; every poll for weeks adds up, so only on change.
        if state != alertState {
            alertState = state
            prefs.alertState = state
        }
        for a in alerts { Notifier.shared.post(maskingNames(in: a)) }
    }

    /// "Hide account e-mails" applies to notifications too: they sit on the lock screen and in Notification Center history.
    private func maskingNames(in alert: Alert) -> Alert {
        guard prefs.hidePII, let names = status?.accounts.map(\.name) else { return alert }
        var a = alert
        for name in names.sorted(by: { $0.count > $1.count }) {
            a.title = a.title.replacingOccurrences(of: name, with: displayName(name))
            a.body = a.body.replacingOccurrences(of: name, with: displayName(name))
        }
        return a
    }

    private func recordHistory() {
        guard let status else { return }
        let now = Date()
        if history.record(HistorySample(status: status, quota: freshQuota, at: now)), now.timeIntervalSince(historySavedAt) > 300 {
            saveHistory()
        }
    }

    private func saveHistory() {
        historySavedAt = Date()
        let snapshot = history
        Task.detached { try? snapshot.save(to: AppStore.historyURL) }
    }

    var isDown: Bool { if case .down = connection { return true } else { return false } }

    var restartPendingText: String? {
        guard !restartPending.isEmpty else { return nil }
        let changes = restartPending.count == 1 ? L("1 change needs a proxy restart") : L("%d changes need a proxy restart", restartPending.count)
        return changes + " (" + restartPending.sorted().joined(separator: ", ") + ")"
    }

    var iconModel: IconModel {
        MenuBarState.compute(IconInputs(status: status, quota: freshQuota, reachable: !isDown, lastSuccessAt: lastSuccessAt,
                                        pollInterval: popoverOpen ? prefs.pollOpen : prefs.pollClosed, rotatedAt: rotatedAt, rotatedTo: rotatedTo,
                                        pinCurrent: prefs.pinCurrent, showRemaining: prefs.showRemaining))
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
                showToast(.error, L("Switch failed: %@", e.message))
            } catch {
                showToast(.error, L("Switch failed: %@", error.localizedDescription))
            }
        }
    }

    /// The hotkey: move traffic to the next account in priority order that can serve, wrapping around.
    func switchToNextAvailable() {
        guard let status, !status.accounts.isEmpty else { showToast(.warn, L("No accounts to switch between")); return }
        // Stay within the current account's provider: a Codex account cannot take Claude traffic.
        let provider = status.current?.provider ?? Providers.anthropic
        let ordered = status.accountsByPriority.filter { status.providers.count == 1 || $0.provider == provider }
        guard !ordered.isEmpty else { showToast(.warn, L("No other account can serve right now")); return }
        let start = ordered.firstIndex { $0.name == status.currentAccount } ?? -1
        for offset in 1...ordered.count {
            let candidate = ordered[(start + offset) % ordered.count]
            if candidate.unavailable == nil, candidate.name != status.currentAccount {
                switchTo(candidate.name)
                return
            }
        }
        showToast(.warn, L("No other account can serve right now"))
    }

    /// `POST /teamclaude/reload`; the result is what callers report, not a guess.
    @discardableResult
    func reloadConfig() async -> Bool {
        do {
            let r = try await client.reload()
            showToast(.ok, r.added > 0 ? L("Reloaded (+%d new)", r.added) : L("Reloaded"))
            await poll()
            return r.ok
        } catch let e as ProxyError {
            showToast(.error, L("Reload failed: %@", e.message))
        } catch {
            showToast(.error, L("Reload failed: %@", error.localizedDescription))
        }
        return false
    }

    var settingsOps: SettingsOps {
        let runner = self.runner
        let file = self.configFile
        let client = self.client
        return SettingsOps(
            run: { args, stdin in try await runner.run(args, stdin: stdin) },
            // The read, fsync and rename happen off the main actor.
            update: { mutate in try await Task.detached { try file.update(mutate) }.value },
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
                showToast(.warn, L("%@ saved — restart the proxy to apply", label))
            } else if let note = outcome.note {
                showToast(.warn, "\(label): \(note)")
            } else {
                showToast(.ok, L("%@ applied", label))
            }
            // A live proxy key change moves the client now; a port or host change waits for the restart it needs.
            if case .json(let path, _, _) = change, path.first == "proxy", !outcome.restartRequired { reloadEndpoint() }
            loadConfigRoot()
            await poll()
            return outcome
        } catch let e as CLIError {
            showToast(.error, "\(label): \(e.message)")
        } catch let e as SettingsError {
            showToast(.error, "\(label): \(e.message)")
        } catch let e as ConfigError {
            showToast(.error, "\(label): \(e.message)")
        } catch {
            showToast(.error, "\(label): \(error.localizedDescription)")
        }
        return nil
    }

    // Account actions the card and the table share, with one wording each.
    func setPriority(_ name: String, org: String? = nil, _ value: PriorityValue) async {
        await apply(.priority(account: name, org: org, value: value), label: L("Priority of %@", displayName(name)))
    }

    func setEnabled(_ name: String, org: String? = nil, _ enabled: Bool) async {
        await apply(.enabled(account: name, org: org, enabled: enabled), label: enabled ? L("Enable %@", displayName(name)) : L("Disable %@", displayName(name)))
    }

    func removeAccount(_ name: String, org: String? = nil) async {
        await apply(.removeAccount(name: name, org: org), label: L("Remove %@", displayName(name)))
    }

    static var removeAccountMessage: String { L("The entry leaves the config now; the proxy keeps serving it until it restarts.") }

    func runCLI(_ args: [String], stdin: String? = nil, stdinWriter: StdinWriter? = nil, timeout: TimeInterval = 30,
                onLine: (@Sendable (OutputLine) -> Void)? = nil) async throws -> CLIResult {
        try await runner.run(args, stdin: stdin, stdinWriter: stdinWriter, timeout: timeout, onLine: onLine)
    }

    /// `launchctl kickstart -k` on the agent, then poll fast until `startedAt` moves past the request.
    func restartService() async {
        restartRequestedAt = Date()
        restartWatchUntil = Date().addingTimeInterval(30)
        rescheduleLoop()
        let uid = getuid()
        do {
            let result = try await CLIRunner.execute(executable: URL(fileURLWithPath: "/bin/launchctl"),
                                                     arguments: ["kickstart", "-k", "gui/\(uid)/\(ProxyLocator.launchAgentLabel)"],
                                                     environment: ProcessInfo.processInfo.environment, timeout: 15)
            if result.succeeded {
                showToast(.info, L("Restarting the proxy…"))
                return
            }
            showToast(.error, "launchctl: \(result.failureMessage)")
        } catch {
            showToast(.error, "launchctl: \((error as? CLIError)?.message ?? error.localizedDescription)")
        }
        restartRequestedAt = nil
        restartWatchUntil = nil
    }

    // MARK: - config document & service health (settings screens)

    /// Re-read the config for the settings screens, off the main actor; the screens update when it lands.
    func loadConfigRoot() {
        let file = configFile
        Task {
            let result: Result<JSON, Error> = await Task.detached { Result { try file.load().root } }.value
            switch result {
            case .success(let root): configRoot = root; configError = nil
            case .failure(let e as ConfigError): configError = e.message
            case .failure(let e): configError = e.localizedDescription
            }
        }
    }

    func configValue(_ path: [String]) -> JSON {
        configRoot.map { ConfigFile.value($0, path: path) } ?? .null
    }

    /// Write a whole document (the raw editor): the same atomic path as every other edit, then reload.
    func writeConfigDocument(_ root: JSON) async -> Bool {
        let file = configFile
        do {
            try await Task.detached { try file.withLock { try file.write(root) } }.value
            reloadEndpoint()
            loadConfigRoot()
            let ok = await reloadConfig()
            return ok
        } catch {
            showToast(.error, L("Could not write the config: %@", error.localizedDescription))
            return false
        }
    }

    func refreshServiceHealth() async {
        let uid = getuid()
        let plist = ProxyLocator.launchAgentPath()
        let installed = FileManager.default.fileExists(atPath: plist.path)
        let env = ProcessInfo.processInfo.environment
        async let print = try? CLIRunner.execute(executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: ["print", "gui/\(uid)/\(ProxyLocator.launchAgentLabel)"], environment: env, timeout: 10)
        async let lsof = portOwner()
        let (p, owner) = await (print, lsof)
        let health = ServiceHealth.parse(launchctlPrint: (p?.succeeded ?? false) ? p?.stdout : nil, installed: installed)
        serviceHealth = health
        serviceDiagnosis = ServiceDiagnosis.diagnose(health: health, portOwner: owner)
    }

    private func portOwner() async -> PortOwner? {
        let r = try? await CLIRunner.execute(executable: URL(fileURLWithPath: "/usr/sbin/lsof"), arguments: ["-nP", "-iTCP:\(endpoint.port)", "-sTCP:LISTEN", "-Fpc"],
                                             environment: ProcessInfo.processInfo.environment, timeout: 10)
        return r.flatMap { $0.succeeded ? PortOwner.parse(lsofFields: $0.stdout) : nil }
    }

    /// `teamclaude service install|uninstall` through the CLI, then re-diagnose.
    func service(_ verb: String) async {
        do {
            let r = try await runner.run(["service", verb], timeout: 30)
            if r.succeeded { showToast(.ok, verb == "install" ? L("Service installed") : verb == "uninstall" ? L("Service uninstalled") : L("Service %@ done", verb)) } else { showToast(.error, "service \(verb): \(r.failureMessage)") }
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
    /// The owner is looked up again first: the diagnosis may be minutes old and pids get reused.
    func quitPortOwnerAndRestart(pid: Int) async {
        guard let owner = await portOwner(), owner.pid == pid else {
            showToast(.warn, L("That process no longer holds the port"))
            await refreshServiceHealth()
            return
        }
        // lsof's command field is the bare (truncated) name: every Node process is "node". The argv says whether it is teamclaude.
        let argv = (try? await CLIRunner.execute(executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-o", "command=", "-p", String(pid)],
                                                 environment: ProcessInfo.processInfo.environment, timeout: 5))?.stdout ?? ""
        guard argv.contains("teamclaude") else {
            showToast(.error, L("Port %d is held by %@, not teamclaude — quit it yourself or change the port", endpoint.port, owner.command.isEmpty ? "pid \(pid)" : owner.command))
            return
        }
        if kill(pid_t(pid), SIGTERM) != 0 {
            showToast(.error, L("Could not signal pid %d: %@", pid, String(cString: strerror(errno))))
            return
        }
        try? await Task.sleep(for: .seconds(2))
        await restartService()
        try? await Task.sleep(for: .seconds(3))
        await refreshServiceHealth()
    }

    func deleteStateFile() {
        do {
            try FileManager.default.removeItem(at: configFile.statePath)
            showToast(.ok, L("State file deleted"))
        } catch {
            showToast(.error, L("Could not delete the state file: %@", error.localizedDescription))
        }
    }

    /// status.json, quota.json, the config with every secret replaced, `launchctl print`, and the app's
    /// own state, in a folder under Downloads: what a bug report needs and nothing it must not carry.
    func exportDiagnostics() async -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appending(path: "teamclaude-diagnostics-\(stamp)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let status { try status.raw.pretty().write(to: dir.appending(path: "status.json"), atomically: true, encoding: .utf8) }
            if let quota { try quota.raw.pretty().write(to: dir.appending(path: "quota.json"), atomically: true, encoding: .utf8) }
            if let root = try? configFile.load().root {
                try ConfigRedaction.redact(root).pretty().write(to: dir.appending(path: "config-redacted.json"), atomically: true, encoding: .utf8)
            }
            let uid = getuid()
            let print = try? await CLIRunner.execute(executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: ["print", "gui/\(uid)/\(ProxyLocator.launchAgentLabel)"],
                                                     environment: ProcessInfo.processInfo.environment, timeout: 10)
            try (print?.stdout ?? "(launchctl print failed)").write(to: dir.appending(path: "launchctl.txt"), atomically: true, encoding: .utf8)
            var app = ["TeamClaude Bar \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "(dev)")"]
            app.append("endpoint \(endpoint.label) · connection \(connection) · cli \(cliLocation?.describe ?? "not found") · cli version \(cliVersion ?? "?") · server version \(status?.server?.version ?? "not reported")")
            app.append("service \(serviceDiagnosis?.text ?? "not checked")")
            app.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            try app.joined(separator: "\n").write(to: dir.appending(path: "app.txt"), atomically: true, encoding: .utf8)
            showToast(.ok, L("Diagnostics written to Downloads"))
            return dir
        } catch {
            showToast(.error, L("Could not export diagnostics: %@", error.localizedDescription))
            return nil
        }
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

    // MARK: - names

    private func refreshAliases(_ s: StatusSnapshot) {
        let rows = s.accounts.map { (name: $0.name, org: $0.orgName) }
        aliases = Derived.aliases(for: rows)
        shortAliases = Derived.aliases(for: rows, base: MenuBarState.shortName)
    }

    /// The name as the user wants it shown: the full name, or a unique short alias with Hide PII on.
    func displayName(_ name: String) -> String {
        guard prefs.hidePII else { return name }
        return (shortAliases[name] ?? MenuBarState.shortName(name)) + "…"
    }

    /// The local part of an email for tight spots (`alice` for `alice@example.com`), kept unique across accounts.
    func compactName(_ name: String) -> String {
        if prefs.hidePII { return displayName(name) }
        return aliases[name] ?? String(name.split(separator: "@").first ?? Substring(name))
    }
}

/// Everything the raw editor and the diagnostics export must never show.
enum ConfigRedaction {
    static let placeholder = "•••"

    static func redact(_ json: JSON) -> JSON {
        switch json {
        case .object(let o):
            var out: [String: JSON] = [:]
            for (k, v) in o {
                if SettingsSchema.sensitiveKeys.contains(k), v.string != nil { out[k] = .string(placeholder) }
                else { out[k] = redact(v) }
            }
            return .object(out)
        case .array(let a):
            return .array(a.map(redact))
        default:
            return json
        }
    }

    /// Put the on-disk secrets back where the edited document still carries the placeholder,
    /// matching account rows by `id`, then by `name`, then by position.
    static func restore(_ edited: JSON, from disk: JSON) -> JSON {
        func merge(_ e: JSON, _ d: JSON) -> JSON {
            switch (e, d) {
            case (.object(let eo), .object(let dobj)):
                var out: [String: JSON] = [:]
                for (k, v) in eo {
                    if v.string == placeholder, let orig = dobj[k], orig.string != nil { out[k] = orig }
                    else if let dv = dobj[k] { out[k] = merge(v, dv) }
                    else { out[k] = v }
                }
                return .object(out)
            case (.array(let ea), .array(let da)):
                return .array(ea.enumerated().map { i, item in
                    let match = da.first { $0["id"].string != nil && $0["id"].string == item["id"].string }
                        ?? da.first { $0["name"].string != nil && $0["name"].string == item["name"].string }
                        ?? (i < da.count ? da[i] : nil)
                    return match.map { merge(item, $0) } ?? item
                })
            default:
                return e
            }
        }
        return merge(edited, disk)
    }
}
