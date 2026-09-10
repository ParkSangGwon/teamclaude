import Foundation
import XCTest
import TeamClaudeCore

final class SettingsPlannerTests: XCTestCase {
    private func argv(_ c: SettingChange) -> [String]? { SettingsPlanner.cliArguments(c) }

    // MARK: CLI argv

    func testThresholdArgv() {
        XCTAssertEqual(argv(.threshold(percent: 90)), ["threshold", "90"])
        XCTAssertEqual(argv(.threshold(percent: 99.5)), ["threshold", "99.5"])
        XCTAssertEqual(argv(.threshold(percent: 87.5)), ["threshold", "87.5"])
        XCTAssertEqual(argv(.threshold(percent: 90.04)), ["threshold", "90.0"], "one decimal, the CLI's own precision")
        let table: [String: Double?] = ["unified7d": 90, "unified5h": nil]
        XCTAssertEqual(argv(.thresholdTable(table)), ["threshold", "unified5h=default", "unified7d=90"])
        XCTAssertEqual(argv(.thresholdTable(["unified7dFable": 87.5])), ["threshold", "unified7dFable=87.5"])
        XCTAssertEqual(argv(.thresholdTable(["default": 90, "unified7d": nil])), ["threshold", "default=90", "unified7d=default"], "the CLI takes `default=<n>` but refuses `default=default`")
        XCTAssertNil(argv(.thresholdTable([:])))
    }

    func testProbeAndWarmupArgv() {
        XCTAssertEqual(argv(.probe(seconds: 0)), ["probe", "off"])
        XCTAssertEqual(argv(.probe(seconds: -1)), ["probe", "off"])
        XCTAssertEqual(argv(.probe(seconds: 330)), ["probe", "330"])
        XCTAssertEqual(argv(.warmupInterval(seconds: -1)), ["warmup", "off"])
        XCTAssertEqual(argv(.warmupInterval(seconds: 600)), ["warmup", "600"])
        XCTAssertEqual(argv(.warmupInterval(seconds: 0)), ["warmup", "off"])
        let reset = argv(.warmupReset(time: "15:30", timezone: "Europe/Moscow"))
        XCTAssertEqual(reset, ["warmup", "reset", "15:30", "--timezone", "Europe/Moscow"])
        XCTAssertEqual(reset?.count, 5)
        XCTAssertEqual(argv(.warmupRolling(time: "09:00", timezone: "UTC")), ["warmup", "rolling", "09:00", "--timezone", "UTC"])
    }

    func testDistributePriorityEnableArgv() {
        XCTAssertEqual(argv(.distribute("adaptive")), ["distribute", "adaptive"])
        XCTAssertEqual(argv(.distribute("off")), ["distribute", "off"])
        XCTAssertEqual(argv(.priority(account: "alice", org: nil, value: .number(2))), ["priority", "alice", "2"])
        XCTAssertEqual(argv(.priority(account: "alice", org: nil, value: .first)), ["priority", "alice", "--first"])
        XCTAssertEqual(argv(.priority(account: "alice", org: "Acme", value: .last)), ["priority", "alice", "--last", "--org", "Acme"])
        XCTAssertEqual(argv(.priority(account: "alice", org: "Acme", value: .number(-3))), ["priority", "alice", "-3", "--org", "Acme"])
        XCTAssertEqual(argv(.enabled(account: "alice", org: nil, enabled: true)), ["enable", "alice"])
        XCTAssertEqual(argv(.enabled(account: "alice", org: "Acme", enabled: false)), ["disable", "alice", "--org", "Acme"])
    }

