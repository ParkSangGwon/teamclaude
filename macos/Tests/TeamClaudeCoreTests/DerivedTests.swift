import Foundation
import XCTest
import TeamClaudeCore

final class DerivedTests: XCTestCase {
    /// An integral instant so window arithmetic stays exact.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: level

    func testThresholdIsRedRegardlessOfPace() {
        // One second before the reset: the elapsed share is ~100%, so pace alone says green.
        let reset = now.addingTimeInterval(1)
        XCTAssertEqual(Derived.level(ratio: 0.5, resetAt: reset, window: Window.fiveHour, threshold: nil, now: now), .green)
        XCTAssertEqual(Derived.level(ratio: 0.5, resetAt: reset, window: Window.fiveHour, threshold: 0.5, now: now), .red)
        XCTAssertEqual(Derived.level(ratio: 0.99, resetAt: reset, window: Window.fiveHour, threshold: 0.98, now: now), .red)
        XCTAssertEqual(Derived.level(ratio: 0.97, resetAt: nil, window: nil, threshold: 0.98, now: now), .red, "no window: 0.97 ≥ 0.9")
        XCTAssertEqual(Derived.level(ratio: 0.5, resetAt: nil, window: nil, threshold: 0.98, now: now), .green)
    }

    func testPaceDifferenceBands() {
        // ratio 0.5 against an elapsed share of 50 / 45 / 35 / 34 percent of a 5-hour window.
        func level(elapsedShare: Double) -> Level {
            let remaining = Window.fiveHour * (1 - elapsedShare)
            return Derived.level(ratio: 0.5, resetAt: now.addingTimeInterval(remaining), window: Window.fiveHour, threshold: 0.98, now: now)
        }
        XCTAssertEqual(level(elapsedShare: 0.5), .green, "diff 0")
        XCTAssertEqual(level(elapsedShare: 0.45), .yellow, "diff 5")
        XCTAssertEqual(level(elapsedShare: 0.35), .orange, "diff 15")
        XCTAssertEqual(level(elapsedShare: 0.34), .red, "diff 16")
        XCTAssertEqual(level(elapsedShare: 0.75), .green, "behind the pace")
    }

    func testNoWindowRule() {
        for (ratio, expected) in [(0.0, Level.green), (0.69, .green), (0.7, .yellow), (0.89, .yellow), (0.9, .red), (1.0, .red)] {
            XCTAssertEqual(Derived.level(ratio: ratio, resetAt: nil, window: nil, threshold: nil, now: now), expected, "\(ratio)")
            // A window with a past reset is no window either.
            XCTAssertEqual(Derived.level(ratio: ratio, resetAt: now.addingTimeInterval(-1), window: Window.fiveHour, threshold: nil, now: now), expected, "\(ratio) past reset")
            XCTAssertEqual(Derived.level(ratio: ratio, resetAt: now.addingTimeInterval(60), window: nil, threshold: nil, now: now), expected, "\(ratio) no window length")
        }
    }

    func testRawLevelAndElapsedFraction() {
        XCTAssertEqual(Derived.rawLevel(0.69), .green)
        XCTAssertEqual(Derived.rawLevel(0.7), .yellow, "the TUI's no-window fallback: green / yellow / red")
        XCTAssertEqual(Derived.rawLevel(0.9), .red)
        XCTAssertEqual(Derived.rawLevel(0.5, warn: 0.4, critical: 0.6), .yellow)
        XCTAssertNil(Derived.elapsedFraction(resetAt: nil, window: Window.fiveHour, now: now))
        XCTAssertEqual(Derived.elapsedFraction(resetAt: now.addingTimeInterval(Window.fiveHour / 4), window: Window.fiveHour, now: now), 0.75)
        XCTAssertEqual(Derived.elapsedFraction(resetAt: now.addingTimeInterval(-1), window: Window.fiveHour, now: now), 1)
        XCTAssertNil(Derived.elapsedFraction(resetAt: now.addingTimeInterval(Window.fiveHour + 1), window: Window.fiveHour, now: now), "a reset beyond the window is not a window that has started")
    }

    // MARK: formatting

