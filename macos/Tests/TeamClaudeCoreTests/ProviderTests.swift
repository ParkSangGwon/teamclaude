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
