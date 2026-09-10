import Foundation

/// "Is there a newer teamclaude on npm?" The install itself is the CLI's job
/// (`teamclaude update` knows whether it is an npm or a git install); the app only
/// asks the registry and compares against the CLI's reported version.
public enum UpdateCheck {
    public static let packageName = "@karpeleslab/teamclaude"
    public static let registryURL = URL(string: "https://registry.npmjs.org/\(packageName)/latest")!

    public static func parseLatest(_ data: Data) -> String? {
        guard let json = try? JSON.parse(data), let v = json["version"].string, !v.isEmpty else { return nil }
        return v
    }

    /// True when `latest` is a release version strictly newer than `installed`.
    /// A git checkout ("unknown") never counts as outdated.
    public static func isNewer(latest: String?, installed: String?) -> Bool {
        guard let latest, let installed, installed != "unknown", !installed.isEmpty else { return false }
        guard latest.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        return Semver.compare(latest, installed) > 0
    }

    public static func fetchLatest(timeout: TimeInterval = 10) async throws -> String? {
        var req = URLRequest(url: registryURL)
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return parseLatest(data)
    }

    /// The version `teamclaude update` reports it installed, from its stdout.
    public static func installedVersion(fromUpdateOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            if let r = line.range(of: "Updated to ") {
                let tail = line[r.upperBound...].prefix { $0.isNumber || $0 == "." }
                let version = String(tail).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if !version.isEmpty { return version }
            }
        }
        return nil
    }
}