    func testFormatReset() {
        func f(_ seconds: TimeInterval) -> String { Derived.formatReset(now.addingTimeInterval(seconds), now: now) }
        XCTAssertEqual(f(45 * 60), "45m")
        XCTAssertEqual(f(3 * 3600 + 31 * 60), "3h31m")
        XCTAssertEqual(f(2 * 3600), "2h")
        XCTAssertEqual(f(3 * 86400 + 12 * 3600), "3d12h")
        XCTAssertEqual(f(3 * 86400), "3d")
        XCTAssertEqual(f(1), "1m", "rounds up to the next minute")
        XCTAssertEqual(f(0), "")
        XCTAssertEqual(f(-60), "")
        XCTAssertEqual(Derived.formatReset(nil, now: now), "")
    }

    func testFormatDuration() {
        XCTAssertEqual(Derived.formatDuration(45), "45s")
        XCTAssertEqual(Derived.formatDuration(90), "2m")
        XCTAssertEqual(Derived.formatDuration(3 * 3600), "3h")
        XCTAssertEqual(Derived.formatDuration(86400 + 2 * 3600), "1d2h")
        XCTAssertEqual(Derived.formatDuration(2 * 86400), "2d")
        XCTAssertEqual(Derived.formatDuration(3 * 3600 + 5 * 60), "3h5m")
        XCTAssertEqual(Derived.formatDuration(0), "1s")
        XCTAssertEqual(Derived.formatDuration(-1), "1s", "a tick that trails the poll reads as now")
        XCTAssertEqual(Derived.formatDuration(.nan), "-")
        XCTAssertEqual(Derived.formatDuration(.infinity), "-")
    }

    func testFormatResetLong() {
        let real = Date()
        let calendar = Calendar.current
        let in211m = real.addingTimeInterval(3 * 3600 + 31 * 60)
        XCTAssertEqual(Derived.formatResetLong(in211m, style: .countdown, now: real, calendar: calendar), "Resets in 3h 31m")
        let clock = Derived.formatResetLong(in211m, style: .clock, now: real, calendar: calendar)
        XCTAssertTrue(clock.hasPrefix("Resets "), clock)
        XCTAssertFalse(clock.contains("Resets in"), clock)
        XCTAssertTrue(clock.contains("Today") || clock.contains("Tomorrow"), clock)
        let both = Derived.formatResetLong(in211m, style: .both, now: real, calendar: calendar)
        XCTAssertTrue(both.hasPrefix("Resets in 3h 31m ("), both)
        XCTAssertTrue(both.hasSuffix(")"), both)
        XCTAssertTrue(both.contains("(Today") || both.contains("(Tomorrow"), both)

        // The same instant tomorrow is always "Tomorrow", whatever the hour now.
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: real)!
        XCTAssertTrue(Derived.formatResetLong(tomorrow, style: .clock, now: real, calendar: calendar).contains("Tomorrow"))
        // A reset later today, when the day has room for it.
        let soon = real.addingTimeInterval(60)
        if calendar.isDate(soon, inSameDayAs: real) {
            XCTAssertTrue(Derived.formatResetLong(soon, style: .clock, now: real, calendar: calendar).hasPrefix("Resets Today "))
            XCTAssertTrue(Derived.formatResetLong(soon, style: .both, now: real, calendar: calendar).contains("(Today "))
        }
        // Beyond tomorrow but within the week: a weekday; further: a month and day.
        let inThreeDays = real.addingTimeInterval(3 * 86400)
        let weekday = Derived.formatResetLong(inThreeDays, style: .clock, now: real, calendar: calendar)
        XCTAssertFalse(weekday.contains("Today") || weekday.contains("Tomorrow"), weekday)
        let inTenDays = Derived.formatResetLong(real.addingTimeInterval(10 * 86400), style: .clock, now: real, calendar: calendar)
        XCTAssertTrue(inTenDays.contains(","), inTenDays)

