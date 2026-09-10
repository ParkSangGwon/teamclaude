import Foundation
import XCTest
import TeamClaudeCore

final class SettingsOpsTests: XCTestCase {
    /// Records what the closures were asked to do; the config lives in memory.
    private final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        var runs: [[String]] = []
        var updates = 0
        var reloads = 0
        var config: JSON = Fixtures.json("config-full.json")
        var runResult: Result<CLIResult, Error> = .success(CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: false))
        var reloadResult: Result<ReloadResult, Error> = .success(ReloadResult(ok: true, added: 0))

        func ops(serverVersion: String? = nil) -> SettingsOps {
            SettingsOps(
                run: { args, _ in
                    let r: Result<CLIResult, Error> = self.lock.withLock { self.runs.append(args); return self.runResult }
                    return try r.get()
                },
                update: { mutate in
                    try self.lock.withLock {
                        self.updates += 1
                        var root = self.config
                        try mutate(&root)
                        self.config = root
                        return root
                    }
                },
                reload: {
                    let r: Result<ReloadResult, Error> = self.lock.withLock { self.reloads += 1; return self.reloadResult }
                    return try r.get()
                },
                serverVersion: serverVersion
            )
        }
    }

    private var fake: Fake!
    override func setUp() { fake = Fake() }

    func testCLIPathLeavesTheConfigAlone() async throws {
        let before = fake.config
        let outcome = try await fake.ops().apply(.threshold(percent: 90))
        XCTAssertEqual(outcome.via, "cli")
        XCTAssertEqual(fake.runs, [["threshold", "90"]])
        XCTAssertEqual(fake.updates, 0)
        XCTAssertEqual(fake.config, before)
        XCTAssertEqual(fake.reloads, 1)
        XCTAssertTrue(outcome.reloaded)
        XCTAssertFalse(outcome.restartRequired)
        XCTAssertNil(outcome.note)
        XCTAssertEqual(outcome.added, 0)
    }

    func testMissingCLIFallsBackToJSON() async throws {
        fake.runResult = .failure(CLIError.notFound)
        let outcome = try await fake.ops().apply(.threshold(percent: 90))
        XCTAssertEqual(outcome.via, "json")
        XCTAssertEqual(fake.runs.count, 1, "the CLI was tried first")
        XCTAssertEqual(fake.updates, 1)
        XCTAssertEqual(fake.config["switchThreshold"], .number(0.9))
        XCTAssertEqual(fake.reloads, 1)
        XCTAssertTrue(outcome.reloaded)
    }

    func testJSONOnlyChangesSkipTheCLI() async throws {
        let outcome = try await fake.ops().apply(.json(path: ["expiryRouting", "enabled"], value: .bool(true), applies: .live))
        XCTAssertEqual(outcome.via, "json")
        XCTAssertEqual(fake.runs, [])
        XCTAssertEqual(fake.config["expiryRouting"]["enabled"], .bool(true))
        XCTAssertEqual(fake.reloads, 1)
    }

    func testFailedCLIThrowsAndWritesNothing() async {
        let failed = CLIResult(exitCode: 1, stdout: "", stderr: "threshold must be between 1 and 100\n", timedOut: false)
        fake.runResult = .success(failed)
        let before = fake.config
        do {
            _ = try await fake.ops().apply(.threshold(percent: 900))
            XCTFail("expected CLIError.failed")
        } catch {
            XCTAssertEqual(error as? CLIError, .failed(failed))
            XCTAssertEqual((error as? CLIError)?.message, "threshold must be between 1 and 100")
        }
        XCTAssertEqual(fake.updates, 0)
        XCTAssertEqual(fake.config, before)
        XCTAssertEqual(fake.reloads, 0)
    }

    func testTimedOutCLIIsAFailure() async {
        fake.runResult = .success(CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: true))
        do {
            _ = try await fake.ops().apply(.probe(seconds: 300))
            XCTFail("expected CLIError.failed")
        } catch {
            XCTAssertEqual((error as? CLIError)?.message, "teamclaude timed out")
        }
        XCTAssertEqual(fake.reloads, 0)
    }

    func testOtherCLIErrorsPropagate() async {
        fake.runResult = .failure(CLIError.launch("EACCES"))
        do {
            _ = try await fake.ops().apply(.probe(seconds: 300))
            XCTFail("expected CLIError.launch")
        } catch {
            XCTAssertEqual(error as? CLIError, .launch("EACCES"))
        }
        XCTAssertEqual(fake.updates, 0)
        XCTAssertEqual(fake.reloads, 0)
    }

    func testJSONWriteErrorsPropagate() async {
        fake.runResult = .failure(CLIError.notFound)
        do {
            _ = try await fake.ops().apply(.priority(account: "nobody", org: nil, value: .first))
            XCTFail("expected SettingsError")
        } catch {
            XCTAssertEqual(error as? SettingsError, .noSuchAccount("nobody"))
        }
        XCTAssertEqual(fake.reloads, 0)
    }

    func testUnreachableReloadIsANoteNotAnError() async throws {
        fake.reloadResult = .failure(ProxyError.unreachable("connection refused"))
        let outcome = try await fake.ops().apply(.threshold(percent: 90))
        XCTAssertEqual(outcome.via, "cli")
        XCTAssertFalse(outcome.reloaded)
        XCTAssertEqual(outcome.note, "Saved to the config; it applies when the proxy starts")
        XCTAssertTrue(outcome.note?.contains("Saved") == true && outcome.note?.contains("applies") == true)

        fake.reloadResult = .failure(ProxyError.timedOut)
        let stalled = try await fake.ops().apply(.threshold(percent: 90))
        XCTAssertEqual(stalled.note, ProxyError.timedOut.message)
        XCTAssertFalse(stalled.reloaded)

        fake.reloadResult = .failure(SettingsError.invalid("boom"))
        let other = try await fake.ops().apply(.threshold(percent: 90))
        XCTAssertTrue(other.note?.hasPrefix("Saved to the config; reload failed: ") == true, other.note ?? "nil")
    }

    func testARunningProxyThatRefusesTheReloadIsNamedAsSuch() async throws {
        // 401/404/500 come from a proxy that is up; "applies when the proxy starts" would be a lie.
        for e in [ProxyError.unauthorized, .unsupported, .rejected("nope"), .notTeamClaude(500), .badReply("x")] {
            fake.reloadResult = .failure(e)
            let o = try await fake.ops().apply(.threshold(percent: 90))
            XCTAssertFalse(o.reloaded)
            XCTAssertEqual(o.note, e.message, "\(e)")
        }
    }

    func testReloadResultIsReported() async throws {
        fake.reloadResult = .success(ReloadResult(ok: true, added: 2))
        let outcome = try await fake.ops().apply(.removeAccount(name: "codex@example.com", org: nil))
        XCTAssertTrue(outcome.reloaded)
        XCTAssertEqual(outcome.added, 2)
        fake.reloadResult = .success(ReloadResult(ok: false, added: 0))
        let refused = try await fake.ops().apply(.threshold(percent: 90))
        XCTAssertFalse(refused.reloaded)
        XCTAssertNil(refused.note)
    }

    func testRestartRequired() async throws {
        let hold = try await fake.ops().apply(.json(path: ["holdSeconds"], value: .number(0), applies: .restart))
        XCTAssertTrue(hold.restartRequired)
        let removed = try await fake.ops().apply(.removeAccount(name: "codex@example.com", org: nil))
        XCTAssertTrue(removed.restartRequired)
        let threshold = try await fake.ops().apply(.threshold(percent: 90))
        XCTAssertFalse(threshold.restartRequired)
        let detail = try await fake.ops().apply(.json(path: ["proxy", "sessionDetail"], value: .bool(true), applies: .live))
        XCTAssertFalse(detail.restartRequired)
        let gated = SettingChange.json(path: ["blockedModels"], value: .array([]), applies: .liveSince("1.1.19"))
        let older = try await fake.ops(serverVersion: "1.1.18").apply(gated)
        XCTAssertTrue(older.restartRequired)
        let unknownVersion = try await fake.ops(serverVersion: nil).apply(gated)
        XCTAssertTrue(unknownVersion.restartRequired)
        let fixed = try await fake.ops(serverVersion: "1.1.19").apply(gated)
        XCTAssertFalse(fixed.restartRequired)
        let checkout = try await fake.ops(serverVersion: "unknown").apply(gated)
        XCTAssertFalse(checkout.restartRequired)
    }

    // MARK: validation

    func testUpstreamProxyValidation() {
        XCTAssertNil(SettingsValidation.upstreamProxy("host:3128"))
        XCTAssertNil(SettingsValidation.upstreamProxy("http://u:p@h:3128"))
        XCTAssertNil(SettingsValidation.upstreamProxy("http://proxy.corp.example:3128"))
        XCTAssertNil(SettingsValidation.upstreamProxy("HTTP://proxy.corp.example"))
        XCTAssertNil(SettingsValidation.upstreamProxy("  "), "empty means direct")
        XCTAssertNil(SettingsValidation.upstreamProxy(""))
        XCTAssertEqual(SettingsValidation.upstreamProxy("socks5://x"), "Only http:// proxies are supported")
        XCTAssertEqual(SettingsValidation.upstreamProxy("https://x"), "Only http:// proxies are supported")
        XCTAssertNotNil(SettingsValidation.upstreamProxy("http://"), "no host")
        XCTAssertNotNil(SettingsValidation.upstreamProxy("http://host:70000"), "port out of range")
        XCTAssertNotNil(SettingsValidation.upstreamProxy("host:70000"))
        XCTAssertNotNil(SettingsValidation.upstreamProxy("http://host:0"))
    }

    func testTimeAndTimezoneValidation() {
        XCTAssertNil(SettingsValidation.timeHHMM("15:30"))
        XCTAssertNil(SettingsValidation.timeHHMM("00:00"))
        XCTAssertNil(SettingsValidation.timeHHMM("23:59"))
        XCTAssertNil(SettingsValidation.timeHHMM("9:05"), "a single-digit hour is still HH:MM to Int()")
        XCTAssertEqual(SettingsValidation.timeHHMM("24:00"), "Time must be HH:MM")
        XCTAssertEqual(SettingsValidation.timeHHMM("12:60"), "Time must be HH:MM")
        XCTAssertEqual(SettingsValidation.timeHHMM("15:30:00"), "Time must be HH:MM")
        XCTAssertEqual(SettingsValidation.timeHHMM("noon"), "Time must be HH:MM")
        XCTAssertEqual(SettingsValidation.timeHHMM(""), "Time must be HH:MM")
        XCTAssertNil(SettingsValidation.timezone("Europe/Moscow"))
        XCTAssertNil(SettingsValidation.timezone("UTC"))
        XCTAssertEqual(SettingsValidation.timezone("Mars/Olympus"), "Not an IANA time zone")
        XCTAssertEqual(SettingsValidation.timezone(""), "Not an IANA time zone")
        XCTAssertTrue(SettingsValidation.reservedDimensionHeaders.contains("x-api-key"))
    }
}
