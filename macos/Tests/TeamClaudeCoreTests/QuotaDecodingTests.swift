import Foundation
import XCTest
import TeamClaudeCore

final class QuotaDecodingTests: XCTestCase {
    func testLiveFixtureDecodes() throws {
        let q = try Fixtures.quota("quota-live.json")
        XCTAssertEqual(q.accounts.count, 2)
        let alice = try XCTUnwrap(q.account(named: "alice@example.com"))
        XCTAssertEqual(alice.type, "oauth")
        XCTAssertFalse(alice.disabled)
        XCTAssertEqual(alice.status, "active")
        XCTAssertEqual(alice.tier.rateLimitTier, "default_claude_max_20x")
        XCTAssertNil(alice.tier.seatTier)
        XCTAssertEqual(alice.tier.weight, 20)
        XCTAssertEqual(alice.buckets.count, 4)
        XCTAssertEqual(alice.buckets["fiveHour"]?.utilization, 0.06)
        XCTAssertEqual(alice.buckets["fiveHour"]?.remaining, 0.94)
        XCTAssertEqual(alice.buckets["fiveHour"]?.resetAt, Date(timeIntervalSince1970: 1788984600))
        XCTAssertEqual(alice.buckets["fiveHour"]?.source, "unified5h")
        XCTAssertEqual(alice.buckets["weeklySonnet"]?.source, "unified7d", "a family that fell back to the shared week says so")
        XCTAssertEqual(alice.buckets["weeklyFable"]?.source, "unified7dFable")
        XCTAssertNil(alice.buckets["weeklyFable"]?.limit)

        XCTAssertEqual(Set(q.aggregate.keys), ["fiveHour", "weeklyShared", "weeklySonnet", "weeklyFable"])
        let five = try XCTUnwrap(q.aggregate["fiveHour"])
        XCTAssertEqual(five.capacityWeight, 40)
        XCTAssertEqual(five.usedWeight, 4.2)
        XCTAssertEqual(five.remainingWeight, 35.8)
        XCTAssertEqual(five.utilization, 0.105)
        XCTAssertEqual(five.remaining, 0.895)
        XCTAssertEqual(five.knownAccounts, 2)
        XCTAssertEqual(five.nextResetAt, Date(timeIntervalSince1970: 1788970200))
        XCTAssertEqual(q.unknownTiers, [])
        XCTAssertEqual(q.warmup["enabled"].bool, false)
        XCTAssertEqual(q.warmup["mode"].string, "off")
        XCTAssertNil(q.account(named: "nobody"))
        XCTAssertNil(q.account(named: nil))
    }

    func testUnknownTierFixture() throws {
        let q = try Fixtures.quota("quota-unknown-tier.json")
        XCTAssertEqual(q.unknownTiers, ["carol@example.com"])
        XCTAssertTrue(q.aggregate.isEmpty, "no aggregate on the wire → empty, not a crash")
        let carol = try XCTUnwrap(q.account(named: "carol@example.com"))
        XCTAssertNil(carol.tier.weight)
        XCTAssertEqual(carol.tier.rateLimitTier, "default_claude_ultra_99x")
        XCTAssertEqual(Derived.tierBadge(carol.tier), "tier ?")
        XCTAssertEqual(Set(carol.buckets.keys), ["fiveHour", "weeklyShared", "weeklySonnet"], "a null bucket is absent")
        let five = try XCTUnwrap(carol.buckets["fiveHour"])
        XCTAssertNil(five.utilization)
        XCTAssertNil(five.remaining)
        XCTAssertNil(five.resetAt)
        XCTAssertNil(five.source)
        XCTAssertEqual(carol.buckets["weeklyShared"]?.source, "unified7d")

        let api = try XCTUnwrap(q.account(named: "api-fallback"))
        XCTAssertEqual(api.type, "apikey")
        XCTAssertTrue(api.disabled)
        XCTAssertNil(api.status)
        XCTAssertNil(api.tier.weight)
        XCTAssertNil(api.tier.rateLimitTier)
        XCTAssertEqual(api.buckets["tokens"]?.limit, 1_000_000)
        XCTAssertEqual(api.buckets["tokens"]?.remainingAmount, 750_000)
        XCTAssertEqual(api.buckets["tokens"]?.source, "tokens")
        XCTAssertEqual(q.warmup["intervalSeconds"].int, 600)
    }

    func testAggregateEntriesThatAreNotObjectsAreDropped() throws {
        let q = try QuotaSnapshot(json: .object([
            "accounts": .array([]),
            "aggregate": .object(["fiveHour": .null, "weeklyShared": .string("x"), "weeklyFable": .object(["utilization": .number(0.2)])]),
            "unknownTiers": .array([.string("not-an-object"), .object(["name": .string("dave")]), .object(["rateLimitTier": .string("x")])]),
        ]))
        XCTAssertEqual(Array(q.aggregate.keys), ["weeklyFable"])
        XCTAssertEqual(q.aggregate["weeklyFable"]?.utilization, 0.2)
        XCTAssertEqual(q.aggregate["weeklyFable"]?.capacityWeight, 0)
        XCTAssertEqual(q.aggregate["weeklyFable"]?.knownAccounts, 0)
        XCTAssertNil(q.aggregate["weeklyFable"]?.nextResetAt)
        XCTAssertEqual(q.unknownTiers, ["dave"])
        XCTAssertTrue(q.warmup.isNull)
    }

    func testAccountsMissingIsNotQuota() {
        for bad in [JSON.object([:]), .object(["accounts": .object([:])]), .object(["accounts": .null]), .object(["aggregate": .object([:])]), .string("x")] {
            XCTAssertThrowsError(try QuotaSnapshot(json: bad)) { error in
                XCTAssertEqual(error as? SnapshotError, .notQuota)
            }
        }
    }
}
