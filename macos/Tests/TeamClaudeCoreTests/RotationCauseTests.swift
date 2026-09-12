import XCTest
@testable import TeamClaudeCore

/// A rotation log entry keeps its cause as data, so it reads in whichever language is active when it is shown.
final class RotationCauseTests: XCTestCase {
    override func tearDown() { L10n.activate("en") }

    func testCauseRoundTripsThroughTheLog() throws {
        let at = Date(timeIntervalSince1970: 1_757_700_000)
        var log = RotationLog()
        log.append(RotationEvent(at: at, from: "alice", to: "bob", cause: .unavailable(code: "quota", resetAt: at.addingTimeInterval(3 * 3600)), manual: false))
        log.append(RotationEvent(at: at, from: "bob", to: "carol", cause: .outranked(newPriority: 0, oldPriority: 2), manual: false))
        log.append(RotationEvent(at: at, from: "carol", to: "alice", cause: .manual, manual: true))
        let decoded = try JSONDecoder().decode(RotationLog.self, from: try JSONEncoder().encode(log))
        XCTAssertEqual(decoded, log)
        XCTAssertEqual(decoded.events[0].reasonText, "alice: local switch threshold reached · resets in 3h")
        XCTAssertEqual(decoded.events[1].reasonText, "carol outranks bob (priority 0 < 2)")
        XCTAssertEqual(decoded.events[2].reasonText, "switched from the app")
    }

    func testReasonFollowsTheActiveLanguage() throws {
        _ = try XCTUnwrap(L10n.resourceBundle())
        let e = RotationEvent(at: Date(), from: "alice", to: "bob", cause: .expiryRouting, manual: false)
        L10n.activate("en")
        XCTAssertEqual(e.reasonText, "expiry routing preferred bob")
        L10n.activate("ko")
        XCTAssertEqual(e.reasonText, L("expiry routing preferred %@", "bob"))
        XCTAssertNotEqual(e.reasonText, "expiry routing preferred bob", "the Korean table has this key")
    }

    func testLegacyEntriesKeepTheirRecordedText() throws {
        let blob = #"{"events":[{"at":1757700000,"from":"alice","to":"bob","reason":"alice: upstream 429 hold","manual":false}]}"#
        let log = try JSONDecoder().decode(RotationLog.self, from: Data(blob.utf8))
        XCTAssertNil(log.events[0].cause)
        XCTAssertEqual(log.events[0].reasonText, "alice: upstream 429 hold")
    }

    func testCauseIsDerivedFromTheOldAccountFirst() throws {
        let before = try Fixtures.status("status-mixed-providers.json")
        let after = try Fixtures.status("status-mixed-providers-rotated.json")
        let cause = Derived.rotationCause(from: "carol@example.com", to: "dave@example.com", previous: before, status: after)
        XCTAssertEqual(cause, .unavailable(code: "quota", resetAt: after.account(named: "carol@example.com")?.quota.unified5hReset))
    }
}
