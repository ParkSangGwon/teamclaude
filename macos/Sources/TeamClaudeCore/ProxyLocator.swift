import Foundation

/// How to run the teamclaude CLI: `node <entry> <args>` (entry is `src/index.js`
/// or the `bin/teamclaude` symlink — node ignores the shebang either way) or a
/// bare executable.
public struct CLILocation: Sendable, Equatable {
    public enum Source: String, Sendable { case launchAgent, loginShell, manual }
    public var node: URL?
    public var entry: URL
    public var environment: [String: String]
    public var source: Source

    public init(node: URL?, entry: URL, environment: [String: String], source: Source) {
        self.node = node; self.entry = entry; self.environment = environment; self.source = source
    }

    public var executable: URL { node ?? entry }
    public var leadingArguments: [String] { node == nil ? [] : [entry.path] }
    public var configPathOverride: String? { environment["TEAMCLAUDE_CONFIG"] }
    public var describe: String { node.map { "\($0.path) \(entry.path)" } ?? entry.path }
}

public enum ProxyLocator {
    public static let launchAgentLabel = "com.karpeleslab.teamclaude"

    public static func launchAgentPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    public static func logPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Logs/teamclaude.log")
    }

    /// The plist `teamclaude service install` wrote: `ProgramArguments = [node, entry, server, --headless]`.
    public static func fromLaunchAgent(plist url: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> CLILocation? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String], args.count >= 2 else { return nil }
        let env = (plist["EnvironmentVariables"] as? [String: String]) ?? [:]
        let node = URL(fileURLWithPath: args[0])
        let entry = URL(fileURLWithPath: args[1])
        guard fileExists(node.path), fileExists(entry.path) else { return nil }
        if node.lastPathComponent == "node" {
            return CLILocation(node: node, entry: entry, environment: env, source: .launchAgent)
        }
        return CLILocation(node: nil, entry: node, environment: env, source: .launchAgent)
    }

    /// Parse the output of `command -v node; command -v teamclaude; echo $PATH` from a login shell.
    public static func fromLoginShellOutput(_ output: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> CLILocation? {
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let cli = lines.first(where: { $0.hasSuffix("/teamclaude") }), fileExists(cli) else { return nil }
        let node = lines.first { $0.hasSuffix("/node") && fileExists($0) }
        let path = lines.last { $0.contains("/") && !$0.hasSuffix("/teamclaude") && !$0.hasSuffix("/node") } ?? ""
        var env: [String: String] = [:]
        if !path.isEmpty { env["PATH"] = path }
        return CLILocation(node: node.map { URL(fileURLWithPath: $0) }, entry: URL(fileURLWithPath: cli), environment: env, source: .loginShell)
    }

    public static func fromManualPath(_ path: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> CLILocation? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty, fileExists(expanded) else { return nil }
        return CLILocation(node: nil, entry: URL(fileURLWithPath: expanded), environment: [:], source: .manual)
    }

    /// Manual override → LaunchAgent plist → login shell. Runs the shell (5 s) only when needed.
    public static func resolve(manualOverride: String? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CLILocation? {
        if let manual = manualOverride, let loc = fromManualPath(manual) { return loc }
        if let loc = fromLaunchAgent(plist: launchAgentPath(home: home)) { return loc }
        if let out = try? runLoginShell(), let loc = fromLoginShellOutput(out) { return loc }
        return nil
    }

    static func runLoginShell(timeout: TimeInterval = 5) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v node; command -v teamclaude; echo \"$PATH\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        // A bounded read: an rc file that backgrounds a child keeps the pipe's write end open past the shell's exit.
        let data = CLIRunner.drain(pipe.fileHandleForReading, within: timeout)
        if p.isRunning { p.terminate() }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Service health

/// What `launchctl print gui/<uid>/<label>` says about the agent.
public struct ServiceHealth: Sendable, Equatable {
    public var installed: Bool
    public var loaded: Bool
    public var pid: Int?
    public var runs: Int?
    public var lastExitCode: Int?
    public var state: String?

    public init(installed: Bool, loaded: Bool, pid: Int? = nil, runs: Int? = nil, lastExitCode: Int? = nil, state: String? = nil) {
        self.installed = installed; self.loaded = loaded; self.pid = pid; self.runs = runs; self.lastExitCode = lastExitCode; self.state = state
    }

    /// Parse `launchctl print` output; `nil` output (non-zero exit) means not loaded.
    public static func parse(launchctlPrint output: String?, installed: Bool) -> ServiceHealth {
        guard let output else { return ServiceHealth(installed: installed, loaded: false) }
        func int(_ key: String) -> Int? {
            guard let range = output.range(of: "\(key) = ") else { return nil }
            let tail = output[range.upperBound...].prefix { $0.isNumber || $0 == "-" }
            return Int(tail)
        }
        let stateLine = output.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("state = ") }
        let state = stateLine.map { String($0.trimmingCharacters(in: .whitespaces).dropFirst("state = ".count)) }
        return ServiceHealth(installed: installed, loaded: true, pid: int("pid"), runs: int("runs"), lastExitCode: int("last exit code"), state: state)
    }

    /// Many runs with a non-zero last exit and no stable pid: launchd keeps relaunching a process that dies at once.
    public var crashLooping: Bool { loaded && (runs ?? 0) >= 5 && (lastExitCode ?? 0) != 0 && (pid == nil || state != "running") }
}

/// Who holds the proxy port, from `lsof -nP -iTCP:<port> -sTCP:LISTEN -Fpc`.
public struct PortOwner: Sendable, Equatable {
    public var pid: Int
    public var command: String

    public static func parse(lsofFields output: String) -> PortOwner? {
        var pid: Int?
        var cmd = ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = Int(line.dropFirst()) }
            else if line.hasPrefix("c"), cmd.isEmpty { cmd = String(line.dropFirst()) }
        }
        guard let pid else { return nil }
        return PortOwner(pid: pid, command: cmd)
    }
}

