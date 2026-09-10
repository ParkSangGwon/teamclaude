import Foundation

public enum SettingsSection: String, Sendable, CaseIterable, Identifiable {
    case general, proxy, accounts, rotation, quota, routing, logging, advanced
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: return "General"
        case .proxy: return "Proxy & Service"
        case .accounts: return "Accounts"
        case .rotation: return "Rotation"
        case .quota: return "Quota"
        case .routing: return "Routing"
        case .logging: return "Logging"
        case .advanced: return "Advanced"
        }
    }
}

public enum FieldKind: Sendable, Equatable {
    case toggle
    case int(min: Int?, max: Int?, step: Int, unit: String?)
    case double(min: Double?, max: Double?, step: Double, unit: String?)
    case text(placeholder: String?)
    case secret
    case picker([String])
    case stringList
    /// bucket → number; a missing key means "default".
    case keyedNumbers(keys: [String])
    /// array of objects with these string fields.
    case objectList(fields: [String])
}

public enum Applies: Sendable, Equatable {
    case live
    case restart
    /// Live on proxies at or above this version, restart before it.
    case liveSince(String)

    public func resolved(serverVersion: String?) -> Applies {
        if case .liveSince(let v) = self {
            guard let serverVersion, Semver.compare(serverVersion, v) >= 0 else { return .restart }
            return .live
        }
        return self
    }
}

public struct SettingField: Sendable, Equatable, Identifiable {
    public let id: String
    public let path: [String]
    public let section: SettingsSection
    public let label: String
    public let help: String
    public let kind: FieldKind
    public let applies: Applies
    public let sensitive: Bool
    /// Applied through a CLI verb rather than a JSON edit (see `SettingsPlanner`).
    public let cli: Bool

    public init(_ path: String, _ section: SettingsSection, _ label: String, _ help: String, _ kind: FieldKind, _ applies: Applies, sensitive: Bool = false, cli: Bool = false) {
        self.id = path
        self.path = path.split(separator: ".").map(String.init)
        self.section = section
        self.label = label
        self.help = help
        self.kind = kind
        self.applies = applies
        self.sensitive = sensitive
        self.cli = cli
    }
}

public enum Semver {
    /// -1 / 0 / 1; non-numeric parts compare as 0. "unknown" (a git checkout) sorts newest.
    public static func compare(_ a: String, _ b: String) -> Int {
        if a == "unknown" { return 1 }
        if b == "unknown" { return -1 }
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}

/// Every config field from docs/configuration.md, as data. The Rotation, Quota,
/// Logging and Advanced panes render straight from this table.
public enum SettingsSchema {
    /// First proxy release whose reload hot-applies `eventLogging` and `blockedModels`.
    public static let reloadFixVersion = "1.1.19"

