import SwiftUI
import AppKit
import TeamClaudeCore

struct AccountsPane: View {
    @Environment(AppStore.self) private var store
    @State private var adding: AddAccountMode?
    @State private var expanded: Set<String> = []

    var rows: [JSON] { store.configValue(["accounts"]).array ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(rows.count) account\(rows.count == 1 ? "" : "s") in the config").font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu("Add account…") {
                    Button("Claude subscription (browser sign-in)") { adding = .oauth }
                    Button("Claude subscription (paste code)") { adding = .token }
                    Button("Anthropic API key") { adding = .apiKey }
                    Button("OpenAI Codex subscription") { adding = .codex }
                    Divider()
                    Button("Import from Claude Code") { adding = .importCLI }
                    Button("Import from a credentials file…") { adding = .importFile }
                }.fixedSize()
            }
            if rows.isEmpty {
                Text("No accounts yet — add a Claude subscription, an API key, or import the one Claude Code is logged into.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                AccountCard(row: row, live: store.status?.account(named: row["name"].string ?? ""), tier: store.quota?.account(named: row["name"].string ?? "")?.tier,
                            expanded: expanded.contains(row["name"].string ?? ""),
                            toggle: { let n = row["name"].string ?? ""; if expanded.contains(n) { expanded.remove(n) } else { expanded.insert(n) } })
            }
            Text("Priority: lower is preferred; a strictly lower value preempts a healthy current account. Disabling keeps the entry but takes it out of rotation. Removing needs a proxy restart.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $adding) { mode in AddAccountSheet(mode: mode) { adding = nil } }
    }
}

struct AccountCard: View {
    @Environment(AppStore.self) private var store
    var row: JSON
    var live: Account?
    var tier: Tier?
    var expanded: Bool
    var toggle: () -> Void
    @State private var priorityText = ""
    @State private var confirmRemove = false

