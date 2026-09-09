import Foundation
import XCTest
import TeamClaudeCore

final class AlertEngineTests: XCTestCase {
    /// Whole seconds, so reset instants survive the millisecond round-trip exactly.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    private var prefs = AlertPrefs()
    private var state = AlertState()
    private var previous: StatusSnapshot?

    private func healthy(current: String = "alice") -> StatusSnapshot {
        makeStatus(current: current, accounts: [accountJSON("alice", fiveHour: 0.3), accountJSON("bob", fiveHour: 0.2)])
    }

    private func hold() -> StatusSnapshot {
        makeStatus(current: "alice", accounts: [accountJSON("alice", unavailable: "quota", fiveHour: 0.99), accountJSON("bob", unavailable: "throttled", fiveHour: 0.5)])
    }

    /// Runs one evaluation against the running state and returns what fired.
    @discardableResult
    private func evaluate(status: StatusSnapshot?, quota: QuotaSnapshot? = nil, reachable: Bool = true, appSwitchedTo: String? = nil, at: Date? = nil) -> [Alert] {
        let inputs = AlertInputs(previous: previous, status: status, quota: quota, reachable: reachable, appSwitchedTo: appSwitchedTo, now: at ?? now)
        let r = AlertEngine.evaluate(inputs, state: state, prefs: prefs)
        state = r.state
        if let status { previous = status }
        return r.alerts
    }

    private func fleet(_ util: Double, reset: Date? = nil) -> QuotaSnapshot {
        makeQuota(fiveHour: util, weekly: 0.1, nextResetAt: reset ?? now.addingTimeInterval(3 * 3600))
    }

    func testFirstEvaluationSeedsSilently() {
        let alerts = evaluate(status: healthy(), quota: fleet(0.96))
        XCTAssertEqual(alerts, [])
        XCTAssertTrue(state.seeded)
        XCTAssertEqual(state.fired["fleet.5h"], [90, 95], "levels already crossed are remembered, not announced")
        XCTAssertEqual(state.lastCurrent, "alice")
        XCTAssertEqual(evaluate(status: healthy(), quota: fleet(0.96)), [], "and stay quiet afterwards")
    }

    func testFleetLevelsFireOnceEach() {
        evaluate(status: healthy(), quota: fleet(0.70))
        let at92 = evaluate(status: healthy(), quota: fleet(0.92))
        XCTAssertEqual(at92.count, 1)
        XCTAssertEqual(at92[0].kind, .fleetLevel)
        XCTAssertEqual(at92[0].title, "Fleet 5-hour usage at 92%")
        XCTAssertEqual(at92[0].body, "2 accounts weighted by tier · next reset in 3h")
        XCTAssertFalse(at92[0].sound)
        let windowId = Int(now.addingTimeInterval(3 * 3600).timeIntervalSince1970)
        XCTAssertEqual(at92[0].id, "fleet.5h.90.\(windowId)")
        XCTAssertEqual(evaluate(status: healthy(), quota: fleet(0.92)), [])
        let at96 = evaluate(status: healthy(), quota: fleet(0.96))
        XCTAssertEqual(at96.map(\.id), ["fleet.5h.95.\(windowId)"])
        XCTAssertEqual(at96[0].title, "Fleet 5-hour usage at 96%")
        XCTAssertEqual(evaluate(status: healthy(), quota: fleet(0.96)), [])
        XCTAssertEqual(evaluate(status: healthy(), quota: fleet(0.99)), [])
    }

    func testWeeklyMetricAndPreferenceGate() {
        let q = { (w: Double) in makeQuota(fiveHour: 0.1, weekly: w, nextResetAt: self.now.addingTimeInterval(86400)) }
        evaluate(status: healthy(), quota: q(0.5))
        let fired = evaluate(status: healthy(), quota: q(0.91))
        XCTAssertEqual(fired.map(\.title), ["Fleet weekly usage at 91%"])
        XCTAssertTrue(fired[0].id.hasPrefix("fleet.7d.90."))
        prefs.fleetWeekly = false
        state = AlertState()
        evaluate(status: healthy(), quota: q(0.5))
        XCTAssertEqual(evaluate(status: healthy(), quota: q(0.91)), [])
        XCTAssertEqual(state.fired["fleet.7d"], [90], "still tracked while muted")
    }