    func testRouteArgv() {
        XCTAssertEqual(argv(.routeAdd(name: "fable", match: ["*fable*", "*opus*"], accounts: ["a", "b"], bucket: "unified7dFable", color: "magenta")),
                       ["route", "add", "fable", "--match", "*fable*,*opus*", "--accounts", "a,b", "--bucket", "unified7dFable", "--color", "magenta"])
        XCTAssertEqual(argv(.routeAdd(name: "fable", match: ["*fable*"], accounts: [], bucket: nil, color: nil)), ["route", "add", "fable", "--match", "*fable*"])
        XCTAssertEqual(argv(.routeAdd(name: "fable", match: ["*fable*"], accounts: [], bucket: "", color: "")), ["route", "add", "fable", "--match", "*fable*"], "empty strings are omitted")
        XCTAssertNil(argv(.routeAdd(name: "a,b", match: ["*x*"], accounts: [], bucket: nil, color: nil)), "a comma would be split by the CLI")
        XCTAssertNil(argv(.routeAdd(name: "ok", match: ["*x*", "y,z"], accounts: [], bucket: nil, color: nil)))
        XCTAssertNil(argv(.routeAdd(name: "ok", match: ["*x*"], accounts: ["a,b"], bucket: nil, color: nil)))
        XCTAssertNil(argv(.routeAdd(name: "--flag", match: ["*x*"], accounts: [], bucket: nil, color: nil)))
        XCTAssertNil(argv(.routeAdd(name: "ok", match: [""], accounts: [], bucket: nil, color: nil)))
        XCTAssertEqual(argv(.routeRemove(name: "fable")), ["route", "rm", "fable"])
        XCTAssertNil(argv(.routeRemove(name: "--all")))
    }

    func testRemoveAndJsonOnlyArgv() {
        XCTAssertEqual(argv(.removeAccount(name: "alice", org: "Acme")), ["remove", "alice", "--org", "Acme"])
        XCTAssertEqual(argv(.removeAccount(name: "alice", org: nil)), ["remove", "alice"])
        XCTAssertNil(argv(.json(path: ["holdSeconds"], value: .number(0), applies: .restart)))
        XCTAssertNil(argv(.accountField(name: "alice", id: nil, key: "maxUsage", value: .number(0.5), applies: .live)))
    }

    // MARK: JSON path + mutate

    private func config() -> JSON { Fixtures.json("config-full.json") }

    private func mutated(_ change: SettingChange, from root: JSON? = nil) throws -> JSON {
        var doc = root ?? config()
        try SettingsPlanner.mutate(&doc, SettingsPlanner.jsonPath(change))
        return doc
    }

    func testThresholdJSON() throws {
        XCTAssertEqual(SettingsPlanner.jsonPath(.threshold(percent: 90)), .patch(path: ["switchThreshold"], value: .number(0.9), .live))
        XCTAssertEqual(try mutated(.threshold(percent: 90))["switchThreshold"], .number(0.9))
        let table: [String: Double?] = ["unified7d": 90, "unified5h": nil]
        XCTAssertEqual(try mutated(.thresholdTable(table))["switchThreshold"], .object(["unified7d": .number(0.9)]))
        XCTAssertEqual(try mutated(.thresholdTable(["unified5h": nil]))["switchThreshold"], .number(0.98), "all defaults → back to the scalar default")
    }

    func testProbeAndWarmupJSON() throws {
        XCTAssertEqual(try mutated(.probe(seconds: 330))["quotaProbeSeconds"], .number(330))
        XCTAssertEqual(try mutated(.probe(seconds: -5))["quotaProbeSeconds"], .number(0))
        XCTAssertEqual(try mutated(.warmupInterval(seconds: 0))["warmupSeconds"], .number(0))

        XCTAssertNotNil(config()["warmupSchedule"].object, "the fixture starts with a schedule")
        let interval = try mutated(.warmupInterval(seconds: 600))
        XCTAssertEqual(interval["warmupSeconds"], .number(600))
        XCTAssertTrue(interval["warmupSchedule"].isNull, "interval and schedule are exclusive")

        var withSeconds = config()
        ConfigFile.patch(&withSeconds, path: ["warmupSeconds"], value: .number(600))
        let reset = try mutated(.warmupReset(time: "15:30", timezone: "Europe/Moscow"), from: withSeconds)
        XCTAssertEqual(reset["warmupSeconds"], .number(0))
        XCTAssertEqual(reset["warmupSchedule"], .object(["resetTime": .string("15:30"), "timezone": .string("Europe/Moscow")]))
        let rolling = try mutated(.warmupRolling(time: "09:00", timezone: "UTC"), from: withSeconds)
        XCTAssertEqual(rolling["warmupSeconds"], .number(0))
        XCTAssertEqual(rolling["warmupSchedule"], .object(["mode": .string("rolling"), "resetTime": .string("09:00"), "timezone": .string("UTC")]))
    }

