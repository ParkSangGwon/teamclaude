import XCTest
@testable import TeamClaudeCore

/// 1.1.20 reports one cursor per provider; the app must follow the per-provider fields where they exist and the single cursor before.
final class ProviderTests: XCTestCase {
    func testMixedFleetHasACurrentAccountPerProvider() throws {
        let s = try Fixtures.status("status-mixed-providers.json")
        XCTAssertEqual(s.providers, ["anthropic", "codex"])
        let alice = try XCTUnwrap(s.account(named: "alice@example.com"))
        let carol = try XCTUnwrap(s.account(named: "carol@example.com"))
        XCTAssertEqual(alice.provider, "anthropic")
        XCTAssertEqual(carol.provider, "codex")
        XCTAssertTrue(s.isCurrent(alice))
        XCTAssertTrue(s.isCurrent(carol), "the Codex cursor is carol even though currentAccount names alice")
        XCTAssertFalse(s.isNext(alice))
        XCTAssertEqual(s.defaultTarget(for: "codex"), "carol@example.com")
        XCTAssertEqual(alice.knownSessions, 2)
        XCTAssertEqual(s.sessions?.knownPerAccount, [0: 2])
    }

    func testOlderServerFallsBackToTheSingleCursor() throws {
        let s = try Fixtures.status("status-two-accounts-b-quota.json")
        XCTAssertTrue(s.currentAccounts.isEmpty)
        XCTAssertEqual(s.providers, ["anthropic"])
        for a in s.accounts { XCTAssertEqual(s.isCurrent(a), a.name == s.currentAccount) }
        // A 1.1.16 payload has routes but no per-provider targets: one trailing default row, the old label.
        let old = try Fixtures.status("status-live-1.1.16.json")
        XCTAssertTrue(old.defaultTargets.isEmpty)
        XCTAssertEqual(Derived.routeRows(old).last?.label, "Everything else")
    }

    func testRouteRowsGetOneDefaultRowPerProvider() throws {
        let s = try Fixtures.status("status-mixed-providers.json")
        let rows = Derived.routeRows(s)
        XCTAssertEqual(rows.map(\.kind), [.route, .default, .default])
        XCTAssertEqual(rows.map(\.label), ["Fable", "Claude default", "Codex default"])
        XCTAssertEqual(rows[1].target, "alice@example.com")
        XCTAssertEqual(rows[2].target, "carol@example.com")
        XCTAssertEqual(rows[2].current, "carol@example.com")
    }

    func testReferenceFixtureCarriesTheProviderFields() throws {
        let s = try Fixtures.status("status-1.1.20.json")
        XCTAssertEqual(s.server?.version, "1.1.20")
        XCTAssertEqual(s.currentAccounts["anthropic"], s.currentAccount)
        XCTAssertEqual(s.routes.first?.provider, "anthropic")
        XCTAssertEqual(Derived.routeRows(s).last?.label, "Claude default")
    }
}

extension ProviderTests {
    /// The Codex cursor moving is a rotation of its own, announced and logged even though the Anthropic one stayed put.
    func testCodexRotationIsAnnouncedOnItsOwn() throws {
        let before = try Fixtures.status("status-mixed-providers.json")
        let after = try Fixtures.status("status-mixed-providers-rotated.json")
        var state = AlertState()
        var prefs = AlertPrefs(); prefs.rotation = true
        // Three hours before the fixture's 5-hour reset, so the reason carries a countdown.
        let now = try XCTUnwrap(after.account(named: "carol@example.com")?.quota.unified5hReset).addingTimeInterval(-3 * 3600)
        state = AlertEngine.evaluate(AlertInputs(previous: nil, status: before, quota: nil, reachable: true, now: now), state: state, prefs: prefs).state
        XCTAssertEqual(state.lastCurrents, ["anthropic": "alice@example.com", "codex": "carol@example.com"])
        let r = AlertEngine.evaluate(AlertInputs(previous: before, status: after, quota: nil, reachable: true, now: now), state: state, prefs: prefs)
        XCTAssertEqual(r.alerts.filter { $0.kind == .rotation }.map(\.title), ["Rotated: carol@example.com → dave@example.com"])
        XCTAssertEqual(r.alerts.first { $0.kind == .rotation }?.body, "carol@example.com: local switch threshold reached · resets in 3h")
        XCTAssertEqual(r.state.lastCurrents["codex"], "dave@example.com")
        XCTAssertEqual(r.state.lastCurrent, "alice@example.com", "the single cursor stays the Anthropic one for older state readers")
    }

    func testAStateFromBeforePerProviderCursorsStillDetectsTheAnthropicRotation() throws {
        let s = try Fixtures.status("status-1.1.20.json")
        var state = AlertState(); state.seeded = true; state.lastCurrent = "alice@example.com"
        var prefs = AlertPrefs(); prefs.rotation = true
        let r = AlertEngine.evaluate(AlertInputs(previous: nil, status: s, quota: nil, reachable: true), state: state, prefs: prefs)
        XCTAssertEqual(r.alerts.filter { $0.kind == .rotation }.map(\.title), ["Rotated: alice@example.com → \(s.currentAccount!)"])
    }

    func testNextUpIsOnePerProvider() throws {
        let s = try Fixtures.status("status-mixed-providers.json")
        let nexts = Derived.nextUps(s)
        XCTAssertEqual(nexts.map(\.provider), ["anthropic", "codex"])
        XCTAssertEqual(nexts.map(\.name), ["alice@example.com", "carol@example.com"])
        XCTAssertTrue(nexts.allSatisfy(\.isCurrent))
        XCTAssertEqual(Derived.nextUp(s)?.provider, "anthropic")
    }
}
