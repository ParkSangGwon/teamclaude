import XCTest
import Foundation
@testable import TeamClaudeCore

/// Spawns a real headless proxy from ../src with a throwaway config and drives the
/// read and write paths the app uses. Skipped when `node` is not on PATH.
final class LiveProxyIntegrationTests: XCTestCase {
    var server: Process?
    var tmp: URL!

    override func tearDown() {
        // Wait for the exit: the server still holds the port and writes its state file into `tmp` until then.
        if let server, server.isRunning {
            server.terminate()
            let deadline = Date().addingTimeInterval(5)
            while server.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if server.isRunning { kill(server.processIdentifier, SIGKILL); server.waitUntilExit() }
        }
        server = nil
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        super.tearDown()
    }

    static func findOnPath(_ name: String) -> URL? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = URL(fileURLWithPath: String(dir)).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: p.path) { return p }
        }
        return nil
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func closedPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        precondition(ok == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    func testAppPathsAgainstAHeadlessProxy() async throws {
        guard let node = Self.findOnPath("node") else { throw XCTSkip("node not on PATH") }
        let entry = Self.repoRoot.appending(path: "src/index.js")
        guard FileManager.default.fileExists(atPath: entry.path) else { throw XCTSkip("src/index.js not found at \(entry.path)") }

        tmp = FileManager.default.temporaryDirectory.appending(path: "tcbar-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let configPath = tmp.appending(path: "config.json")
        let port = Self.closedPort()
        let deadUpstream = Self.closedPort()
        let config: JSON = .object([
            "proxy": .object(["port": .number(Double(port)), "apiKey": .string("tc-it-key")]),
            "upstream": .string("http://127.0.0.1:\(deadUpstream)"),
            "upstreamProxy": .bool(false),
            "switchThreshold": .number(0.98),
            "accounts": .array([.object(["name": .string("api-test"), "type": .string("apikey"), "apiKey": .string("sk-ant-api03-test")])]),
        ])
        let file = ConfigFile(path: configPath)
        try file.write(config)

        var env = ProcessInfo.processInfo.environment
        env["TEAMCLAUDE_CONFIG"] = configPath.path
        env["TEAMCLAUDE_DISABLE_AUTOUPDATE"] = "1"
        let p = Process()
        p.executableURL = node
        p.arguments = [entry.path, "server", "--headless"]
        p.environment = env
        let log = FileHandle.nullDevice
        p.standardOutput = log
        p.standardError = log
        try p.run()
        server = p

        let client = ProxyClient(endpoint: ProxyEndpoint(host: "127.0.0.1", port: port, apiKey: "tc-it-key"))
        var status: StatusSnapshot?
        for _ in 0..<50 {
            if let s = try? await client.status() { status = s; break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let first = try XCTUnwrap(status, "proxy did not come up")
        XCTAssertEqual(first.accounts.map(\.name), ["api-test"])
        XCTAssertEqual(first.currentAccount, "api-test")
        XCTAssertEqual(first.switchThreshold, 0.98, accuracy: 1e-9)

        // /quota: an API-key account has no subscription tier.
        let quota = try await client.quota()
        XCTAssertEqual(quota.accounts.first?.name, "api-test")
        XCTAssertNil(quota.accounts.first?.tier.weight)

        // switch: recorded, and the reply says whether rotation follows it.
        let sw = try await client.switchTo("api-test")
        XCTAssertTrue(sw.ok)
        XCTAssertEqual(sw.account, "api-test")
        await XCTAssertThrowsErrorAsync(try await client.switchTo("nobody")) { error in
            guard case ProxyError.rejected = error else { return XCTFail("expected rejected, got \(error)") }
        }

        // Writes through SettingsOps: CLI verb, then a JSON edit, both followed by reload.
        let location = CLILocation(node: node, entry: entry, environment: ["TEAMCLAUDE_CONFIG": configPath.path], source: .manual)
        let runner = CLIRunner(location: location)
        let ops = SettingsOps(
            run: { args, stdin in try await runner.run(args, stdin: stdin, timeout: 30) },
            update: { mutate in try file.update(mutate) },
            reload: { try await client.reload() },
            serverVersion: nil
        )
        let t = try await ops.apply(.threshold(percent: 90))
        XCTAssertEqual(t.via, "cli")
        XCTAssertTrue(t.reloaded)
        XCTAssertEqual(try file.load().root["switchThreshold"].double, 0.9)
        let afterThreshold = try await client.status()
        XCTAssertEqual(afterThreshold.switchThreshold, 0.9, accuracy: 1e-9)

        let r = try await ops.apply(.routeAdd(name: "it-route", match: ["*zz-it*"], accounts: [], bucket: nil, color: "cyan"))
        XCTAssertEqual(r.via, "cli")
        let withRoute = try await client.status()
        XCTAssertTrue(withRoute.routes.contains { $0.name == "it-route" })
        _ = try await ops.apply(.routeRemove(name: "it-route"))
        let withoutRoute = try await client.status()
        XCTAssertFalse(withoutRoute.routes.contains { $0.name == "it-route" })

        // A live JSON-only key; sessionDetail keeps the spawned proxy away from the real ~/.claude transcripts.
        let j = try await ops.apply(.json(path: ["proxy", "sessionDetail"], value: .bool(true), applies: .live))
        XCTAssertEqual(j.via, "json")
        XCTAssertTrue(j.reloaded)
        XCTAssertEqual(try file.load().root["proxy"]["sessionDetail"].bool, true)
        XCTAssertEqual(try file.load().root["proxy"]["apiKey"].string, "tc-it-key", "the sibling key survives a nested patch")
        // The token-bearing row survived every write untouched.
        XCTAssertEqual(try file.load().root["accounts"][0]["apiKey"].string, "sk-ant-api03-test")

        let d = try await ops.apply(.enabled(account: "api-test", org: nil, enabled: false))
        XCTAssertEqual(d.via, "cli")
        let disabled = try await client.status()
        XCTAssertEqual(disabled.accounts.first?.disabled, true)
        _ = try await ops.apply(.enabled(account: "api-test", org: nil, enabled: true))
        let enabled = try await client.status()
        XCTAssertEqual(enabled.accounts.first?.disabled, false)
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ handler: (Error) -> Void = { _ in }, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