    func testDistributeJSON() throws {
        XCTAssertEqual(try mutated(.distribute("on"))["distributeSessions"], .bool(true))
        XCTAssertEqual(try mutated(.distribute("off"))["distributeSessions"], .bool(false))
        XCTAssertEqual(try mutated(.distribute("adaptive"))["distributeSessions"], .string("adaptive"))
    }

    func testEnabledAndPriorityJSON() throws {
        let disabled = try mutated(.enabled(account: "primary-max", org: nil, enabled: false))
        XCTAssertEqual(disabled["accounts"][0]["disabled"], .bool(true))
        let enabled = try mutated(.enabled(account: "api-fallback", org: nil, enabled: true))
        XCTAssertTrue(enabled["accounts"][3]["disabled"].isNull, "enabled means the key is gone, not false")
        XCTAssertEqual(enabled["accounts"][3]["apiKey"].string, "sk-ant-api03-your-api-key")

        XCTAssertEqual(try mutated(.priority(account: "primary-max", org: nil, value: .number(4)))["accounts"][0]["priority"], .number(4))
        XCTAssertEqual(try mutated(.priority(account: "primary-max", org: nil, value: .first))["accounts"][0]["priority"], .number(-1))
        XCTAssertEqual(try mutated(.priority(account: "primary-max", org: nil, value: .last))["accounts"][0]["priority"], .number(100))
        XCTAssertThrowsError(try mutated(.priority(account: "nobody", org: nil, value: .first))) {
            XCTAssertEqual($0 as? SettingsError, .noSuchAccount("nobody"))
        }
    }

    func testRoutesJSON() throws {
        let replaced = try mutated(.routeAdd(name: "fable", match: ["*fable*", "*opus*"], accounts: ["primary-max", "api-fallback"], bucket: "unified7dFable", color: "cyan"))
        XCTAssertEqual(replaced["routes"].array?.count, 1, "same name replaces the row")
        XCTAssertEqual(replaced["routes"][0], .object([
            "name": .string("fable"), "match": .array([.string("*fable*"), .string("*opus*")]),
            "accounts": .array([.string("primary-max"), .string("api-fallback")]), "bucket": .string("unified7dFable"), "color": .string("cyan"),
        ]))
        let added = try mutated(.routeAdd(name: "haiku", match: ["*haiku*"], accounts: [], bucket: nil, color: ""), from: replaced)
        XCTAssertEqual(added["routes"].array?.count, 2)
        XCTAssertEqual(added["routes"][1], .object(["name": .string("haiku"), "match": .array([.string("*haiku*")])]), "empty optionals are omitted")
        let removed = try mutated(.routeRemove(name: "fable"), from: added)
        XCTAssertEqual(removed["routes"].array?.map { $0["name"].string }, ["haiku"])
        XCTAssertEqual(try mutated(.routeRemove(name: "none"), from: removed)["routes"], removed["routes"])

        var noRoutes = config()
        ConfigFile.patch(&noRoutes, path: ["routes"], value: nil)
        XCTAssertEqual(try mutated(.routeAdd(name: "x", match: ["*"], accounts: [], bucket: nil, color: nil), from: noRoutes)["routes"].array?.count, 1)
    }