    var name: String { row["name"].string ?? "" }
    var isCurrent: Bool { store.status?.currentAccount == name }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8)).foregroundStyle(isCurrent ? Color.accentColor : Color.clear)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.displayName(name)).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text([row["orgName"].string, row["type"].string, row["provider"].string, row["importFrom"].string.map { "from \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Chip(text: Derived.tierBadge(tier))
                if let live {
                    Chip(text: live.disabled ? "disabled" : live.status, color: live.disabled ? .secondary : live.status == "active" ? .green : live.status == "throttled" ? .yellow : .red)
                    if let why = UnavailableText.label(live.unavailable) { Chip(text: why, color: .yellow) }
                } else if row["disabled"].bool == true {
                    Chip(text: "disabled", color: .secondary)
                } else {
                    Chip(text: "not loaded", color: .secondary)
                }
                Spacer()
                if !isCurrent, live != nil { Button("Make current") { store.switchTo(name) }.controlSize(.small) }
                Button(expanded ? "Less" : "More") { toggle() }.controlSize(.small)
            }
            HStack(spacing: 12) {
                Toggle("On", isOn: Binding(get: { row["disabled"].bool != true }, set: { on in Task { await store.apply(.enabled(account: name, org: nil, enabled: on), label: on ? "Enable \(name)" : "Disable \(name)") } })).toggleStyle(.switch).controlSize(.small)
                HStack(spacing: 4) {
                    Text("Priority").font(.system(size: 12)).fixedSize()
                    TextField("0", text: $priorityText).textFieldStyle(.roundedBorder).frame(width: 50).multilineTextAlignment(.trailing).onSubmit(applyPriority)
                    Button("Top") { Task { await store.apply(.priority(account: name, org: nil, value: .first), label: "Priority of \(name)") } }.controlSize(.mini).fixedSize()
                    Button("Bottom") { Task { await store.apply(.priority(account: name, org: nil, value: .last), label: "Priority of \(name)") } }.controlSize(.mini).fixedSize()
                }
                if let live { Text("\(live.sessions) sessions · \(live.usage.totalRequests) requests").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button("Remove…") { confirmRemove = true }.controlSize(.small)
            }
            if expanded {
                Divider()
                ForEach(SettingsSchema.accountFields) { field in
                    FieldRow(field: field, value: row[field.id]) { new in
                        Task { await store.apply(.accountField(name: name, id: row["id"].string, key: field.id, value: new, applies: field.applies), label: "\(field.label) of \(name)") }
                    }
                }
                if let uuid = row["accountUuid"].string {
                    Text("accountUuid \(uuid)" + (row["orgUuid"].string.map { " · orgUuid \($0)" } ?? "")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Copy pinned run command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("TC_ACCT=\(uuid) teamclaude run", forType: .string)
                        store.showToast(.ok, "Copied: TC_ACCT=… teamclaude run")
                    }.controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { priorityText = String(row["priority"].int ?? 0) }
        .onChange(of: row["priority"].int ?? 0) { _, v in priorityText = String(v) }
        .confirmationDialog("Remove \(name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await store.apply(.removeAccount(name: name, org: row["orgUuid"].string), label: "Remove \(name)") } }
        } message: { Text("The entry leaves the config now; the proxy keeps serving it until it restarts.") }
    }

    private func applyPriority() {
        guard let n = Int(priorityText.trimmingCharacters(in: .whitespaces)) else { return }
        Task { await store.apply(.priority(account: name, org: nil, value: .number(n)), label: "Priority of \(name)") }
    }
}

// MARK: - Add account

enum AddAccountMode: String, Identifiable {
    case oauth, token, apiKey, codex, importCLI, importFile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .oauth: return "Claude subscription — browser sign-in"
        case .token: return "Claude subscription — paste the code"
        case .apiKey: return "Anthropic API key"
        case .codex: return "OpenAI Codex subscription"
        case .importCLI: return "Import from Claude Code"
        case .importFile: return "Import from a credentials file"
        }
    }
    var help: String {
        switch self {
        case .oauth: return "Opens your browser for the same OAuth flow Claude Code uses; the CLI waits up to two minutes for the callback."
        case .token: return "For when the browser cannot reach this Mac: open the link the CLI prints, sign in, then paste the code or the full callback URL here."
        case .apiKey: return "A Console API key (billed per token). The key is passed to the CLI on stdin and never appears in a command line."
        case .codex: return "Signs in through the Codex CLI's flow on port 1455 (fails if `codex login` is already running)."
        case .importCLI: return "Copies the credentials Claude Code is logged in with (macOS may show a Keychain prompt owned by `security`)."
        case .importFile: return "Reads accessToken/refreshToken from a credentials JSON file."
        }
    }
}

struct AddAccountSheet: View {
    @Environment(AppStore.self) private var store
    let mode: AddAccountMode
    var dismiss: () -> Void
    @State private var name = ""
    @State private var secret = ""
    @State private var code = ""
    @State private var path = "~/.claude/.credentials.json"
    @State private var lines: [OutputLine] = []
    @State private var running = false
    @State private var finished: CLIResult?
    @State private var reloaded: Bool?
    @State private var task: Task<Void, Never>?
    @State private var errorText: String?
    /// Paste-code login: the CLI prints its URL first and only then reads the code, so stdin stays open until it is sent.
    @State private var stdinWriter: StdinWriter?
    @State private var codeSent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.title).font(.headline)
            Text(mode.help).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Text("Name").frame(width: 70, alignment: .trailing); TextField("optional — defaults to the account e-mail", text: $name).textFieldStyle(.roundedBorder) }
            if mode == .apiKey { HStack { Text("API key").frame(width: 70, alignment: .trailing); SecureField("sk-ant-api03-…", text: $secret).textFieldStyle(.roundedBorder) } }
            if mode == .importFile { HStack { Text("File").frame(width: 70, alignment: .trailing); TextField("~/.claude/.credentials.json", text: $path).textFieldStyle(.roundedBorder) } }
            if mode == .token, running, !codeSent {
                HStack {
                    Text("Code").frame(width: 70, alignment: .trailing)
                    TextField("authorization code or callback URL", text: $code).textFieldStyle(.roundedBorder).onSubmit(sendCode)
                    Button("Send", action: sendCode).controlSize(.small).disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !lines.isEmpty || running {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(line.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(isErr(line) ? .orange : .primary).textSelection(.enabled)
                                    if let url = urlIn(line.text) { Button("Open") { NSWorkspace.shared.open(url) }.controlSize(.mini) }
                                }.id(i)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .frame(height: 180).background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: lines.count) { _, n in proxy.scrollTo(max(0, n - 1)) }
                }
            }
            if let errorText { Text(errorText).foregroundStyle(.red).font(.system(size: 12)) }
            if let finished {
                Text(finishedText(finished)).foregroundStyle(finished.succeeded && reloaded != false ? Level.green.color : Level.red.color).font(.system(size: 12))
            }
            HStack {
                if running { ProgressView().controlSize(.small); Text("Running…").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                if running { Button("Cancel") { task?.cancel() } }
                else if finished != nil { Button("Close", action: dismiss).keyboardShortcut(.defaultAction) }
                else { Button("Cancel", action: dismiss); Button("Start") { start() }.keyboardShortcut(.defaultAction).disabled(mode == .apiKey && secret.isEmpty) }
            }
        }
        .padding(20).frame(width: 520)
    }

    private func isErr(_ l: OutputLine) -> Bool { if case .err = l { return true } else { return false } }

    private func finishedText(_ r: CLIResult) -> String {
        guard r.succeeded else { return "The CLI exited with \(r.exitCode)\(r.timedOut ? " (timed out)" : "")." }
        switch reloaded {
        case .some(true): return "Done — the proxy has been reloaded."
        case .some(false): return "Saved, but the proxy did not reload — restart it or use Reload Config."
        case .none: return "Done."
        }
    }

    private func sendCode() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let stdinWriter else { return }
        stdinWriter.send(trimmed)
        stdinWriter.close()
        codeSent = true
    }

    private func urlIn(_ text: String) -> URL? {
        guard let range = text.range(of: "https://") else { return nil }
        let tail = text[range.lowerBound...].split(separator: " ").first.map(String.init) ?? ""
        return URL(string: tail)
    }

    private func start() {
        var args: [String]
        var stdin: String? = nil
        var writer: StdinWriter? = nil
        var timeout: TimeInterval = 150
        switch mode {
        case .oauth: args = ["login", "--oauth"]
        case .token: args = ["login", "--token"]; writer = StdinWriter(); timeout = 300
        case .apiKey: args = ["login", "--api"]; stdin = secret; timeout = 30
        case .codex: args = ["login", "--codex", "--no-browser"]
        case .importCLI: args = ["import"]; timeout = 90
        case .importFile: args = ["import", "--from", (path as NSString).expandingTildeInPath]; timeout = 90
        }
        if !name.isEmpty { args += ["--name", name] }
        running = true; lines = []; finished = nil; reloaded = nil; errorText = nil; codeSent = false
        stdinWriter = writer
        let mode = self.mode
        task = Task {
            do {
                let r = try await store.runCLI(args, stdin: stdin, stdinWriter: writer, timeout: timeout) { line in
                    Task { @MainActor in lines.append(line) }
                }
                finished = r
                if r.succeeded {
                    // login --api and remove do not notify the server themselves.
                    reloaded = await store.reloadConfig()
                    store.loadConfigRoot()
                    if mode == .apiKey { secret = "" }
                }
            } catch let e as CLIError {
                errorText = e.message
            } catch is CancellationError {
                errorText = "Cancelled"
            } catch {
                errorText = error.localizedDescription
            }
            running = false
            stdinWriter = nil
        }
    }
}
