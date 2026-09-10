import Foundation
import XCTest
import TeamClaudeCore

final class ConfigFileTests: XCTestCase {
    private var dir: URL!
    private var path: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "teamclaude-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appending(path: "teamclaude.json")
        try Fixtures.data("config-full.json").write(to: path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func attributes(_ url: URL) throws -> [FileAttributeKey: Any] { try FileManager.default.attributesOfItem(atPath: url.path) }
    private func read(_ url: URL) throws -> JSON { try JSON.parse(try Data(contentsOf: url)) }
    private func entries() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    // MARK: path resolution

    func testResolvePathPrecedence() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(ConfigFile.resolvePath(env: ["TEAMCLAUDE_CONFIG": "/x/y.json", "XDG_CONFIG_HOME": "/xdg"], home: home).path, "/x/y.json")
        XCTAssertEqual(ConfigFile.resolvePath(env: ["XDG_CONFIG_HOME": "/xdg"], home: home).path, "/xdg/teamclaude.json")
        XCTAssertEqual(ConfigFile.resolvePath(env: [:], home: home).path, "/Users/someone/.config/teamclaude.json")
        XCTAssertEqual(ConfigFile.resolvePath(env: ["TEAMCLAUDE_CONFIG": "", "XDG_CONFIG_HOME": ""], home: home).path, "/Users/someone/.config/teamclaude.json", "empty values do not count")
        let tilde = ConfigFile.resolvePath(env: ["TEAMCLAUDE_CONFIG": "~/cfg.json"], home: home).path
        XCTAssertEqual(tilde, ("~/cfg.json" as NSString).expandingTildeInPath)
        XCTAssertFalse(tilde.hasPrefix("~"))
    }

    func testStatePath() {
        XCTAssertEqual(ConfigFile(path: URL(fileURLWithPath: "/x/teamclaude.json")).statePath.path, "/x/teamclaude.state.json")
        XCTAssertEqual(ConfigFile(path: URL(fileURLWithPath: "/x/conf")).statePath.path, "/x/conf.state")
    }

    // MARK: load