    func testRemoveAccountJSON() throws {
        let removed = try mutated(.removeAccount(name: "codex@example.com", org: nil))
        XCTAssertEqual(removed["accounts"].array?.map { $0["id"].string }, ["acct-1", "acct-2", "acct-4"])
        XCTAssertThrowsError(try mutated(.removeAccount(name: "nobody", org: nil))) { XCTAssertEqual($0 as? SettingsError, .noSuchAccount("nobody")) }

        var twins = config()
        var rows = twins["accounts"].array!
        rows.append(.object(["name": .string("codex@example.com"), "orgName": .string("Other"), "id": .string("acct-5")]))
        ConfigFile.patch(&twins, path: ["accounts"], value: .array(rows))
        XCTAssertThrowsError(try mutated(.removeAccount(name: "codex@example.com", org: nil), from: twins)) {
            XCTAssertEqual($0 as? SettingsError, .ambiguousAccount("codex@example.com"))
        }
        let byOrg = try mutated(.removeAccount(name: "codex@example.com", org: "Other"), from: twins)
        XCTAssertEqual(byOrg["accounts"].array?.map { $0["id"].string }, ["acct-1", "acct-2", "acct-3", "acct-4"])
        let byOrgUuid = try mutated(.removeAccount(name: "user@example.com (Acme)", org: "optional-organization-uuid"))
        XCTAssertEqual(byOrgUuid["accounts"].array?.count, 3)
        XCTAssertThrowsError(try mutated(.removeAccount(name: "codex@example.com", org: "Nowhere"), from: twins)) {
            XCTAssertEqual($0 as? SettingsError, .noSuchAccount("codex@example.com"))
        }
    }

    func testAccountFieldJSON() throws {
        let patched = try mutated(.accountField(name: "stale", id: "acct-4", key: "maxUsage", value: .number(0.5), applies: .live))
        XCTAssertEqual(patched["accounts"][3]["maxUsage"], .number(0.5))
        let cleared = try mutated(.accountField(name: "api-fallback", id: nil, key: "maxUsage", value: nil, applies: .live), from: patched)
        XCTAssertTrue(cleared["accounts"][3]["maxUsage"].isNull)
        for key in ["accessToken", "refreshToken", "apiKey", "expiresAt"] {
            XCTAssertThrowsError(try mutated(.accountField(name: "api-fallback", id: nil, key: key, value: .string("x"), applies: .live)), key) {
                XCTAssertEqual($0 as? SettingsError, .noSuchAccount("api-fallback"), "a refused token key surfaces as the account not being patchable")
            }
        }
        XCTAssertThrowsError(try mutated(.accountField(name: "nobody", id: nil, key: "maxUsage", value: .number(1), applies: .live))) {
            XCTAssertEqual($0 as? SettingsError, .noSuchAccount("nobody"))
        }
    }

    func testGenericJSONPatch() throws {
        let doc = try mutated(.json(path: ["expiryRouting", "enabled"], value: .bool(true), applies: .live))
        XCTAssertEqual(doc["expiryRouting"]["enabled"], .bool(true))
        XCTAssertEqual(doc["expiryRouting"]["tolerance"].double, 1.5)
        let created = try mutated(.json(path: ["stormRamp", "startConc"], value: .number(4), applies: .restart))
        XCTAssertEqual(created["stormRamp"], .object(["startConc": .number(4)]))
        let deleted = try mutated(.json(path: ["upstreamProxy"], value: nil, applies: .live))
        XCTAssertTrue(deleted["upstreamProxy"].isNull)
    }

    func testEnabledAndPriorityJSONHonourOrgWithDuplicateNames() throws {
        var twins = config()
        var rows = twins["accounts"].array!
        rows.append(.object(["name": .string("codex@example.com"), "orgName": .string("Other"), "id": .string("acct-5")]))
        ConfigFile.patch(&twins, path: ["accounts"], value: .array(rows))
        let out = try mutated(.enabled(account: "codex@example.com", org: "Other", enabled: false), from: twins)
        XCTAssertTrue(out["accounts"][2]["disabled"].isNull, "the twin in the other organization is untouched")
        XCTAssertEqual(out["accounts"][4]["disabled"], .bool(true))
        let prio = try mutated(.priority(account: "codex@example.com", org: "Other", value: .number(7)), from: twins)
        XCTAssertEqual(prio["accounts"][4]["priority"], .number(7))
        XCTAssertNotEqual(prio["accounts"][2]["priority"], .number(7))
        XCTAssertThrowsError(try mutated(.enabled(account: "codex@example.com", org: nil, enabled: false), from: twins)) {
            XCTAssertEqual($0 as? SettingsError, .ambiguousAccount("codex@example.com"))
        }
        XCTAssertThrowsError(try mutated(.priority(account: "codex@example.com", org: "Nowhere", value: .first), from: twins)) {
            XCTAssertEqual($0 as? SettingsError, .noSuchAccount("codex@example.com"))
        }
    }

