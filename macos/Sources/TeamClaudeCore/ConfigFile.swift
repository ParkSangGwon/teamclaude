import Foundation

public enum ConfigError: Error, Sendable, Equatable {
    case notFound(String)
    case notObject
    case changedUnderneath
    case write(String)

    public var message: String {
        switch self {
        case .notFound(let path): return L("Config file not found: %@", path)
        case .notObject: return L("The config must be a JSON object")
        case .changedUnderneath: return L("The config changed underneath the edit — try again")
        case .write(let detail): return L("Could not write the config: %@", detail)
        }
    }
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

    /// Identity of the bytes a read saw: the server's atomic rename changes the
    /// inode as well as the mtime, so a swap between two stats cannot hide.
    public struct Version: Sendable, Equatable {
        public var modified: Date
        public var size: UInt64
        public var inode: UInt64
    }

    public struct Loaded: Sendable {
        public var root: JSON
        public var version: Version
    }

    public func load() throws -> Loaded {
        // stat, read, stat: a rename between the two stats means the bytes belong to neither and the read is retried.
        var before = version()
        var data: Data
        for _ in 0..<3 {
            do { data = try Data(contentsOf: path) } catch { throw ConfigError.notFound(path.path) }
            let after = version()
            if after == before {
                let json = try JSON.parse(data)
                guard json.object != nil else { throw ConfigError.notObject }
                return Loaded(root: json, version: after)
            }
            before = after
        }
        throw ConfigError.changedUnderneath
    }

    func version() -> Version {
        var st = stat()
        guard stat(path.path, &st) == 0 else { return Version(modified: .distantPast, size: 0, inode: 0) }
        let modified = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        return Version(modified: modified, size: UInt64(st.st_size), inode: UInt64(st.st_ino))
    }

    /// Read → mutate → write under the shared lock, retried when another writer landed in between.
    @discardableResult
    public func update(attempts: Int = 3, _ mutate: (inout JSON) throws -> Void) throws -> JSON {
        try withLock {
            var lastError: Error = ConfigError.changedUnderneath
            for _ in 0..<max(1, attempts) {
                let loaded: Loaded
                do { loaded = try load() } catch ConfigError.changedUnderneath { lastError = ConfigError.changedUnderneath; continue }
                var root = loaded.root
                try mutate(&root)
                if version() != loaded.version { lastError = ConfigError.changedUnderneath; continue }
                try write(root)
                return root
            }
            throw lastError
        }
    }

    // MARK: - advisory lock (shared with the proxy and the CLI)

    /// `<config>.lock` beside the configured path (the proxy's `withConfigLock` puts it next to the
    /// link, not the target): created `O_EXCL` with `{"pid","at"}`, stale after 10 s or once its
    /// holder is gone, waited for at most 2 s and then ignored — advisory, never a deadlock.
    public var lockPath: URL { URL(fileURLWithPath: path.path + ".lock") }
    public static let lockStaleAfter: TimeInterval = 10
    public static let lockWait: TimeInterval = 2

    public func withLock<T>(_ body: () throws -> T) throws -> T {
        let held = acquireLock()
        defer { if held { unlink(lockPath.path) } }
        return try body()
    }

    /// True when the lock was taken; false when it stayed busy past the wait (the write proceeds anyway).
    func acquireLock(wait: TimeInterval = ConfigFile.lockWait) -> Bool {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            let fd = open(lockPath.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                let body = "{\"pid\":\(getpid()),\"at\":\(Int(Date().timeIntervalSince1970 * 1000))}"
                _ = body.withCString { Foundation.write(fd, $0, strlen($0)) }
                close(fd)
                return true
            }
            if errno != EEXIST { return false }
            if lockIsStale() { unlink(lockPath.path); continue }
            if Date() >= deadline { return false }
            usleep(25_000)
        }
    }

    /// Older than the staleness window, or held by a pid that no longer exists.
    func lockIsStale(now: Date = Date()) -> Bool {
        var st = stat()
        guard stat(lockPath.path, &st) == 0 else { return true }
        let modified = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        if now.timeIntervalSince(modified) > ConfigFile.lockStaleAfter { return true }
        guard let data = try? Data(contentsOf: lockPath), let json = try? JSON.parse(data), let pid = json["pid"].int, pid > 0 else { return false }
        return kill(pid_t(pid), 0) != 0 && errno == ESRCH
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
        path.reduce(root) { $0[$1] }
    }

    public enum AccountMatch: Sendable, Equatable {
        case index(Int)
        case notFound
        /// The same name in more than one organization: the caller has to say which (`--org`).
        case ambiguous
    }

    /// The account row for `name`: `id` wins when given, then the name, narrowed by
    /// `org` (uuid or display name) the way the CLI's `--org` does.
    public static func matchAccount(_ root: JSON, name: String, id: String? = nil, org: String? = nil) -> AccountMatch {
        let rows = root["accounts"].array ?? []
        if let id, let i = rows.firstIndex(where: { $0["id"].string == id }) { return .index(i) }
        let hits = rows.indices.filter {
            rows[$0]["name"].string == name && (org == nil || rows[$0]["orgUuid"].string == org || rows[$0]["orgName"].string == org)
        }
        switch hits.count {
        case 0: return .notFound
        case 1: return .index(hits[0])
        default: return .ambiguous
        }
    }

    /// Index of the account row for `name` (matching `id` first when given); nil when missing or ambiguous.
    public static func accountIndex(_ root: JSON, name: String, id: String? = nil, org: String? = nil) -> Int? {
        if case .index(let i) = matchAccount(root, name: name, id: id, org: org) { return i }
        return nil
    }

    /// Patch one key on one account row; token fields are never touched.
    public static func patchAccount(_ root: inout JSON, name: String, id: String? = nil, org: String? = nil, key: String, value: JSON?) -> Bool {
        let forbidden: Set<String> = ["accessToken", "refreshToken", "apiKey", "expiresAt"]
        guard !forbidden.contains(key), let i = accountIndex(root, name: name, id: id, org: org), var rows = root["accounts"].array else { return false }
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
