import Foundation
import XCTest
import TeamClaudeCore

final class StatusDecodingTests: XCTestCase {
    func testEveryStatusFixtureDecodes() {
        for name in Fixtures.statusNames {
            XCTAssertNoThrow(try Fixtures.status(name), name)
        }
    }

    func testOlderShapeHasNoDefaultTarget() throws {
        let s = try Fixtures.status("status-live-1.1.16.json")
        XCTAssertFalse(s.hasDefaultTarget)
        XCTAssertNil(s.defaultTarget)
        XCTAssertEqual(s.currentAccount, "bob@example.com")
        XCTAssertEqual(s.effectiveDefaultTarget, s.currentAccount)
        XCTAssertEqual(s.current?.name, "bob@example.com")
        XCTAssertEqual(s.switchThreshold, 0.98)
        XCTAssertNil(s.switchThresholds, "`switchThresholds: null` on the wire is no table")
        XCTAssertEqual(s.thresholdFor(bucket: "unified7dFable"), 0.98)
        XCTAssertEqual(s.accounts.count, 2)
        XCTAssertEqual(s.accounts[0].name, "alice@example.com")
        XCTAssertEqual(s.accounts[0].orgName, "Example Org")
        XCTAssertEqual(s.accounts[0].quota.unified5h, 0.37)
        XCTAssertEqual(s.accounts[0].quota.unified7dFable, 0.05)
        XCTAssertEqual(s.accounts[0].quota.scopedWeekly["fable"]?.utilization, 0.05)
        XCTAssertEqual(s.accounts[0].quota.spend?.enabled, false)
        XCTAssertEqual(s.accounts[0].usage.totalRequests, 3619)
        XCTAssertEqual(s.accounts[0].usage.totalTokens, 1087374 + 3041249 + 816898709 + 18529981)
        XCTAssertEqual(s.server?.port, 3456)
        XCTAssertEqual(s.server?.uptimeSeconds, 230355)
        XCTAssertEqual(s.probe?.enabled, true)
        XCTAssertEqual(s.probe?.intervalSeconds, 300)
        XCTAssertEqual(s.probe?.accounts.map(\.name), ["alice@example.com", "bob@example.com"])
        XCTAssertEqual(s.probe?.accounts[0].durationMs, 487)
        XCTAssertNil(s.probe?.accounts[0].error)
        XCTAssertEqual(s.warm?.enabled, false)
        XCTAssertEqual(s.warm?.mode, "off")
        XCTAssertNil(s.warm?.accounts[0].lastAt)
        XCTAssertEqual(s.routes.count, 1)
        XCTAssertEqual(s.routes[0].name, "fable")
        XCTAssertEqual(s.routes[0].match, ["*fable*"])
        XCTAssertTrue(s.routes[0].autocreated)
        XCTAssertEqual(s.routes[0].target, "bob@example.com")
        XCTAssertEqual(s.routes[0].accounts.map(\.name), ["alice@example.com", "bob@example.com"])
        XCTAssertEqual(s.routes[0].accounts.map(\.eligible), [true, true])
        XCTAssertEqual(s.sessions?.known, 9)
        XCTAssertEqual(s.sessions?.active, 2)
        XCTAssertEqual(s.sessions?.distribute, true)
        XCTAssertEqual(s.sessions?.mode, "even", "derived from `distribute` when the server sends no mode")
        XCTAssertEqual(s.sessions?.perAccount, [0: 1, 1: 1])
        XCTAssertEqual(s.blockedModels, [])
    }

    func testNewerShapeCarriesDefaultTargetAndThresholdTable() throws {
        let s = try Fixtures.status("status-1.1.18.json")
        XCTAssertTrue(s.hasDefaultTarget)
        XCTAssertEqual(s.defaultTarget, "bob@example.com")
        XCTAssertEqual(s.effectiveDefaultTarget, "bob@example.com")
        XCTAssertEqual(s.switchThresholds, ["unified7dFable": 0.9])
        XCTAssertEqual(s.thresholdFor(bucket: "unified7dFable"), 0.9, "the table wins")
        XCTAssertEqual(s.thresholdFor(bucket: "unified5h"), 0.98, "then the scalar")
        XCTAssertEqual(s.sessions?.mode, "off")
        XCTAssertEqual(s.sessions?.draining, 0)
        XCTAssertEqual(s.sessions?.distribute, false)
        XCTAssertEqual(s.raw["expiryRouting"]["enabled"].bool, false)
        XCTAssertEqual(s.raw["upstreamPool"]["origins"].int, 1)
        XCTAssertEqual(s.raw["server"]["eventLoop"]["maxLagMs"].int, 12)
        XCTAssertEqual(s.accounts[0].raw["pressure"].double, 0.42)
        XCTAssertEqual(s.accounts[0].raw["sessionsByBucket"]["unified7d"].int, 1)
        XCTAssertTrue(s.accounts[1].raw["sessionsByBucket"].isNull)
    }

