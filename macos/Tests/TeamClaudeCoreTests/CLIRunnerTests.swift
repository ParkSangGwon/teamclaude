import Foundation
import XCTest
import TeamClaudeCore

final class CLIRunnerTests: XCTestCase {
    private let sh = URL(fileURLWithPath: "/bin/sh")
    private let env = ["PATH": "/usr/bin:/bin"]

    private func run(_ script: String, stdin: String? = nil, timeout: TimeInterval = 30, onLine: (@Sendable (OutputLine) -> Void)? = nil) async throws -> CLIResult {
        try await CLIRunner.execute(executable: sh, arguments: ["-c", script], environment: env, stdin: stdin, timeout: timeout, onLine: onLine)
    }

    func testExitCodeAndCapture() async throws {
        let r = try await run("echo out; echo err 1>&2; exit 3")
        XCTAssertEqual(r.exitCode, 3)
        XCTAssertEqual(r.stdout, "out\n")
        XCTAssertEqual(r.stderr, "err\n")
        XCTAssertFalse(r.timedOut)
        XCTAssertFalse(r.succeeded)
        XCTAssertEqual(r.failureMessage, "err")

        let ok = try await run("printf ok")
        XCTAssertEqual(ok.exitCode, 0)
        XCTAssertEqual(ok.stdout, "ok")
        XCTAssertEqual(ok.stderr, "")
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.failureMessage, "exit code 0")
    }

    func testInterleavedStderr() async throws {
        let lines = Collected<OutputLine>()
        let r = try await run("echo a; echo b 1>&2; echo c; echo d 1>&2") { lines.append($0) }
        XCTAssertEqual(r.stdout, "a\nc\n")
        XCTAssertEqual(r.stderr, "b\nd\n")
        let seen = lines.values
        XCTAssertEqual(seen.filter { if case .out = $0 { return true } else { return false } }.map(\.text), ["a", "c"])
        XCTAssertEqual(seen.filter { if case .err = $0 { return true } else { return false } }.map(\.text), ["b", "d"])
    }

    func testStdinIsFedOnceAndClosed() async throws {
        let r = try await run("cat", stdin: "hello")
        XCTAssertEqual(r.stdout, "hello\n", "a newline is appended so a prompt reads the answer")
        XCTAssertEqual(r.exitCode, 0)
        let none = try await run("cat")
        XCTAssertEqual(none.stdout, "", "no stdin: the pipe is closed at once, so cat sees EOF instead of hanging")
    }

    func testStreamedLinesArriveInOrderWithTrailingPartial() async throws {
        let lines = Collected<OutputLine>()
        let r = try await run("printf 'one\\ntwo\\nthree'") { lines.append($0) }
        XCTAssertEqual(r.stdout, "one\ntwo\nthree")
        XCTAssertEqual(lines.values, [.out("one"), .out("two"), .out("three")])
        let empty = Collected<OutputLine>()
        _ = try await run("printf ''") { empty.append($0) }
        XCTAssertEqual(empty.values, [])
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        // Well past the 64 KiB pipe buffer on both channels.
        let r = try await run("i=0; while [ $i -lt 3000 ]; do echo 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; echo 'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy' 1>&2; i=$((i+1)); done")
        XCTAssertEqual(r.stdout.utf8.count, 3000 * 41)
        XCTAssertEqual(r.stderr.utf8.count, 3000 * 41)
        XCTAssertEqual(r.exitCode, 0)
    }

    func testTimeoutKillsTheChild() async throws {
        let started = Date()
        let r = try await CLIRunner.execute(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: env, timeout: 0.5)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(r.timedOut)
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertFalse(r.succeeded)
        XCTAssertEqual(r.failureMessage, "timed out")
        XCTAssertEqual(CLIError.failed(r).message, "teamclaude timed out")
        XCTAssertLessThan(elapsed, 3, "SIGTERM lands well before the sleep would end")
    }

    func testCancellationKillsTheChild() async throws {
        let started = Date()
        let env = self.env
        let sh = self.sh
        let ready = expectation(description: "child started")
        let task = Task {
            try await CLIRunner.execute(executable: sh, arguments: ["-c", "echo started; sleep 5"], environment: env, timeout: 30) { line in
                if line == .out("started") { ready.fulfill() }
            }
        }
        await fulfillment(of: [ready], timeout: 5)
        task.cancel()
        let r = try await task.value
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertFalse(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testStdinToAChildThatExitedFirstDoesNotKillUs() async throws {
        // Larger than the pipe buffer, to a child that never reads: EPIPE must be a non-event, not SIGPIPE.
        let big = String(repeating: "x", count: 200_000)
        let r = try await run("exit 0", stdin: big)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertFalse(r.timedOut)
        let late = try await run("sleep 0.2; exit 4", stdin: "ignored")
        XCTAssertEqual(late.exitCode, 4)
    }

    func testStdinWriterFeedsALineAfterLaunch() async throws {
        let writer = StdinWriter()
        let sh = self.sh, env = self.env
        let prompted = expectation(description: "prompt printed")
        let task = Task {
            try await CLIRunner.execute(executable: sh, arguments: ["-c", "echo prompt; read code; echo got:$code"], environment: env,
                                        stdinWriter: writer, timeout: 10) { line in
                if line == .out("prompt") { prompted.fulfill() }
            }
        }
        await fulfillment(of: [prompted], timeout: 5)
        writer.send("abc123")
        writer.close()
        let r = try await task.value
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout, "prompt\ngot:abc123\n")
        writer.send("after close is harmless")
    }

    func testStreamedLinesStayOrderedUnderLoad() async throws {
        let lines = Collected<OutputLine>()
        let r = try await run("i=1; while [ $i -le 2000 ]; do echo $i; echo e$i 1>&2; i=$((i+1)); done") { lines.append($0) }
        XCTAssertEqual(r.stdout, (1...2000).map(String.init).joined(separator: "\n") + "\n")
        XCTAssertEqual(lines.values.compactMap { if case .out(let s) = $0 { return s } else { return nil } }, (1...2000).map(String.init))
        XCTAssertEqual(lines.values.compactMap { if case .err(let s) = $0 { return s } else { return nil } }, (1...2000).map { "e\($0)" })
    }

    func testDrainGivesUpAtTheDeadlineWhenAGrandchildHoldsThePipe() async throws {
        // `sleep` inherits stdout and outlives the shell: an unbounded read would wait 30 s for it.
        let started = Date()
        let r = try await run("echo first; sleep 30 & exit 0", timeout: 10)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout, "first\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testLaunchFailure() async {
        do {
            _ = try await CLIRunner.execute(executable: URL(fileURLWithPath: "/nonexistent/teamclaude"), arguments: [], environment: env)
            XCTFail("expected a launch error")
        } catch let e as CLIError {
            guard case .launch(let why) = e else { return XCTFail("\(e)") }
            XCTAssertFalse(why.isEmpty)
            XCTAssertTrue(e.message.hasPrefix("Could not start teamclaude: "))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testEnvironmentForLocation() {
        let loc = CLILocation(node: URL(fileURLWithPath: "/usr/local/bin/node"), entry: URL(fileURLWithPath: "/usr/local/bin/teamclaude"),
                              environment: ["PATH": "/custom/bin", "TEAMCLAUDE_CONFIG": "/x.json"], source: .launchAgent)
        let env = CLIRunner.environment(for: loc)
        XCTAssertEqual(env["TEAMCLAUDE_DISABLE_AUTOUPDATE"], "1")
        XCTAssertEqual(env["NO_COLOR"], "1")
        XCTAssertEqual(env["TERM"], "dumb")
        XCTAssertEqual(env["PATH"], "/custom/bin", "the location's PATH overrides the app's")
        XCTAssertEqual(env["TEAMCLAUDE_CONFIG"], "/x.json")
        XCTAssertEqual(env["HOME"], ProcessInfo.processInfo.environment["HOME"], "the rest of the process environment is inherited")

        let bare = CLIRunner.environment(for: CLILocation(node: nil, entry: URL(fileURLWithPath: "/x"), environment: [:], source: .manual))
        XCTAssertNotNil(bare["PATH"])
        XCTAssertEqual(bare["TEAMCLAUDE_DISABLE_AUTOUPDATE"], "1")
    }

    func testRunnerWithoutLocationThrowsNotFound() async {
        do {
            _ = try await CLIRunner(location: nil).run(["status"])
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? CLIError, .notFound)
            XCTAssertEqual(CLIError.notFound.message, "teamclaude CLI not found — set its path in Settings → Proxy")
        }
    }

    func testRunnerPrependsEntryForNodeLocations() async throws {
        // `node` here is /bin/sh, `entry` is a script it runs: the runner must pass entry first, then the args.
        let dir = FileManager.default.temporaryDirectory.appending(path: "tc-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = dir.appending(path: "entry.sh")
        try Data("echo \"$1 $2 $TEAMCLAUDE_DISABLE_AUTOUPDATE $NO_COLOR $TEAMCLAUDE_CONFIG\"\n".utf8).write(to: entry)
        let loc = CLILocation(node: sh, entry: entry, environment: ["TEAMCLAUDE_CONFIG": "/cfg.json"], source: .launchAgent)
        let r = try await CLIRunner(location: loc).run(["threshold", "90"])
        XCTAssertEqual(r.stdout, "threshold 90 1 1 /cfg.json\n")
        XCTAssertTrue(r.succeeded)
    }

    func testFailureMessageTakesTheLastThreeLines() {
        let r = CLIResult(exitCode: 1, stdout: "", stderr: "a\n\n  b  \nc\nd\n", timedOut: false)
        XCTAssertEqual(r.failureMessage, "b c d")
        XCTAssertEqual(CLIError.failed(r).message, "b c d")
        XCTAssertEqual(CLIResult(exitCode: 2, stdout: "", stderr: "\n  \n", timedOut: false).failureMessage, "exit code 2")
        XCTAssertEqual(CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: true).succeeded, false)
    }
}