    func testHysteresisReArmsFivePointsBelowTheLevel() {
        evaluate(status: healthy(), quota: fleet(0.96))
        XCTAssertEqual(evaluate(status: healthy(), quota: fleet(0.84)), [], "dropping re-arms without announcing")
        XCTAssertEqual(state.fired["fleet.5h"], [])
        XCTAssertEqual(evaluate(status: healthy(), quota: fleet(0.92)).map(\.title), ["Fleet 5-hour usage at 92%"])

        state = AlertState()
        evaluate(status: healthy(), quota: fleet(0.96))
        evaluate(status: healthy(), quota: fleet(0.87))
        XCTAssertEqual(state.fired["fleet.5h"], [90], "87 is inside the 85–90 band, so 90 stays armed-off; 95 re-armed")
        XCTAssertEqual(evaluate(status: healthy(), quota: fleet(0.92)), [])

        state = AlertState()
        evaluate(status: healthy(), quota: fleet(0.96))
        evaluate(status: healthy(), quota: fleet(0.93))
        XCTAssertEqual(state.fired["fleet.5h"], [90, 95], "93 is within five points of both levels")
        XCTAssertEqual(evaluate(status: healthy(), quota: fleet(0.92)), [])
        XCTAssertEqual(evaluate(status: healthy(), quota: fleet(0.95)), [])
        evaluate(status: healthy(), quota: fleet(0.89))
        XCTAssertEqual(state.fired["fleet.5h"], [90], "89 re-arms 95 only")
        XCTAssertEqual(evaluate(status: healthy(), quota: fleet(0.95)).map(\.title), ["Fleet 5-hour usage at 95%"])
    }

    func testChangedResetReArmsEverything() {
        evaluate(status: healthy(), quota: fleet(0.96))
        XCTAssertEqual(evaluate(status: healthy(), quota: fleet(0.96)), [])
        let nextWindow = now.addingTimeInterval(8 * 3600)
        let fired = evaluate(status: healthy(), quota: fleet(0.96, reset: nextWindow))
        XCTAssertEqual(fired.map(\.title), ["Fleet 5-hour usage at 96%", "Fleet 5-hour usage at 96%"])
        XCTAssertEqual(fired.map(\.id), ["fleet.5h.90.\(Int(nextWindow.timeIntervalSince1970))", "fleet.5h.95.\(Int(nextWindow.timeIntervalSince1970))"])
        XCTAssertEqual(state.windowIds["fleet.5h"], nextWindow.timeIntervalSince1970)
    }

    func testFleetWithoutAggregateOrUtilizationIsIgnored() {
        evaluate(status: healthy(), quota: makeQuota(fiveHour: nil))
        XCTAssertEqual(evaluate(status: healthy(), quota: makeQuota(fiveHour: nil)), [])
        XCTAssertEqual(evaluate(status: healthy(), quota: nil), [])
        XCTAssertNil(state.fired["fleet.5h"])
    }