    func testDefaultTargetDistinctFromCurrent() {
        let s = makeStatus(current: "alice", accounts: [accountJSON("alice"), accountJSON("bob")], extra: ["defaultTarget": .string("bob")])
        XCTAssertTrue(s.hasDefaultTarget)
        XCTAssertEqual(s.effectiveDefaultTarget, "bob")
        XCTAssertEqual(s.current?.name, "alice")
    }

    func testHostileFixtureDegradesInsteadOfThrowing() throws {
        let s = try Fixtures.status("status-hostile.json")
        XCTAssertEqual(s.switchThreshold, 0.98, "a string threshold falls back to the default")
        XCTAssertEqual(s.switchThresholds, ["unified5h": 0.95], "only numeric entries of the table survive")
        XCTAssertNil(s.server, "a string is not a server object")
        XCTAssertNil(s.warm)
        XCTAssertEqual(s.probe?.enabled, false)
        XCTAssertEqual(s.probe?.intervalSeconds, 0)
        XCTAssertNil(s.probe?.lastRunStartedAt)
        XCTAssertEqual(s.probe?.accounts, [])
        XCTAssertEqual(s.routes, [])
        XCTAssertEqual(s.blockedModels, [])
        XCTAssertNil(s.defaultTarget)
        XCTAssertFalse(s.hasDefaultTarget)
        XCTAssertEqual(s.sessions?.known, 0)
        XCTAssertEqual(s.sessions?.active, 0)
        XCTAssertEqual(s.sessions?.distribute, true, "a string mode still means distribution is on")
        XCTAssertEqual(s.sessions?.mode, "even")
        XCTAssertEqual(s.sessions?.draining, 0)
        XCTAssertEqual(s.sessions?.perAccount, [:])
        XCTAssertEqual(s.accounts.count, 2)

        let a = s.accounts[0]
        XCTAssertEqual(a.unavailable, "future-reason", "unknown codes are kept verbatim")
        XCTAssertEqual(UnavailableText.label(a.unavailable), "future-reason")
        XCTAssertEqual(a.name.count, 64)
        XCTAssertTrue(a.name.hasSuffix("…"))
        XCTAssertTrue(a.name.dropLast().allSatisfy { $0 == "x" }, "control characters are stripped before the cap")
        XCTAssertEqual(s.currentAccount, a.name)
        XCTAssertEqual(s.current, a)
        XCTAssertEqual(a.type, "oauth")
        XCTAssertEqual(a.priority, 0)
        XCTAssertFalse(a.disabled)
        XCTAssertEqual(a.status, "active")
        XCTAssertEqual(a.sessions, 0)
        XCTAssertEqual(a.maxUsage, .string("lots"), "kept raw for the view to interpret")
        XCTAssertNil(a.quota.unified5h, "a numeric string is not a number")
        XCTAssertNil(a.quota.unified5hReset)
        XCTAssertNil(a.quota.spend)
        XCTAssertEqual(a.quota.backend?.label, "Backend")
        XCTAssertEqual(a.quota.backend?.text, "")
        XCTAssertNil(a.quota.backend?.utilization)
        XCTAssertEqual(a.quota.scopedWeekly.count, 2)
        XCTAssertNil(a.quota.scopedWeekly["opus"]?.utilization)
        XCTAssertEqual(a.usage.totalRequests, 0)
        XCTAssertEqual(a.rateLimitedUntil, Date(timeIntervalSince1970: 12), "a small number is epoch seconds")
        XCTAssertNil(a.pausedUntil)
        XCTAssertTrue(a.raw["unknownAccountKey"].array != nil, "unknown keys ride along in raw")

        let b = s.accounts[1]
        XCTAssertEqual(b.name, "")
        XCTAssertTrue(b.quota.isEmpty)
        XCTAssertEqual(b.usage.totalTokens, 0)
        XCTAssertEqual(s.raw["x-unknown-top-level"]["nested"][2].int, 3)
    }

