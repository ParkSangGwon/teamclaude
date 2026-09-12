import Foundation
import XCTest
import TeamClaudeCore

final class MenuBarStateTests: XCTestCase {
    /// Whole seconds, so the reset patched into the fixture survives the millisecond round-trip exactly.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    private var twoAccounts: StatusSnapshot!

    override func setUpWithError() throws {
        let far = ms(now.addingTimeInterval(2 * 3600))
        let json = Fixtures.json("status-two-accounts-b-quota.json")
            .patchingAccount(0) { $0["quota"] = $0["quota"]!.patched(["unified5hReset"], far) }
        twoAccounts = try StatusSnapshot(json: json)
    }

    private func inputs(status: StatusSnapshot? = nil, quota: QuotaSnapshot? = nil, reachable: Bool = true, age: TimeInterval? = 1,
                        pollInterval: TimeInterval = 30, rotatedAt: Date? = nil, rotatedTo: String? = nil,
                        pinCurrent: Bool = false, showRemaining: Bool = false) -> IconInputs {
        IconInputs(status: status ?? twoAccounts, quota: quota ?? makeQuota(fiveHour: 0.3, weekly: 0.4), reachable: reachable,
                   lastSuccessAt: age.map { now.addingTimeInterval(-$0) }, now: now, pollInterval: pollInterval,
                   rotatedAt: rotatedAt, rotatedTo: rotatedTo, pinCurrent: pinCurrent, showRemaining: showRemaining)
    }

    func testUnreachableWithOldDataIsProxyDown() {
        let m = MenuBarState.compute(inputs(reachable: false, age: 60))
        XCTAssertEqual(m.state, .proxyDown)
        XCTAssertEqual(m.label, "—")
        XCTAssertNil(m.fiveHour)
        XCTAssertNil(m.weekly)
        XCTAssertNil(m.tag)
        XCTAssertEqual(m.tooltip, "TeamClaude proxy not reachable · last data 1m ago")

        let never = MenuBarState.compute(inputs(reachable: false, age: nil))
        XCTAssertEqual(never.state, .proxyDown)
        XCTAssertEqual(never.tooltip, "TeamClaude proxy not reachable")
    }

    func testUnreachableBlipKeepsRecentData() {
        let m = MenuBarState.compute(inputs(reachable: false, age: 5))
        XCTAssertNotEqual(m.state, .proxyDown, "a single failed poll within 10 s keeps the last numbers")
        XCTAssertEqual(m.state, .normal)
    }

    func testNoStatusYetIsStartingNotDown() {
        let m = MenuBarState.compute(IconInputs(status: nil, quota: nil, reachable: true, lastSuccessAt: nil, now: now))
        XCTAssertEqual(m.state, .starting, "the first poll is in flight: not a failure yet")
        XCTAssertNil(m.label)
        XCTAssertEqual(m.tooltip, "TeamClaude: connecting to the proxy…")
        let down = MenuBarState.compute(IconInputs(status: nil, quota: nil, reachable: false, lastSuccessAt: nil, now: now))
        XCTAssertEqual(down.state, .proxyDown, "unreachable with nothing ever received is down")
    }

    func testEmptyAccounts() throws {
        let m = MenuBarState.compute(inputs(status: try Fixtures.status("status-empty.json")))
        XCTAssertEqual(m.state, .noAccounts)
        XCTAssertEqual(m.label, "5h 0%")
        XCTAssertEqual(m.fiveHour, 0)
        XCTAssertEqual(m.weekly, 0)
        XCTAssertTrue(m.tooltip.contains("No accounts configured"))
    }

    func testStaleAfterThreePollsOrNinetySeconds() {
        XCTAssertEqual(MenuBarState.compute(inputs(age: 91, pollInterval: 30)).state, .stale)
        XCTAssertEqual(MenuBarState.compute(inputs(age: 89, pollInterval: 30)).state, .normal)
        XCTAssertEqual(MenuBarState.compute(inputs(age: 91, pollInterval: 10)).state, .stale, "floor of 90 s")
        XCTAssertEqual(MenuBarState.compute(inputs(age: 179, pollInterval: 60)).state, .normal)
        XCTAssertEqual(MenuBarState.compute(inputs(age: 181, pollInterval: 60)).state, .stale)
        let m = MenuBarState.compute(inputs(age: 200, pollInterval: 30))
        XCTAssertTrue(m.tooltip.hasPrefix("Data is 4m old — the proxy answered slowly or not at all · "), m.tooltip)
        XCTAssertEqual(m.label, "5h 30%", "the bars keep showing the last numbers")
    }