    func testLoadFullConfig() throws {
        let loaded = try ConfigFile(path: path).load()
        XCTAssertEqual(loaded.root["proxy"]["port"].int, 3456)
        XCTAssertEqual(loaded.root["proxy"]["apiKey"].string, "tc-change-me-to-a-secret")
        XCTAssertEqual(loaded.root["x-future"]["a"].int, 1)
        XCTAssertEqual(loaded.root["switchThreshold"]["unified7dFable"].double, 0.9)
        XCTAssertEqual(loaded.root["accounts"].array?.count, 4)
        XCTAssertEqual(loaded.root["accounts"][1]["id"].string, "acct-2")
        XCTAssertEqual(loaded.version.modified.timeIntervalSince1970, (try attributes(path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1, accuracy: 0.001)
        XCTAssertEqual(loaded.version.size, UInt64(try Data(contentsOf: path).count))
        XCTAssertNotEqual(loaded.version.inode, 0)
    }

    func testLoadErrors() throws {
        let missing = ConfigFile(path: dir.appending(path: "nope.json"))
        XCTAssertThrowsError(try missing.load()) { XCTAssertEqual($0 as? ConfigError, .notFound(missing.path.path)) }
        try Data("[1, 2]".utf8).write(to: path)
        XCTAssertThrowsError(try ConfigFile(path: path).load()) { XCTAssertEqual($0 as? ConfigError, .notObject) }
        try Data("{not json".utf8).write(to: path)
        XCTAssertThrowsError(try ConfigFile(path: path).load()) { XCTAssertNil($0 as? ConfigError, "a parse error is surfaced as-is") }
    }

    // MARK: patch helpers

    func testPatch() {
        var root: JSON = .object([:])
        ConfigFile.patch(&root, path: ["a", "b"], value: .number(1))
        XCTAssertEqual(root, .object(["a": .object(["b": .number(1)])]))
        ConfigFile.patch(&root, path: ["a", "c"], value: .string("x"))
        XCTAssertEqual(ConfigFile.value(root, path: ["a", "c"]), .string("x"))
        ConfigFile.patch(&root, path: ["a", "b"], value: nil)
        XCTAssertEqual(root, .object(["a": .object(["c": .string("x")])]))
        ConfigFile.patch(&root, path: ["a"], value: nil)
        XCTAssertEqual(root, .object([:]))
        ConfigFile.patch(&root, path: ["missing"], value: nil)
        XCTAssertEqual(root, .object([:]), "deleting what is not there is a no-op")
        ConfigFile.patch(&root, path: [], value: .number(1))
        XCTAssertEqual(root, .object([:]), "an empty path is a no-op")

        var scalar: JSON = .object(["a": .number(5)])
        ConfigFile.patch(&scalar, path: ["a", "b", "c"], value: .bool(true))
        XCTAssertEqual(scalar, .object(["a": .object(["b": .object(["c": .bool(true)])])]), "a scalar in the way is replaced by an object")

        var notObject: JSON = .array([.number(1)])
        ConfigFile.patch(&notObject, path: ["k"], value: .null)
        XCTAssertEqual(notObject, .object(["k": .null]))
        XCTAssertTrue(ConfigFile.value(notObject, path: ["k", "deeper"]).isNull)
    }

    func testPatchAccountByIdThenByName() throws {
        var root = try ConfigFile(path: path).load().root
        XCTAssertEqual(ConfigFile.accountIndex(root, name: "codex@example.com"), 2)
        XCTAssertEqual(ConfigFile.accountIndex(root, name: "renamed", id: "acct-2"), 1, "the id wins over a stale name")
        XCTAssertEqual(ConfigFile.accountIndex(root, name: "codex@example.com", id: "no-such-id"), 2, "an unknown id falls back to the name")
        XCTAssertNil(ConfigFile.accountIndex(root, name: "nobody"))

        XCTAssertTrue(ConfigFile.patchAccount(&root, name: "renamed", id: "acct-2", key: "priority", value: .number(5)))
        XCTAssertEqual(root["accounts"][1]["priority"].int, 5)
        XCTAssertEqual(root["accounts"][1]["name"].string, "user@example.com (Acme)", "the row keeps its name")
        XCTAssertTrue(ConfigFile.patchAccount(&root, name: "api-fallback", key: "disabled", value: .bool(true)))
        XCTAssertEqual(root["accounts"][3]["disabled"].bool, true)
        XCTAssertTrue(ConfigFile.patchAccount(&root, name: "api-fallback", key: "disabled", value: nil))
        XCTAssertTrue(root["accounts"][3]["disabled"].isNull)
        XCTAssertEqual(root["accounts"][3]["apiKey"].string, "sk-ant-api03-your-api-key", "siblings untouched")
        XCTAssertFalse(ConfigFile.patchAccount(&root, name: "nobody", key: "priority", value: .number(1)))
    }

    func testPatchAccountRefusesTokenKeys() throws {
        let before = try ConfigFile(path: path).load().root
        for key in ["accessToken", "refreshToken", "apiKey", "expiresAt"] {
            var root = before
            XCTAssertFalse(ConfigFile.patchAccount(&root, name: "api-fallback", key: key, value: .string("x")), key)
            XCTAssertFalse(ConfigFile.patchAccount(&root, name: "api-fallback", key: key, value: nil), key)
            XCTAssertEqual(root, before, "\(key) leaves the document untouched")
        }
        XCTAssertEqual(try read(path), before, "and the file")
    }

    // MARK: update / write

    func testUpdateWritesAtomicallyWithNodeFormatting() throws {
        let file = ConfigFile(path: path)
        let inodeBefore = try XCTUnwrap(try attributes(path)[.systemFileNumber] as? Int)
        let result = try file.update { root in
            ConfigFile.patch(&root, path: ["quotaProbeSeconds"], value: .number(300))
            ConfigFile.patch(&root, path: ["expiryRouting", "enabled"], value: .bool(true))
        }
        XCTAssertEqual(result["quotaProbeSeconds"].int, 300)

        let attrs = try attributes(path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
        XCTAssertNotEqual(attrs[.systemFileNumber] as? Int, inodeBefore, "replaced by rename, not rewritten in place")
        XCTAssertEqual(try entries(), ["teamclaude.json"], "no temp file left behind")

        let text = String(decoding: try Data(contentsOf: path), as: UTF8.self)
        XCTAssertEqual(text, result.pretty())
        XCTAssertTrue(text.hasPrefix("{\n  \"accounts\": [\n    {\n      \"id\": \"acct-1\","), "2-space indent, sorted keys")
        XCTAssertTrue(text.contains("\n  \"quotaProbeSeconds\": 300,\n"))
        XCTAssertFalse(text.contains("\" :"), "no space before the colon")
        XCTAssertTrue(text.hasSuffix("}\n"))

        let after = try read(path)
        XCTAssertEqual(after["x-future"]["a"].int, 1)
        XCTAssertEqual(after["proxy"]["x-future-proxy"].stringArray, ["keep", "me"])
        XCTAssertEqual(after["accounts"].array?.map { $0["id"].string }, ["acct-1", "acct-2", "acct-3", "acct-4"])
        XCTAssertEqual(after["accounts"][1]["accessToken"].string, "sk-ant-oat01-your-access-token")
        XCTAssertEqual(after["accounts"][0]["x-future-account"].bool, true)
        XCTAssertEqual(after["expiryRouting"]["enabled"].bool, true)
        XCTAssertEqual(after["expiryRouting"]["tolerance"].double, 1.5)
        XCTAssertEqual(after["switchThreshold"]["unified5h"].double, 0.98)
    }

    func testWriteThroughASymlinkKeepsTheLink() throws {
        let real = dir.appending(path: "real.json")
        try FileManager.default.moveItem(at: path, to: real)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: real)
        try ConfigFile(path: path).update { ConfigFile.patch(&$0, path: ["holdSeconds"], value: .number(60)) }
        XCTAssertEqual(try attributes(path)[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path.path), real.path)
        XCTAssertEqual(try read(real)["holdSeconds"].int, 60)
        XCTAssertEqual(try attributes(real)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try entries(), ["real.json", "teamclaude.json"])
    }

    func testWriteCreatesTheDirectory() throws {
        let nested = dir.appending(path: "a/b/teamclaude.json")
        try ConfigFile(path: nested).write(.object(["proxy": .object(["port": .number(4000)])]))
        XCTAssertEqual(try read(nested)["proxy"]["port"].int, 4000)
        XCTAssertEqual(try attributes(nested)[.posixPermissions] as? Int, 0o600)
    }

    func testWriteFailureLeavesTheFileAndNoTempBehind() throws {
        let original = try Data(contentsOf: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        XCTAssertThrowsError(try ConfigFile(path: path).update { ConfigFile.patch(&$0, path: ["holdSeconds"], value: .number(1)) }) { error in
            guard case .some(.write) = error as? ConfigError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(try entries(), ["teamclaude.json"], "the temp file is unlinked on failure")

        // The target being a directory makes the rename fail after the temp file was written.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let asDir = dir.appending(path: "dir.json")
        try FileManager.default.createDirectory(at: asDir, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ConfigFile(path: asDir).write(.object([:]))) { error in
            guard case .some(.write) = error as? ConfigError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try entries(), ["dir.json", "teamclaude.json"])
    }

    func testUpdateThrowsWhenTheFileChangesUnderneath() throws {
        let file = ConfigFile(path: path)
        let original = try Data(contentsOf: path)
        var calls = 0
        XCTAssertThrowsError(try file.update(attempts: 3) { root in
            calls += 1
            let bumped = (try self.attributes(self.path)[.modificationDate] as! Date).addingTimeInterval(1)
            try FileManager.default.setAttributes([.modificationDate: bumped], ofItemAtPath: self.path.path)
            ConfigFile.patch(&root, path: ["holdSeconds"], value: .number(999))
        }) { error in
            XCTAssertEqual(error as? ConfigError, .changedUnderneath)
        }
        XCTAssertEqual(calls, 3, "each attempt re-reads and re-runs the closure")
        XCTAssertEqual(try Data(contentsOf: path), original, "nothing was written")
        XCTAssertEqual(try entries(), ["teamclaude.json"])
    }

    func testUpdateRetriesUntilQuiet() throws {
        let file = ConfigFile(path: path)
        var calls = 0
        try file.update(attempts: 3) { root in
            calls += 1
            if calls == 1 {
                let bumped = (try self.attributes(self.path)[.modificationDate] as! Date).addingTimeInterval(1)
                try FileManager.default.setAttributes([.modificationDate: bumped], ofItemAtPath: self.path.path)
            }
            ConfigFile.patch(&root, path: ["holdSeconds"], value: .number(7))
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try read(path)["holdSeconds"].int, 7)
    }

    func testUpdatePropagatesMutateErrors() throws {
        let original = try Data(contentsOf: path)
        XCTAssertThrowsError(try ConfigFile(path: path).update { _ in throw SettingsError.noSuchAccount("x") }) {
            XCTAssertEqual($0 as? SettingsError, .noSuchAccount("x"))
        }
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    // MARK: what the app reads

    func testProxySettings() throws {
        let defaults = ConfigFile.proxySettings(.object([:]))
        XCTAssertEqual(defaults.port, 3456)
        XCTAssertEqual(defaults.host, "127.0.0.1")
        XCTAssertNil(defaults.apiKey)
        XCTAssertTrue(defaults.trustLoopback)
        let full = ConfigFile.proxySettings(try ConfigFile(path: path).load().root)
        XCTAssertEqual(full.port, 3456)
        XCTAssertEqual(full.apiKey, "tc-change-me-to-a-secret")
        XCTAssertTrue(full.trustLoopback)
        let custom = ConfigFile.proxySettings(.object(["proxy": .object(["port": .number(4001), "host": .string("0.0.0.0"), "trustLoopback": .bool(false)])]))
        XCTAssertEqual(custom.port, 4001)
        XCTAssertEqual(custom.host, "0.0.0.0")
        XCTAssertNil(custom.apiKey)
        XCTAssertFalse(custom.trustLoopback)
        XCTAssertEqual(ConfigFile.proxySettings(.object(["proxy": .string("junk")])).port, 3456)
    }

    func testNewProxyKey() {
        let key = ConfigFile.newProxyKey()
        XCTAssertTrue(key.hasPrefix("tc-"))
        let body = key.dropFirst(3)
        XCTAssertEqual(body.count, 32, "24 bytes → 32 base64 characters, no padding")
        XCTAssertTrue(body.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }, key)
        XCTAssertFalse(body.contains("+") || body.contains("/") || body.contains("="))
        XCTAssertNotEqual(key, ConfigFile.newProxyKey())
    }
}