    func testTextSafe() {
        XCTAssertEqual(Text.safe("plain"), "plain")
        XCTAssertEqual(Text.safe("a\u{01}b\u{7f}c\u{85}d\ne"), "abcde")
        XCTAssertEqual(Text.safe(String(repeating: "x", count: 64)).count, 64)
        let capped = Text.safe(String(repeating: "x", count: 65))
        XCTAssertEqual(capped.count, 64)
        XCTAssertTrue(capped.hasSuffix("…"))
        XCTAssertEqual(Text.safe("abcdef", max: 4), "abc…")
        XCTAssertEqual(Text.safe("日本語テキスト", max: 4), "日本語…")
    }

    func testAccountsNotAnArrayIsNotStatus() {
        for bad in [JSON.object([:]), .object(["accounts": .string("x")]), .object(["accounts": .object([:])]), .object(["accounts": .null]), .array([]), .string("html")] {
            XCTAssertThrowsError(try StatusSnapshot(json: bad)) { error in
                XCTAssertEqual(error as? SnapshotError, .notStatus)
            }
        }
        XCTAssertNoThrow(try StatusSnapshot(json: .object(["accounts": .array([])])))
    }

    func testEmptyFixture() throws {
        let s = try Fixtures.status("status-empty.json")
        XCTAssertEqual(s.accounts, [])
        XCTAssertNil(s.currentAccount)
        XCTAssertNil(s.current)
        XCTAssertNil(s.effectiveDefaultTarget)
        XCTAssertFalse(s.hasDefaultTarget)
        XCTAssertEqual(s.accountsByPriority, [])
    }

    func testTimestampsInBothShapes() throws {
        let hold = try Fixtures.status("status-hold.json")
        let bob = try XCTUnwrap(hold.account(named: "bob@example.com"))
        XCTAssertEqual(bob.rateLimitedUntil, Date(timeIntervalSince1970: 4102444800), "ISO-8601 string")
        XCTAssertEqual(bob.quota.unified5hReset, Date(timeIntervalSince1970: 4102444800), "epoch milliseconds")
        XCTAssertEqual(bob.unavailable, "throttled")
        XCTAssertEqual(bob.status, "throttled")

        let live = try Fixtures.status("status-live-1.1.16.json")
        XCTAssertEqual(live.accounts[0].quota.unified5hReset, Date(timeIntervalSince1970: 1788948600))
        XCTAssertEqual(live.accounts[0].quota.unified7dReset, Date(timeIntervalSince1970: 1789297200))
        XCTAssertEqual(live.accounts[0].quota.scopedWeekly["fable"]?.resetAt, Date(timeIntervalSince1970: 1789297199.660))
        XCTAssertEqual(try XCTUnwrap(live.probe?.lastRunStartedAt).timeIntervalSince1970, 1788944289.273, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(live.server?.startedAt).timeIntervalSince1970, 1788714157.537, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(live.accounts[1].usage.lastUsed).timeIntervalSince1970, 1788944504.043, accuracy: 0.001)
        XCTAssertNil(live.accounts[0].rateLimitedUntil)
    }

    func testAccountsByPriorityIsStable() {
        let s = makeStatus(current: nil, accounts: [
            accountJSON("c", priority: 1), accountJSON("a", priority: 0), accountJSON("b", priority: 0),
            accountJSON("d", priority: -1), accountJSON("e", priority: 1),
        ])
        XCTAssertEqual(s.accountsByPriority.map(\.name), ["d", "a", "b", "c", "e"])
        XCTAssertEqual(s.accounts.map(\.name), ["c", "a", "b", "d", "e"], "the wire order is untouched")
    }

    func testAccountLookup() throws {
        let s = try Fixtures.status("status-two-accounts-b-quota.json")
        XCTAssertEqual(s.account(named: "bob@example.com")?.unavailable, "quota")
        XCTAssertNil(s.account(named: "nobody"))
        XCTAssertNil(s.account(named: nil))
        XCTAssertEqual(s.accounts[0].quota.unified7dFable, 0.88)
        XCTAssertFalse(s.accounts[0].isApiKey)
        XCTAssertEqual(s.blockedModels, [])
    }

    func testSwitchAndReloadReplies() {
        let r = SwitchResult(ok: true, account: "bob", eligible: false, reason: "no route allows this account")
        XCTAssertEqual(r.account, "bob")
        XCTAssertEqual(r.eligible, false)
        XCTAssertNil(r.error)
        XCTAssertEqual(UnavailableText.label("quota"), "local switch threshold reached")
        XCTAssertNil(UnavailableText.label(nil))
    }
}