    func testStaleOutranksCritical() {
        let m = MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.99), age: 500))
        XCTAssertEqual(m.state, .stale)
    }

    func testRotatingFlashWindow() {
        let m = MenuBarState.compute(inputs(rotatedAt: now.addingTimeInterval(-5), rotatedTo: "bob@example.com"))
        XCTAssertEqual(m.state, .rotating(to: "bob@example.com"))
        XCTAssertEqual(m.label, "→ bob")
        XCTAssertTrue(m.tooltip.hasPrefix("Rotated to bob@example.com · "))
        XCTAssertEqual(MenuBarState.compute(inputs(rotatedAt: now.addingTimeInterval(-7), rotatedTo: "bob@example.com")).state, .normal)
        XCTAssertEqual(MenuBarState.compute(inputs(rotatedAt: now.addingTimeInterval(-5), rotatedTo: nil)).state, .normal)
        // Rotating outranks critical for the flash, but stale wins over both.
        XCTAssertEqual(MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.99), rotatedAt: now, rotatedTo: "x")).state, .rotating(to: "x"))
        XCTAssertEqual(MenuBarState.compute(inputs(age: 500, rotatedAt: now, rotatedTo: "x")).state, .stale)
    }

    func testCriticalNearTheSwitchThreshold() {
        // threshold 0.98 → critical from 0.93 up.
        let critical = MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.93, weekly: 0.1)))
        XCTAssertEqual(critical.state, .critical)
        XCTAssertEqual(critical.label, "5h 93%!")
        XCTAssertTrue(critical.tooltip.hasPrefix("Critical: at the switch threshold · "))
        XCTAssertEqual(MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.1, weekly: 0.93))).state, .critical, "either bar")
        let warning = MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.92, weekly: 0.1)))
        XCTAssertEqual(warning.state, .warning)
        XCTAssertEqual(warning.label, "5h 92%")
        XCTAssertTrue(warning.tooltip.hasPrefix("Warning · "))
    }

    func testCriticalOnHold() throws {
        let hold = try Fixtures.status("status-hold.json")
        let m = MenuBarState.compute(inputs(status: hold, quota: makeQuota(fiveHour: 0.1, weekly: 0.1)))
        XCTAssertEqual(m.state, .critical)
        XCTAssertTrue(m.tooltip.hasPrefix("Critical: every account is out of rotation · "))
        XCTAssertTrue(m.tooltip.hasSuffix("0/2 accounts available"))
        XCTAssertEqual(m.label, "5h 10%!")
    }

    func testCriticalWhenCurrentAccountIsOverQuota() {
        let s = makeStatus(current: "bob", accounts: [accountJSON("alice", fiveHour: 0.1), accountJSON("bob", unavailable: "quota", fiveHour: 0.99)])
        let m = MenuBarState.compute(inputs(status: s, quota: makeQuota(fiveHour: 0.2, weekly: 0.2)))
        XCTAssertEqual(m.state, .critical)
        XCTAssertEqual(m.label, "5h 20%!")
        XCTAssertTrue(m.tooltip.hasPrefix("Critical: the current account cannot serve and nothing else can take over"), m.tooltip)
        // Rotation already moved on (a routing target other than the blocked current account): ordinary, not critical.
        let rotated = makeStatus(current: "bob", accounts: [accountJSON("alice", fiveHour: 0.1), accountJSON("bob", unavailable: "quota", fiveHour: 0.99)], extra: ["defaultTarget": .string("alice")])
        XCTAssertEqual(MenuBarState.compute(inputs(status: rotated, quota: makeQuota(fiveHour: 0.2, weekly: 0.2))).state, .normal)
    }

    func testWarningLevelIsConfigurable() {
        // Severity follows the bars' own colour rule (the TUI pace rule): without a window, 70/90 bands.
        XCTAssertEqual(MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.75))).state, .normal, "yellow (a little ahead) is not a warning")
        XCTAssertEqual(MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.91))).state, .warning)
        XCTAssertEqual(MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.94))).state, .critical, "within five points of the 98% threshold")
        // With a window, pace decides: 60% used with 90% of the 5-hour window elapsed is green.
        let lateReset = Date().addingTimeInterval(Window.fiveHour * 0.1)
        XCTAssertEqual(MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.6, nextResetAt: lateReset))).state, .normal)
        let earlyReset = Date().addingTimeInterval(Window.fiveHour * 0.9)
        XCTAssertEqual(MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.6, nextResetAt: earlyReset))).state, .warning, "60% used with 10% of the window gone runs far ahead of pace")
        XCTAssertEqual(MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.69))).state, .normal)
        XCTAssertEqual(MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.7))).state, .normal, "the yellow band starts at 70%")
        XCTAssertEqual(MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.9))).state, .warning, "the red band starts at 90%")
    }

    func testFleetSourceByDefault() {
        let m = MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.3, weekly: 0.4)))
        XCTAssertEqual(m.state, .normal)
        XCTAssertEqual(m.fiveHour, 0.3)
        XCTAssertEqual(m.weekly, 0.4)
        XCTAssertEqual(m.label, "5h 30%")
        XCTAssertNil(m.tag)
    }

    func testPinnedSourceUsesTheCurrentAccount() {
        let m = MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.3, weekly: 0.4), pinCurrent: true))
        XCTAssertEqual(m.fiveHour, 0.42)
        XCTAssertEqual(m.weekly, 0.61)
        XCTAssertEqual(m.label, "5h 42%")
        XCTAssertEqual(m.tag, "ali")
    }

    func testNoQuotaSnapshotFallsBackToTheCurrentAccount() {
        let m = MenuBarState.compute(IconInputs(status: twoAccounts, quota: nil, reachable: true, lastSuccessAt: now, now: now))
        XCTAssertEqual(m.fiveHour, 0.42)
        XCTAssertEqual(m.weekly, 0.61)
        XCTAssertEqual(m.tag, "ali")
    }

    func testPinnedWithoutCurrentAccountShowsNothing() {
        let s = makeStatus(current: nil, accounts: [accountJSON("alice", fiveHour: 0.5)])
        let m = MenuBarState.compute(IconInputs(status: s, quota: nil, reachable: true, lastSuccessAt: now, now: now, pinCurrent: true))
        XCTAssertEqual(m.state, .normal)
        XCTAssertNil(m.fiveHour)
        XCTAssertNil(m.label)
        XCTAssertNil(m.tag)
    }

    func testShowRemainingFlipsFills() {
        let m = MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.3, weekly: 0.4), showRemaining: true))
        XCTAssertEqual(try XCTUnwrap(m.fiveHour), 0.7, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(m.weekly), 0.6, accuracy: 1e-12)
        XCTAssertEqual(m.label, "5h 70%")
        let pinned = MenuBarState.compute(inputs(pinCurrent: true, showRemaining: true))
        XCTAssertEqual(try XCTUnwrap(pinned.fiveHour), 0.58, accuracy: 1e-12)
        XCTAssertEqual(pinned.label, "5h 58%")
        // Severity is judged on usage, not on the flipped fill.
        let critical = MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.95), showRemaining: true))
        XCTAssertEqual(critical.state, .critical)
        XCTAssertEqual(critical.label, "5h 5%!")
    }

    func testTooltipMentionsCurrentAccountAndAvailability() {
        let m = MenuBarState.compute(inputs(quota: makeQuota(fiveHour: 0.3, weekly: 0.4)))
        XCTAssertEqual(m.tooltip, "TeamClaude · current alice@example.com · 5h 30% · 7d 40% · Fable 88% · 5h resets in 2h · 1/2 accounts available")
        let pinned = MenuBarState.compute(inputs(pinCurrent: true))
        XCTAssertTrue(pinned.tooltip.contains("5h 42% · 7d 61%"), pinned.tooltip)
    }

    func testModelEqualityDrivesRedraw() {
        let a = MenuBarState.compute(inputs())
        let b = MenuBarState.compute(inputs())
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, MenuBarState.compute(inputs(showRemaining: true)))
    }

    func testShortName() {
        XCTAssertEqual(MenuBarState.shortName("alice@example.com"), "ali")
        XCTAssertEqual(MenuBarState.shortName("Bob Smith"), "bob")
        XCTAssertEqual(MenuBarState.shortName("x"), "x")
        XCTAssertEqual(MenuBarState.shortName("a-1@x"), "a1")
        XCTAssertEqual(MenuBarState.shortName("@only-domain"), "onl")
        XCTAssertEqual(MenuBarState.shortName(""), "")
    }
}