        XCTAssertEqual(Derived.formatResetLong(real.addingTimeInterval(30), style: .countdown, now: real), "Resets in under a minute")
        XCTAssertEqual(Derived.formatResetLong(real.addingTimeInterval(45 * 60), style: .countdown, now: real), "Resets in 45m")
        XCTAssertEqual(Derived.formatResetLong(real.addingTimeInterval(2 * 3600), style: .countdown, now: real), "Resets in 2h")
        XCTAssertEqual(Derived.formatResetLong(real.addingTimeInterval(3 * 86400 + 12 * 3600), style: .countdown, now: real), "Resets in 3d 12h")
        XCTAssertEqual(Derived.formatResetLong(real.addingTimeInterval(3 * 86400), style: .countdown, now: real), "Resets in 3d")
        XCTAssertEqual(Derived.formatResetLong(real.addingTimeInterval(-1), now: real), "Reset overdue")
        XCTAssertEqual(Derived.formatResetLong(nil, now: real), "")
    }

    func testFormatPercent() {
        XCTAssertEqual(Derived.formatPercent(1e300), "1000000%", "a hostile ratio is clamped, never trapped")
        XCTAssertEqual(Derived.formatPercent(-.infinity), "—")
        XCTAssertEqual(Derived.percentInt(1e300), 1_000_000)
        XCTAssertEqual(Derived.safeInt(1e300), 1_000_000_000_000_000)
        XCTAssertEqual(Derived.safeInt(.nan), 0)
        XCTAssertNil(Derived.usedFraction(remaining: 5, limit: 0))
        XCTAssertEqual(Derived.usedFraction(remaining: 25, limit: 100), 0.75)
        XCTAssertEqual(Derived.formatPercent(0.5), "50%")
        XCTAssertEqual(Derived.formatPercent(0.984), "98.4%")
        XCTAssertEqual(Derived.formatPercent(0.105), "10.5%")
        XCTAssertEqual(Derived.formatPercent(1), "100%")
        XCTAssertEqual(Derived.formatPercent(0), "0%")
        XCTAssertEqual(Derived.formatPercent(0.9999), "100%")
        XCTAssertEqual(Derived.formatPercent(nil), "—")
        XCTAssertEqual(Derived.formatPercent(.nan), "—")
    }

    func testPercentInt() {
        XCTAssertEqual(Derived.percentInt(0.005), 1)
        XCTAssertEqual(Derived.percentInt(0.995), 100)
        XCTAssertEqual(Derived.percentInt(0.42), 42)
        XCTAssertEqual(Derived.percentInt(0.004), 0)
        XCTAssertEqual(Derived.percentInt(1.5), 150)
    }

    func testTierBadge() throws {
        func tier(_ weight: Int?, seat: String? = nil) -> Tier {
            var t: [String: JSON] = [:]
            if let weight { t["weight"] = .number(Double(weight)) }
            if let seat { t["seatTier"] = .string(seat) }
            let q = try! QuotaSnapshot(json: .object(["accounts": .array([.object(["name": .string("x"), "tier": .object(t)])])]))
            return q.accounts[0].tier
        }
        XCTAssertEqual(Derived.tierBadge(tier(20)), "Max 20x")
        XCTAssertEqual(Derived.tierBadge(tier(5)), "Max 5x")
        XCTAssertEqual(Derived.tierBadge(tier(1)), "Pro")
        XCTAssertEqual(Derived.tierBadge(tier(nil)), "tier ?")
        XCTAssertEqual(Derived.tierBadge(nil), "tier ?")
        XCTAssertEqual(Derived.tierBadge(tier(20, seat: "team_premium")), "Team 20x")
        XCTAssertEqual(Derived.tierBadge(tier(5, seat: "Team")), "Team 5x")
        XCTAssertEqual(Derived.tierBadge(tier(1, seat: "team_standard")), "Team")
        XCTAssertEqual(Derived.tierBadge(tier(7)), "7x")
        XCTAssertEqual(Derived.tierBadge(tier(20, seat: "enterprise")), "Max 20x")
    }

    func testFormatSessions() {
        func sessions(_ obj: [String: JSON]) -> SessionsInfo {
            makeStatus(current: nil, accounts: [], extra: ["sessions": .object(obj)]).sessions!
        }
        let base: [String: JSON] = ["known": .number(9), "active": .number(2)]
        XCTAssertEqual(Derived.formatSessions(sessions(base.merging(["mode": .string("adaptive"), "distribute": .string("adaptive")]) { $1 })), "2 active / 9 known · adapting")
        XCTAssertEqual(Derived.formatSessions(sessions(base.merging(["distribute": .bool(true)]) { $1 })), "2 active / 9 known · distributing")
        XCTAssertEqual(Derived.formatSessions(sessions(base.merging(["distribute": .bool(false), "mode": .string("off"), "draining": .number(3)]) { $1 })), "2 active / 9 known · draining 3")
        XCTAssertEqual(Derived.formatSessions(sessions(base.merging(["distribute": .bool(false)]) { $1 })), "2 active / 9 known · single-account")
        XCTAssertEqual(Derived.formatSessions(sessions([:])), "0 active / 0 known · single-account")
    }

    func testFormatMoney() {
        XCTAssertEqual(Derived.formatMoney(minor: 123, currency: "USD", exponent: 2), "$1.23")
        XCTAssertEqual(Derived.formatMoney(minor: 123, currency: "usd", exponent: 2), "$1.23")
        XCTAssertEqual(Derived.formatMoney(minor: 12345, currency: "EUR", exponent: 2), "EUR 123.45")
        XCTAssertEqual(Derived.formatMoney(minor: 5, currency: "JPY", exponent: 0), "JPY 5.00")
        XCTAssertEqual(Derived.formatMoney(minor: 0, currency: "USD", exponent: 2), "$0.00")
    }

    // MARK: rows

    func testScopedWeeklyRows() {
        let far = ms(now.addingTimeInterval(86400))
        let s = makeStatus(current: "a", accounts: [accountJSON("a", extraQuota: [
            "unified7dFable": .number(0.88), "unified7dFableReset": far,
            "unified7dSonnet": .number(0.3), "unified7dSonnetReset": far,
            "scopedWeekly": .object(["fable": .object(["utilization": .number(0.5), "resetAt": far]), "opus": .object(["utilization": .number(0.1)])]),
        ])])
        let rows = Derived.scopedWeeklyRows(s.accounts[0].quota)
        XCTAssertEqual(rows.map(\.family), ["fable", "opus", "sonnet"], "sorted by family")
        XCTAssertEqual(rows.map(\.label), ["Fable", "Opus", "Sonnet"])
        XCTAssertEqual(rows[0].utilization, 0.5, "the scoped map wins over the dedicated field")
        XCTAssertEqual(rows[0].resetAt, now.addingTimeInterval(86400))
        XCTAssertEqual(rows[1].utilization, 0.1)
        XCTAssertNil(rows[1].resetAt)
        XCTAssertEqual(rows[2].utilization, 0.3, "a family with no scoped entry falls back to its dedicated field")

        let bare = makeStatus(current: "a", accounts: [accountJSON("a")])
        XCTAssertEqual(Derived.scopedWeeklyRows(bare.accounts[0].quota), [])
        let sonnetOnly = makeStatus(current: "a", accounts: [accountJSON("a", extraQuota: ["unified7dSonnet": .number(0.2)])])
        XCTAssertEqual(Derived.scopedWeeklyRows(sonnetOnly.accounts[0].quota).map(\.family), ["sonnet"])
    }

    private func routedStatus(defaultTarget: String?) -> StatusSnapshot {
        var extra: [String: JSON] = [
            "routes": .array([
                .object(["name": .string("fable"), "match": .array([.string("*fable*")]), "pinned": .string("alice"), "target": .string("bob"),
                         "color": .string("magenta"), "autocreated": .bool(false),
                         "accounts": .array([.object(["name": .string("alice"), "eligible": .bool(false)]), .object(["name": .string("bob"), "eligible": .bool(true)])])]),
                .object(["name": .string("haiku"), "match": .array([.string("*haiku*"), .string("*haiku-3*")]), "target": .string("alice"), "autocreated": .bool(true)]),
                .object(["name": .string("mixed"), "match": .array([.string("*haiku*"), .string("*sonnet*")]), "target": .string("alice"), "pinned": .string("alice")]),
            ]),
            "blockedModels": .array([.string("*haiku*"), .string("*haiku-3*")]),
        ]
        if let defaultTarget { extra["defaultTarget"] = .string(defaultTarget) }
        return makeStatus(current: "alice", accounts: [accountJSON("alice", unavailable: "quota"), accountJSON("bob"), accountJSON("carol")], extra: extra)
    }

    func testRouteRows() {
        let rows = Derived.routeRows(routedStatus(defaultTarget: "carol"))
        XCTAssertEqual(rows.count, 4)
        let fable = rows[0]
        XCTAssertEqual(fable.kind, .route)
        XCTAssertEqual(fable.name, "fable")
        XCTAssertEqual(fable.label, "Fable")
        XCTAssertEqual(fable.match, "*fable*")
        XCTAssertEqual(fable.target, "bob")
        XCTAssertEqual(fable.pinned, "alice")
        XCTAssertTrue(fable.pinMismatch, "pinned to alice, but the server routes to bob")
        XCTAssertFalse(fable.blocked)
        XCTAssertFalse(fable.autocreated)
        XCTAssertEqual(fable.eligible, ["bob"])
        XCTAssertEqual(fable.ineligible, ["alice"])
        XCTAssertEqual(fable.color, "magenta")
        XCTAssertNil(fable.current)
        XCTAssertNil(fable.currentUnavailable)

        let haiku = rows[1]
        XCTAssertEqual(haiku.match, "*haiku*, *haiku-3*")
        XCTAssertTrue(haiku.blocked, "every glob is blocked")
        XCTAssertFalse(haiku.pinMismatch)
        XCTAssertTrue(haiku.autocreated)
        XCTAssertNil(haiku.color)
        XCTAssertEqual(haiku.eligible, [])

        let mixed = rows[2]
        XCTAssertFalse(mixed.blocked, "one unblocked glob keeps the route alive")
        XCTAssertFalse(mixed.pinMismatch, "pinned and target agree")

        let def = rows[3]
        XCTAssertEqual(def.kind, .default)
        XCTAssertEqual(def.name, "")
        XCTAssertEqual(def.label, "Everything else")
        XCTAssertEqual(def.match, "")
        XCTAssertEqual(def.target, "carol", "the server's defaultTarget")
        XCTAssertEqual(def.current, "alice")
        XCTAssertEqual(def.currentUnavailable, "quota")
        XCTAssertFalse(def.blocked)
        XCTAssertNil(def.pinned)
    }

    func testRouteRowsDefaultFallsBackToCurrent() {
        let rows = Derived.routeRows(routedStatus(defaultTarget: nil))
        XCTAssertEqual(rows.last?.kind, .default)
        XCTAssertEqual(rows.last?.target, "alice")
        XCTAssertEqual(rows.last?.current, "alice")
    }

    func testRouteRowsEmptyWithoutRoutes() {
        XCTAssertEqual(Derived.routeRows(makeStatus(current: "alice", accounts: [accountJSON("alice")])), [])
        XCTAssertEqual(Derived.routeRows(makeStatus(current: "alice", accounts: [accountJSON("alice")], extra: ["routes": .array([]), "defaultTarget": .string("alice")])), [])
    }

    // MARK: problems

    private func item(id: String, starved: Int, active: Bool = true, client: String? = nil, project: String? = nil) -> JSON {
        var o: [String: JSON] = ["id": .string(id), "starved": .number(Double(starved)), "active": .bool(active)]
        o["client"] = client.map(JSON.string) ?? .null
        o["dimensions"] = project.map { .object(["project": .string($0)]) } ?? .null
        return .object(o)
    }

    func testProblemsForAccountsNeedingAPerson() {
        let s = makeStatus(current: "a", accounts: [accountJSON("alice", unavailable: "error"), accountJSON("bob", unavailable: "disabled"), accountJSON("carol", unavailable: "quota"), accountJSON("dave")])
        let p = Derived.problems(s)
        XCTAssertEqual(p.map(\.text), ["Account alice needs a re-login.", "Account bob is disabled."])
        XCTAssertEqual(p.map(\.severity), [.warn, .warn])
        XCTAssertEqual(p.map(\.kind), ["account", "account"])
        XCTAssertEqual(Derived.problems(makeStatus(current: nil, accounts: [accountJSON("a"), accountJSON("b", unavailable: "throttled")])), [])
    }

    func testProblemsForStarvedSessions() {
        let items: [JSON] = [
            item(id: "aaaaaaaa-1111", starved: 5),
            item(id: "bbbbbbbb-2222", starved: 7, client: "claude-code", project: "teamclaude"),
            item(id: "cccccccc-3333", starved: 3),
            item(id: "dddddddd-4444", starved: 9, client: "claude-code", project: "teamclaude"),
            item(id: "eeeeeeee-5555", starved: 6),
            item(id: "ffffffff-6666", starved: 8),
            item(id: "99999999-7777", starved: 50, active: false),
        ]
        let s = makeStatus(current: "a", accounts: [accountJSON("a"), accountJSON("b", unavailable: "quota")],
                           extra: ["sessions": .object(["known": .number(7), "active": .number(6), "items": .array(items), "starvedMax": .number(50)])])
        let p = Derived.problems(s)
        XCTAssertEqual(p.count, 4, "three listed plus the overflow row")
        XCTAssertEqual(p[0].kind, "starved-session")
        XCTAssertEqual(p[0].severity, .bad)
        XCTAssertEqual(p[0].text, "Session claude-code dddddddd has had 9 requests in a row come back with nothing (teamclaude) — it is failing, not idle.")
        XCTAssertEqual(p[1].text, "Session ffffffff has had 8 requests in a row come back with nothing — it is failing, not idle.")
        XCTAssertEqual(p[2].text, "Session claude-code bbbbbbbb has had 7 requests in a row come back with nothing (teamclaude) — it is failing, not idle.")
        XCTAssertEqual(p[3].kind, "starved-more")
        XCTAssertEqual(p[3].text, "and 2 more sessions are getting nothing back.")
    }

    func testProblemsStarvedMaxFallback() {
        let s = makeStatus(current: "a", accounts: [accountJSON("a")], extra: ["sessions": .object(["starvedMax": .number(6)])])
        XCTAssertEqual(Derived.problems(s).map(\.text), ["A session has had 6 requests in a row come back with nothing. Turn on proxy.sessionDetail to see which."])
        let below = makeStatus(current: "a", accounts: [accountJSON("a")], extra: ["sessions": .object(["starvedMax": .number(4)])])
        XCTAssertEqual(Derived.problems(below), [])
        // Items present but none starved enough: no fallback either, starvedMax notwithstanding.
        let quiet = makeStatus(current: "a", accounts: [accountJSON("a")],
                               extra: ["sessions": .object(["starvedMax": .number(9), "items": .array([item(id: "x", starved: 2)])])])
        XCTAssertEqual(Derived.problems(quiet).map(\.text), ["A session has had 9 requests in a row come back with nothing. Turn on proxy.sessionDetail to see which."])
    }

    func testProblemsWhyWhenEveryAccountIsStalled() {
        func why(_ codes: [String]) -> String {
            let s = makeStatus(current: "a", accounts: codes.enumerated().map { accountJSON("a\($0.offset)", unavailable: $0.element) },
                               extra: ["sessions": .object(["items": .array([item(id: "abcdefgh", starved: 5)])])])
            return Derived.problems(s)[0].text
        }
        XCTAssertTrue(why(["quota", "quota"]).hasSuffix(" — every account is over its quota threshold."))
        XCTAssertTrue(why(["throttled"]).hasSuffix(" — every account is in a rate-limit hold."))
        XCTAssertTrue(why(["quota", "throttled"]).hasSuffix(" — every account is over its quota threshold or in a rate-limit hold."))
        XCTAssertTrue(why(["quota", "error"]).hasSuffix(" — it is failing, not idle."), "an errored account is not a stall")
    }

    func testProblemsOrderWorstFirst() {
        let s = makeStatus(current: "a", accounts: [accountJSON("alice", unavailable: "error")],
                           extra: ["sessions": .object(["items": .array([item(id: "abcdefgh", starved: 5)])])])
        XCTAssertEqual(Derived.problems(s).map(\.kind), ["starved-session", "account"])
    }

    // MARK: switch outcome, hold

    func testSwitchOutcome() {
        func check(_ r: SwitchResult, _ kind: SwitchOutcome.Kind, _ text: String, line: UInt = #line) {
            let o = Derived.switchOutcome(r)
            XCTAssertEqual(o.kind, kind, line: line)
            XCTAssertEqual(o.text, text, line: line)
        }
        check(SwitchResult(ok: true, account: "bob", eligible: true), .ok, "switched to bob")
        check(SwitchResult(ok: true, account: "bob"), .ok, "switched to bob")
        check(SwitchResult(ok: true, account: "bob", eligible: false, reason: "no route allows this account"), .warn, "switched to bob, but rotation will not use it: no route allows this account")
        check(SwitchResult(ok: true, account: "bob", eligible: false), .warn, "switched to bob, but rotation will not use it")
        check(SwitchResult(ok: false, error: "no such account"), .error, "switch failed: no such account")
        check(SwitchResult(ok: false), .error, "switch failed")
        check(SwitchResult(ok: true), .ok, "switched to ")
    }

    func testIsHold() throws {
        XCTAssertTrue(Derived.isHold(try Fixtures.status("status-hold.json")))
        XCTAssertFalse(Derived.isHold(try Fixtures.status("status-two-accounts-b-quota.json")))
        XCTAssertFalse(Derived.isHold(try Fixtures.status("status-empty.json")), "no accounts is not a hold")
        XCTAssertFalse(Derived.isHold(try Fixtures.status("status-live-1.1.16.json")))
        XCTAssertFalse(Derived.isHold(try Fixtures.status("status-hostile.json")), "the second hostile account has no code, so it can serve")
        XCTAssertTrue(Derived.isHold(makeStatus(current: "a", accounts: [accountJSON("a", unavailable: "future-reason")])), "an unknown code still counts as out of rotation")
    }
}
