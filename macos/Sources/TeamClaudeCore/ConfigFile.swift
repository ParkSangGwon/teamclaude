import Foundation

public enum ConfigError: Error, Sendable, Equatable {
    case notFound(String)
    case notObject
    case changedUnderneath
    case write(String)
}

/// `~/.config/teamclaude.json`: the same file the CLI and the server write. It
/// holds every account's tokens and the proxy key, so a write is a same-directory
/// temp file (0600, fsynced) renamed over the target — the discipline of the
/// server's `writeJsonAtomic` — and a read-modify-write re-reads at commit time and
/// bails when the file changed underneath, which keeps the race with the server's
/// token refresh no wider than the CLI's own.
public struct ConfigFile: Sendable, Equatable {
    public let path: URL

    public init(path: URL) { self.path = path }

    /// `TEAMCLAUDE_CONFIG` → `$XDG_CONFIG_HOME/teamclaude.json` → `~/.config/teamclaude.json`.
    public static func resolvePath(env: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let p = env["TEAMCLAUDE_CONFIG"], !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty { return URL(fileURLWithPath: xdg).appending(path: "teamclaude.json") }
        return home.appending(path: ".config/teamclaude.json")
    }

    public var statePath: URL {
        let p = path.path
        return URL(fileURLWithPath: p.hasSuffix(".json") ? String(p.dropLast(5)) + ".state.json" : p + ".state")
    }

    public struct Loaded: Sendable {
        public var root: JSON
        public var modified: Date
    }

    public func load() throws -> Loaded {
        let data: Data
        do { data = try Data(contentsOf: path) } catch { throw ConfigError.notFound(path.path) }
        let json = try JSON.parse(data)
        guard json.object != nil else { throw ConfigError.notObject }
        return Loaded(root: json, modified: modificationDate())
    }

    func modificationDate() -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date) ?? .distantPast
    }

    /// Read → mutate → write, retried when another writer landed in between.
    @discardableResult
    public func update(attempts: Int = 3, _ mutate: (inout JSON) throws -> Void) throws -> JSON {
        var lastError: Error = ConfigError.changedUnderneath
        for _ in 0..<max(1, attempts) {
            let loaded = try load()
            var root = loaded.root
            try mutate(&root)
            if modificationDate() != loaded.modified { lastError = ConfigError.changedUnderneath; continue }
            try write(root)
            return root
        }
        throw lastError
    }

    /// Atomic replace: same-directory temp, 0600, fsync, rename over the resolved target.
    public func write(_ root: JSON) throws {
        let target = URL(fileURLWithPath: path.resolvingSymlinksInPath().path)
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: ".\(target.lastPathComponent).tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw ConfigError.write("cannot create \(tmp.lastPathComponent): \(String(cString: strerror(errno)))") }
        var ok = false
        defer { if !ok { unlink(tmp.path) } }
        let bytes = Array(root.pretty().utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBufferPointer { Foundation.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { close(fd); throw ConfigError.write("write failed: \(String(cString: strerror(errno)))") }
            written += n
        }
        fsync(fd)
        fchmod(fd, 0o600)
        close(fd)
        if rename(tmp.path, target.path) != 0 { throw ConfigError.write("rename failed: \(String(cString: strerror(errno)))") }
        ok = true
    }

    // MARK: - key paths

    /// Set (or delete with `nil`) exactly one key path, creating intermediate objects.
    public static func patch(_ root: inout JSON, path: [String], value: JSON?) {
        guard let head = path.first else { return }
        var obj = root.object ?? [:]
        if path.count == 1 {
            if let value { obj[head] = value } else { obj.removeValue(forKey: head) }
        } else {
            var child = obj[head] ?? .object([:])
            if child.object == nil { child = .object([:]) }
            patch(&child, path: Array(path.dropFirst()), value: value)
            obj[head] = child
        }
        root = .object(obj)
    }

    public static func value(_ root: JSON, path: [String]) -> JSON {
        var cur = root
        for key in path { cur = cur[key] }
        return cur
    }

    /// Index of the account row for `name` (matching `id` first when given).
    public static func accountIndex(_ root: JSON, name: String, id: String? = nil) -> Int? {
        let rows = root["accounts"].array ?? []
        if let id, let i = rows.firstIndex(where: { $0["id"].string == id }) { return i }
        return rows.firstIndex { $0["name"].string == name }
    }

    /// Patch one key on one account row; token fields are never touched.
    public static func patchAccount(_ root: inout JSON, name: String, id: String? = nil, key: String, value: JSON?) -> Bool {
        let forbidden: Set<String> = ["accessToken", "refreshToken", "apiKey", "expiresAt"]
        guard !forbidden.contains(key), let i = accountIndex(root, name: name, id: id), var rows = root["accounts"].array else { return false }
        var row = rows[i].object ?? [:]
        if let value { row[key] = value } else { row.removeValue(forKey: key) }
        rows[i] = .object(row)
        var obj = root.object ?? [:]
        obj["accounts"] = .array(rows)
        root = .object(obj)
        return true
    }

    // MARK: - what the app reads

    public struct ProxySettings: Sendable, Equatable {
        public var port: Int
        public var host: String
        public var apiKey: String?
        public var trustLoopback: Bool

        public init(port: Int, host: String, apiKey: String?, trustLoopback: Bool) {
            self.port = port; self.host = host; self.apiKey = apiKey; self.trustLoopback = trustLoopback
        }
    }

    public static func proxySettings(_ root: JSON) -> ProxySettings {
        let p = root["proxy"]
        return ProxySettings(port: p["port"].int ?? 3456, host: p["host"].string ?? "127.0.0.1",
                             apiKey: p["apiKey"].string, trustLoopback: p["trustLoopback"].bool ?? true)
    }

    /// Generates a key the way `createDefaultConfig` does: `tc-` + 24 random bytes, base64url.
    public static func newProxyKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let b64 = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "tc-" + b64
    }
}