    public static let fields: [SettingField] = [
        // Rotation
        SettingField("switchThreshold", .rotation, "Switch threshold", "Utilization at which rotation leaves an account. Reported OAuth utilization arrives in whole percents; tenths only matter for API-key accounts.", .double(min: 1, max: 100, step: 1, unit: "%"), .live, cli: true),
        SettingField("switchThresholds", .rotation, "Per-bucket thresholds", "Override the threshold for one bucket; a missing bucket uses `default` (the scalar above).", .keyedNumbers(keys: ["default"] + Buckets.all), .live, cli: true),
        SettingField("distributeSessions", .rotation, "Session distribution", "Off: quota-driven rotation only. On: pin each new session to an equal-priority account for cache reuse. Adaptive: concentrate on the least remaining weekly credit.", .picker(["off", "on", "adaptive"]), .live, cli: true),
        SettingField("expiryRouting.enabled", .rotation, "Expiry-pressure routing", "Prefer accounts whose governing weekly quota is ample and resets soonest. The key name is provisional (#176).", .toggle, .live),
        SettingField("expiryRouting.tolerance", .rotation, "Expiry tolerance", "How much more remaining quota an account needs before it is preferred.", .double(min: 1, max: nil, step: 0.1, unit: nil), .live),
        SettingField("expiryRouting.preempt", .rotation, "Expiry preempts current", "Move off a healthy current account when a better-expiring one exists.", .toggle, .live),
        SettingField("holdSeconds", .rotation, "Hold on exhaustion", "Hold the request open until quota resets instead of answering 429 when every account is spent. 0 returns 429 immediately.", .int(min: 0, max: 86400, step: 30, unit: "s"), .restart),
        SettingField("stormRamp.enabled", .rotation, "Storm control", "Pace requests onto a freshly switched account so a herd failing over together does not throttle it.", .toggle, .restart),
        SettingField("stormRamp.startConc", .rotation, "Storm start concurrency", "Requests admitted at once right after a switch.", .int(min: 1, max: nil, step: 1, unit: nil), .restart),
        SettingField("stormRamp.stepConc", .rotation, "Storm step", "Concurrency added per step.", .int(min: 1, max: nil, step: 1, unit: nil), .restart),
        SettingField("stormRamp.stepMs", .rotation, "Storm step interval", "Milliseconds between steps.", .int(min: 1, max: nil, step: 100, unit: "ms"), .restart),
        SettingField("stormRamp.windowMs", .rotation, "Storm window", "How long the ramp lasts.", .int(min: 1, max: nil, step: 1000, unit: "ms"), .restart),
        SettingField("adaptiveDistribution.maxSampleAgeMs", .rotation, "Adaptive: max sample age", "A burn sample older than this spans an idle gap and is discarded.", .int(min: 1, max: nil, step: 60000, unit: "ms"), .restart),
        SettingField("adaptiveDistribution.lookaheadMs", .rotation, "Adaptive: lookahead", "How far ahead the reserve projects the burn rate.", .int(min: 1, max: nil, step: 60000, unit: "ms"), .restart),
        SettingField("adaptiveDistribution.burnWindowMs", .rotation, "Adaptive: burn window", "Interval one burn-rate sample is measured over.", .int(min: 1, max: nil, step: 60000, unit: "ms"), .restart),
        SettingField("adaptiveDistribution.burnAlpha", .rotation, "Adaptive: burn alpha", "EWMA weight of a new burn sample, in (0, 1].", .double(min: 0.01, max: 1, step: 0.05, unit: nil), .restart),
        SettingField("adaptiveDistribution.minReserve", .rotation, "Adaptive: min reserve", "Lower bound of the reserve the taper works across (0–1).", .double(min: 0, max: 1, step: 0.01, unit: nil), .restart),
        SettingField("adaptiveDistribution.maxReserve", .rotation, "Adaptive: max reserve", "Upper bound of the reserve (0–1, at least min reserve).", .double(min: 0, max: 1, step: 0.01, unit: nil), .restart),
        SettingField("adaptiveDistribution.initialBurnRate", .rotation, "Adaptive: initial burn rate", "Utilization per millisecond assumed until something is observed.", .double(min: 0, max: nil, step: 0.000000001, unit: nil), .restart),
        SettingField("adaptiveDistribution.initialConcCap", .rotation, "Adaptive: initial concurrency cap", "Where the tolerated-concurrency estimate starts.", .int(min: 1, max: nil, step: 1, unit: nil), .restart),
        SettingField("adaptiveDistribution.minConcCap", .rotation, "Adaptive: min concurrency cap", "Lowest the estimate may learn down to.", .int(min: 1, max: nil, step: 1, unit: nil), .restart),
        SettingField("adaptiveDistribution.maxConcCap", .rotation, "Adaptive: max concurrency cap", "Highest the estimate may learn up to.", .int(min: 1, max: nil, step: 1, unit: nil), .restart),
        SettingField("adaptiveDistribution.concBackoff", .rotation, "Adaptive: concurrency backoff", "EWMA weight applied on a throttle, in (0, 1].", .double(min: 0.01, max: 1, step: 0.05, unit: nil), .restart),
        SettingField("adaptiveDistribution.concBackoffTo", .rotation, "Adaptive: backoff target", "Fraction of the throttling load retreated to, in (0, 1].", .double(min: 0.01, max: 1, step: 0.05, unit: nil), .restart),
        SettingField("adaptiveDistribution.concGrowth", .rotation, "Adaptive: concurrency growth", "EWMA weight of the +1 probe while running at the cap, in (0, 1].", .double(min: 0.01, max: 1, step: 0.01, unit: nil), .restart),
        SettingField("adaptiveDistribution.maxBurnBoost", .rotation, "Adaptive: max burn boost", "Ceiling on the burn-down preference (≥ 1).", .double(min: 1, max: nil, step: 0.5, unit: nil), .restart),

        // Quota
        SettingField("quotaProbeSeconds", .quota, "Quota probe", "Background refresh of idle accounts from the usage endpoint (spends no quota). 0 turns it off; minimum 30 s.", .int(min: 0, max: 604800, step: 30, unit: "s"), .live, cli: true),
        SettingField("warmupSeconds", .quota, "Keep-warm interval", "Send a minimal request to each idle account so its 5-hour timer keeps running. Spends a little quota and needs `claude` on the service PATH. 0 turns it off; minimum 60 s.", .int(min: 0, max: 604800, step: 60, unit: "s"), .live, cli: true),

        // Routing
        SettingField("blockedModels", .routing, "Blocked models", "Model globs answered with a fast 400 instead of being forwarded, so a model no account can serve never hangs the pipeline.", .stringList, .liveSince(reloadFixVersion)),

        // Logging
        SettingField("eventLogging", .logging, "Claude Code telemetry", "hide forwards it but keeps it out of the activity log; block answers 200 locally; show forwards and displays it.", .picker(["hide", "block", "show"]), .liveSince(reloadFixVersion)),
        SettingField("sessionTitles.enabled", .logging, "Session titles", "Name each activity row after the Claude Code session that sent it (reads session transcripts under ~/.claude/projects).", .toggle, .live),
        SettingField("sessionTitles.width", .logging, "Session title width", "Columns the label gets in the activity log.", .int(min: 6, max: 60, step: 1, unit: nil), .live),
        SettingField("sessionTitles.projectsDir", .logging, "Projects directory", "Overrides ~/.claude/projects.", .text(placeholder: "~/.claude/projects"), .live),
        SettingField("logDir", .logging, "Request log directory", "One file per logged request. Unset writes nothing. Grows fast: a week of a few sessions measured 13 GB.", .text(placeholder: "unset"), .restart),
        SettingField("logLevel", .logging, "Request log level", "body writes headers and both bodies; headers writes only the heads; off records nothing while leaving the directory set.", .picker(["body", "headers", "off"]), .restart),
        SettingField("logMaxBodyBytes", .logging, "Max logged body", "Largest body kept per direction; 0 records every body in full.", .int(min: 0, max: nil, step: 65536, unit: "bytes"), .restart),
        SettingField("logRetentionHours", .logging, "Log retention", "Age at which log files are deleted; 0 keeps everything.", .int(min: 0, max: nil, step: 24, unit: "h"), .restart),
        SettingField("proxy.clientKeys", .logging, "Client keys", "Per-client keys; each authenticates like the proxy key and its usage is booked under its name.", .objectList(fields: ["name", "key"]), .live, sensitive: true),
        SettingField("proxy.usageDimensions", .logging, "Usage dimensions", "Request headers whose values group token usage (project, branch…). Consumed by the proxy, not forwarded.", .objectList(fields: ["name", "header"]), .live),
        SettingField("proxy.sessionDetail", .logging, "Per-session detail", "Adds a per-session breakdown to status and the dashboard. Any proxy-key holder can then see what every consumer is working on.", .toggle, .live),

        // Proxy / network (rendered by the Proxy pane, applied through the same table)
        SettingField("proxy.port", .proxy, "Port", "Local port the proxy listens on. The app reconnects after the restart.", .int(min: 1024, max: 65535, step: 1, unit: nil), .restart),
        SettingField("proxy.host", .proxy, "Bind address", "127.0.0.1 keeps the proxy local; 0.0.0.0 accepts off-box clients, which must then present the proxy key.", .text(placeholder: "127.0.0.1"), .restart),
        SettingField("proxy.apiKey", .proxy, "Proxy API key", "Remote clients present it as x-api-key. Regenerating it logs the dashboard out.", .secret, .live, sensitive: true),
        SettingField("proxy.trustLoopback", .proxy, "Trust loopback", "Let connections from 127.0.0.1 skip the key. Turn off behind a reverse proxy on the same host.", .toggle, .restart),
        SettingField("proxy.maxBodyBytes", .proxy, "Max request body", "Largest client request body accepted; 0 = unbounded.", .int(min: 0, max: nil, step: 1048576, unit: "bytes"), .restart),
        SettingField("upstream", .proxy, "Upstream", "API base URL for Anthropic accounts.", .text(placeholder: "https://api.anthropic.com"), .restart),
        SettingField("upstreamProxy", .proxy, "Outbound proxy", "http://user:pass@host:3128 or host:3128 for everything TeamClaude sends upstream. Leave empty to use HTTPS_PROXY from the environment.", .text(placeholder: "direct"), .live),
        SettingField("noProxy", .proxy, "Bypass hosts", "Comma-separated hosts that skip the outbound proxy (suffix match, * = all).", .text(placeholder: ""), .live),
        SettingField("mitm.http1Only", .proxy, "MITM: HTTP/1.1 only", "Needed for Remote Control from the Claude Code Desktop app (a WebSocket over HTTP/2 is not relayed).", .toggle, .restart),
        SettingField("sx.apiKey", .proxy, "sx.org API key", "When set, TeamClaude auto-provisions a residential proxy for egress-IP 429s.", .secret, .live, sensitive: true),
        SettingField("sx.mode", .proxy, "sx.org mode", "always routes all upstream traffic; 429 fails over after a 429; off keeps the key unused.", .picker(["always", "429", "off"]), .live),
        SettingField("egress.pin", .proxy, "Egress pin", "auto, or the IP the outbound traffic must leave from.", .text(placeholder: "auto"), .restart),
        SettingField("egress.checkUrl", .proxy, "Egress check URL", "Where the egress IP is looked up.", .text(placeholder: "https://api.ipify.org"), .restart),
        SettingField("egress.ttlSeconds", .proxy, "Egress check TTL", "Seconds an egress lookup stays valid.", .int(min: 1, max: nil, step: 10, unit: "s"), .restart),
        SettingField("egress.holdSeconds", .proxy, "Egress hold", "Seconds to hold traffic while the egress IP is wrong.", .int(min: 0, max: nil, step: 10, unit: "s"), .restart),
        SettingField("autoUpdate", .advanced, "Self-update", "Check npm once a day and install a newer teamclaude in the background.", .toggle, .restart),
    ]

    public static func field(_ id: String) -> SettingField? { fields.first { $0.id == id } }
    public static func fields(in section: SettingsSection) -> [SettingField] { fields.filter { $0.section == section } }

    /// Per-account row keys the Accounts pane edits (name/priority/disabled go through the CLI).
    public static let accountFields: [SettingField] = [
        SettingField("maxUsage", .accounts, "Usage cap", "Hard per-account cap: a fraction (0–1) or a per-bucket table. At the cap the account receives no requests at all.", .keyedNumbers(keys: ["default"] + Buckets.all), .live),
        SettingField("upstream", .accounts, "Account upstream", "Alternative base URL for this account only (a third-party Anthropic-compatible backend).", .text(placeholder: "https://api.deepseek.com/anthropic"), .live),
        SettingField("modelMap", .accounts, "Model map", "Anthropic model name → this backend's model name.", .objectList(fields: ["from", "to"]), .live),
        SettingField("stripRequestFields", .accounts, "Strip request fields", "Top-level request-body fields dropped before forwarding to this account (or cache_control.<subfield>).", .stringList, .restart),
    ]

    /// Fields whose values must never be logged or shown unmasked.
    public static let sensitiveKeys: Set<String> = ["accessToken", "refreshToken", "apiKey", "key"]
}