    func testRotationAlert() {
        let before = makeStatus(current: "alice", accounts: [accountJSON("alice", unavailable: "quota"), accountJSON("bob")])
        let after = makeStatus(current: "bob", accounts: [accountJSON("alice", unavailable: "quota"), accountJSON("bob")])
        evaluate(status: before)
        let fired = evaluate(status: after)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].kind, .rotation)
        XCTAssertEqual(fired[0].id, "rotate.alice.bob")
        XCTAssertEqual(fired[0].title, "Rotated: alice → bob")
        XCTAssertEqual(fired[0].body, "alice: local switch threshold reached")
        XCTAssertTrue(fired[0].sound)
        XCTAssertEqual(state.lastCurrent, "bob")
        XCTAssertEqual(evaluate(status: after), [])
    }

    func testRotationBodyWithoutAReason() {
        evaluate(status: healthy(current: "alice"))
        let fired = evaluate(status: healthy(current: "bob"))
        XCTAssertEqual(fired.map(\.body), ["Rotation moved to bob."])
    }

    func testRotationFollowsDefaultTarget() {
        evaluate(status: makeStatus(current: "alice", accounts: [accountJSON("alice"), accountJSON("bob")], extra: ["defaultTarget": .string("alice")]))
        let fired = evaluate(status: makeStatus(current: "alice", accounts: [accountJSON("alice"), accountJSON("bob")], extra: ["defaultTarget": .string("bob")]))
        XCTAssertEqual(fired.map(\.title), ["Rotated: alice → bob"], "the account carrying new requests changed, even though `currentAccount` did not")
    }

    func testRotationSuppressedForTheAppsOwnSwitch() {
        evaluate(status: healthy(current: "alice"))
        XCTAssertEqual(evaluate(status: healthy(current: "bob"), appSwitchedTo: "bob"), [])
        XCTAssertEqual(state.lastCurrent, "bob")
        XCTAssertEqual(evaluate(status: healthy(current: "alice"), appSwitchedTo: "bob").map(\.title), ["Rotated: bob → alice"])
    }

    func testRotationPreferenceOff() {
        prefs.rotation = false
        evaluate(status: healthy(current: "alice"))
        XCTAssertEqual(evaluate(status: healthy(current: "bob")), [])
        XCTAssertEqual(state.lastCurrent, "bob")
    }

    func testAccountErrorFiresOnceAndReArmsAfterClearing() {
        let errored = makeStatus(current: "bob", accounts: [accountJSON("alice", unavailable: "error"), accountJSON("bob")])
        evaluate(status: healthy(current: "bob"))
        let fired = evaluate(status: errored)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].kind, .accountError)
        XCTAssertEqual(fired[0].id, "acct.error.alice")
        XCTAssertEqual(fired[0].title, "alice needs a re-login")
        XCTAssertEqual(state.errorAccounts, ["alice"])
        XCTAssertEqual(evaluate(status: errored), [])
        XCTAssertEqual(evaluate(status: healthy(current: "bob")), [])
        XCTAssertEqual(state.errorAccounts, [])
        XCTAssertEqual(evaluate(status: errored).map(\.id), ["acct.error.alice"])
    }

    func testAccountErrorSeededIsNotAnnounced() {
        let errored = makeStatus(current: "bob", accounts: [accountJSON("alice", unavailable: "error"), accountJSON("bob")])
        XCTAssertEqual(evaluate(status: errored), [])
        XCTAssertEqual(state.errorAccounts, ["alice"])
        XCTAssertEqual(evaluate(status: errored), [])
    }

    func testHoldFiresOnTheEdge() throws {
        let hold = hold()
        evaluate(status: healthy())
        let fired = evaluate(status: hold)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].kind, .hold)
        XCTAssertEqual(fired[0].id, "hold")
        XCTAssertEqual(fired[0].title, "No account can serve requests")
        XCTAssertEqual(fired[0].body, "every account is over its quota threshold or in a rate-limit hold")
        XCTAssertTrue(fired[0].sound)
        XCTAssertTrue(state.allOut)
        XCTAssertEqual(evaluate(status: hold), [])
        XCTAssertEqual(evaluate(status: healthy()), [])
        XCTAssertFalse(state.allOut)
        XCTAssertEqual(evaluate(status: hold).map(\.kind), [.hold])
    }

    func testHoldBodyWhenAnAccountIsOutForAnotherReason() {
        evaluate(status: healthy())
        let out = makeStatus(current: "alice", accounts: [accountJSON("alice", unavailable: "quota"), accountJSON("bob", unavailable: "error")])
        let fired = evaluate(status: out)
        XCTAssertEqual(fired.map(\.kind), [.accountError, .hold])
        XCTAssertEqual(fired.filter { $0.kind == .hold }.map(\.body), ["every account is out of rotation"])
    }

    func testProxyDownNeedsTwoConsecutiveMisses() {
        evaluate(status: healthy())
        XCTAssertEqual(evaluate(status: nil, reachable: false), [])
        XCTAssertEqual(state.downStreak, 1)
        XCTAssertFalse(state.announcedDown)
        let fired = evaluate(status: nil, reachable: false)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].kind, .proxyDown)
        XCTAssertEqual(fired[0].id, "proxy.down")
        XCTAssertTrue(fired[0].sound)
        XCTAssertTrue(state.announcedDown)
        XCTAssertEqual(evaluate(status: nil, reachable: false), [])
        XCTAssertEqual(state.downStreak, 3)
    }

    func testABlipResetsTheStreak() {
        evaluate(status: healthy())
        evaluate(status: nil, reachable: false)
        evaluate(status: healthy())
        XCTAssertEqual(state.downStreak, 0)
        XCTAssertEqual(evaluate(status: nil, reachable: false), [])
    }

    func testProxyBackOnlyWhenAskedFor() {
        evaluate(status: healthy())
        evaluate(status: nil, reachable: false)
        evaluate(status: nil, reachable: false)
        XCTAssertEqual(evaluate(status: healthy()), [], "proxyBack is off by default")
        XCTAssertFalse(state.announcedDown)

        prefs.proxyBack = true
        evaluate(status: nil, reachable: false)
        evaluate(status: nil, reachable: false)
        let back = evaluate(status: healthy())
        XCTAssertEqual(back.map(\.kind), [.proxyBack])
        XCTAssertEqual(back[0].id, "proxy.back")
        XCTAssertFalse(state.announcedDown)
    }

    func testProxyDownPreferenceOffStillTracks() {
        prefs.proxyDown = false
        evaluate(status: nil, reachable: false)
        XCTAssertEqual(evaluate(status: nil, reachable: false), [])
        XCTAssertTrue(state.announcedDown)
    }

    func testPauseMutesFleetAndRotationButNotHoldOrDown() throws {
        prefs.pausedUntil = now.addingTimeInterval(3600)
        XCTAssertTrue(prefs.isPaused(at: now))
        evaluate(status: healthy(current: "alice"), quota: fleet(0.5))
        XCTAssertEqual(evaluate(status: healthy(current: "bob"), quota: fleet(0.92)), [])
        XCTAssertEqual(state.fired["fleet.5h"], [90], "muted, but still recorded so it will not fire after the pause")
        XCTAssertEqual(state.lastCurrent, "bob")
        XCTAssertEqual(evaluate(status: try Fixtures.status("status-hold.json")).map(\.kind), [.hold])
        evaluate(status: nil, reachable: false)
        XCTAssertEqual(evaluate(status: nil, reachable: false).map(\.kind), [.proxyDown])

        prefs.pausedUntil = now.addingTimeInterval(-1)
        XCTAssertFalse(prefs.isPaused(at: now))
        XCTAssertEqual(evaluate(status: healthy(current: "alice")).map(\.kind), [.rotation])
    }

    func testAlertStateRoundTrips() throws {
        var s = AlertState()
        s.seeded = true
        s.fired = ["fleet.5h": [90, 95], "fleet.7d": []]
        s.windowIds = ["fleet.5h": 1788970200]
        s.lastCurrent = "alice@example.com"
        s.allOut = true
        s.errorAccounts = ["bob"]
        s.downStreak = 2
        s.announcedDown = true
        s.spendSeen = ["spend.alice.2026-9"]
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(AlertState.self, from: data), s)

        var p = AlertPrefs()
        p.levels = [80]
        p.pausedUntil = Date(timeIntervalSince1970: 1_800_000_000)
        p.proxyBack = true
        XCTAssertEqual(try JSONDecoder().decode(AlertPrefs.self, from: try JSONEncoder().encode(p)), p)
    }

    func testSpendAlertOncePerAccountPerMonth() throws {
        func billing(_ used: Double) -> StatusSnapshot {
            makeStatus(current: "alice", accounts: [
                accountJSON("alice", extraQuota: ["spend": .object(["enabled": .bool(true), "usedMinor": .number(used), "currency": .string("USD"), "exponent": .number(2)])]),
                accountJSON("bob"),
            ])
        }
        evaluate(status: billing(0))
        XCTAssertEqual(state.spendSeen, [], "nothing used yet")
        let fired = evaluate(status: billing(123))
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].kind, .spend)
        XCTAssertEqual(fired[0].title, "alice is billing overage")
        XCTAssertEqual(fired[0].body, "$1.23 used this month")
        let month = Calendar.current.dateComponents([.year, .month], from: now)
        XCTAssertEqual(fired[0].id, "spend.alice.\(month.year!)-\(month.month!)")
        XCTAssertEqual(evaluate(status: billing(999)), [], "already announced this month")

        let nextMonth = try XCTUnwrap(Calendar.current.date(byAdding: .month, value: 1, to: now))
        XCTAssertEqual(evaluate(status: billing(50), at: nextMonth).map(\.body), ["$0.50 used this month"])
        XCTAssertEqual(state.spendSeen.count, 2)
    }

    func testSpendSeededSilently() {
        let billing = makeStatus(current: "alice", accounts: [accountJSON("alice", extraQuota: ["spend": .object(["enabled": .bool(true), "usedMinor": .number(5)])])])
        XCTAssertEqual(evaluate(status: billing), [])
        XCTAssertEqual(state.spendSeen.count, 1)
        XCTAssertEqual(evaluate(status: billing), [])
    }
}