    // MARK: applies

    func testAppliesResolution() {
        let live = Applies.liveSince("1.1.19")
        XCTAssertEqual(live.resolved(serverVersion: "1.1.19"), .live)
        XCTAssertEqual(live.resolved(serverVersion: "1.2.0"), .live)
        XCTAssertEqual(live.resolved(serverVersion: "unknown"), .live)
        XCTAssertEqual(live.resolved(serverVersion: "1.1.18"), .restart)
        XCTAssertEqual(live.resolved(serverVersion: nil), .restart)
        XCTAssertEqual(Applies.live.resolved(serverVersion: nil), .live)
        XCTAssertEqual(Applies.restart.resolved(serverVersion: "9.9.9"), .restart)

        XCTAssertEqual(SettingsPlanner.applies(.json(path: ["blockedModels"], value: .array([]), applies: .liveSince("1.1.19"))), .liveSince("1.1.19"))
        XCTAssertEqual(SettingsPlanner.applies(.json(path: ["holdSeconds"], value: .number(0), applies: .restart)), .restart)
        XCTAssertEqual(SettingsPlanner.applies(.removeAccount(name: "a", org: nil)), .restart)
        XCTAssertEqual(SettingsPlanner.applies(.threshold(percent: 90)), .live)
        XCTAssertEqual(SettingsPlanner.applies(.routeAdd(name: "x", match: ["*"], accounts: [], bucket: nil, color: nil)), .live)
        XCTAssertEqual(SettingsPlanner.applies(.accountField(name: "a", id: nil, key: "stripRequestFields", value: .array([]), applies: .restart)), .restart)
    }

    func testSemverCompare() {
        XCTAssertEqual(Semver.compare("1.1.18", "1.1.19"), -1)
        XCTAssertEqual(Semver.compare("1.2.0", "1.1.19"), 1)
        XCTAssertEqual(Semver.compare("1.1.19", "1.1.19"), 0)
        XCTAssertEqual(Semver.compare("1.1", "1.1.0"), 0)
        XCTAssertEqual(Semver.compare("1.10.0", "1.9.0"), 1)
        XCTAssertEqual(Semver.compare("2", "1.99.99"), 1)
        XCTAssertEqual(Semver.compare("1.1.19-beta", "1.1.19"), 0, "a pre-release tag is ignored")
        XCTAssertEqual(Semver.compare("1.1.19-beta.1", "1.1.19"), 1, "but a dotted part after it still counts as a fourth component")
        XCTAssertEqual(Semver.compare("unknown", "9.9.9"), 1, "a git checkout sorts newest")
        XCTAssertEqual(Semver.compare("1.0.0", "unknown"), -1)
        XCTAssertEqual(Semver.compare("unknown", "unknown"), 1)
        XCTAssertEqual(Semver.compare("garbage", "0.0.0"), 0)
    }

    func testSchemaLookups() {
        XCTAssertEqual(SettingsSchema.field("switchThreshold")?.path, ["switchThreshold"])
        XCTAssertEqual(SettingsSchema.field("expiryRouting.enabled")?.path, ["expiryRouting", "enabled"])
        XCTAssertEqual(SettingsSchema.field("expiryRouting.enabled")?.section, .rotation)
        XCTAssertNil(SettingsSchema.field("nope"))
        XCTAssertTrue(SettingsSchema.fields(in: .quota).map(\.id).contains("quotaProbeSeconds"))
        XCTAssertEqual(SettingsSchema.field("blockedModels")?.applies, .liveSince(SettingsSchema.reloadFixVersion))
        XCTAssertEqual(SettingsSchema.field("proxy.apiKey")?.sensitive, true)
        XCTAssertEqual(SettingsSchema.field("switchThreshold")?.cli, true)
        XCTAssertEqual(Set(SettingsSchema.fields.map(\.id)).count, SettingsSchema.fields.count, "ids are unique")
        XCTAssertEqual(SettingsSchema.accountFields.map(\.id), ["maxUsage", "upstream", "modelMap", "stripRequestFields"])
    }
}