public enum ServiceDiagnosis: Sendable, Equatable {
    case healthy(pid: Int)
    case notInstalled
    case notLoaded
    /// The LaunchAgent cannot bind the port because another teamclaude process holds it.
    case portHeldElsewhere(ownerPid: Int, ownerCommand: String, runs: Int?)
    case crashLooping(runs: Int?, lastExitCode: Int?)
    case stopped

    public static func diagnose(health: ServiceHealth, portOwner: PortOwner?) -> ServiceDiagnosis {
        if !health.installed { return .notInstalled }
        if !health.loaded { return .notLoaded }
        if let owner = portOwner, let pid = health.pid, owner.pid == pid { return .healthy(pid: pid) }
        if let owner = portOwner, health.pid != owner.pid { return .portHeldElsewhere(ownerPid: owner.pid, ownerCommand: owner.command, runs: health.runs) }
        if health.crashLooping { return .crashLooping(runs: health.runs, lastExitCode: health.lastExitCode) }
        if let pid = health.pid { return .healthy(pid: pid) }
        return .stopped
    }

    public var text: String {
        switch self {
        case .healthy(let pid): return L("Service running (pid %d)", pid)
        case .notInstalled: return L("Service not installed — the proxy is not managed by launchd")
        case .notLoaded: return L("Service installed but not loaded")
        case .portHeldElsewhere(let pid, let cmd, let runs):
            return L("Port is served by another process (%@); the LaunchAgent cannot start", cmd.isEmpty ? "pid \(pid)" : "\(cmd), pid \(pid)") + (runs.map { " " + L("(%d attempts)", $0) } ?? "")
        case .crashLooping(let runs, let code): return L("Service is crash-looping") + (runs.map { " " + L("(%d runs", $0) } ?? "") + (code.map { ", " + L("last exit %d)", $0) } ?? ")")
        case .stopped: return L("Service loaded but not running")
        }
    }
}
