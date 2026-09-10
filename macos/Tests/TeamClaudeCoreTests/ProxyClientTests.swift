import Foundation
import XCTest
import TeamClaudeCore

/// Answers URLSession requests from an in-memory route table keyed "METHOD /path".
final class StubProtocol: URLProtocol {
    struct Reply { var status: Int; var body: Data; var headers: [String: String] = [:] }
    struct Seen {
        var method: String; var path: String; var headers: [String: String]; var body: Data?
        /// URLSession canonicalizes header names before a protocol sees them.
        func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    }

    nonisolated(unsafe) private static var routes: [String: Reply] = [:]
    nonisolated(unsafe) private static var seen: [Seen] = []
    private static let lock = NSLock()

    static func reset() { lock.lock(); routes = [:]; seen = []; lock.unlock() }
    static func route(_ key: String, _ reply: Reply) { lock.lock(); routes[key] = reply; lock.unlock() }
    static var requests: [Seen] { lock.lock(); defer { lock.unlock() }; return seen }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let key = "\(method) \(url.path)"
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            body = data
        }
        StubProtocol.lock.lock()
        StubProtocol.seen.append(Seen(method: method, path: url.path, headers: request.allHTTPHeaderFields ?? [:], body: body))
        let reply = StubProtocol.routes[key] ?? Reply(status: 404, body: Data())
        StubProtocol.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ProxyClientTests: XCTestCase {
    override func setUp() { StubProtocol.reset() }

    private func client(apiKey: String? = "tc-secret") -> ProxyClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ProxyClient(endpoint: ProxyEndpoint(host: "127.0.0.1", port: 3456, apiKey: apiKey), configuration: configuration)
    }

    private func json(_ s: String, status: Int = 200) -> StubProtocol.Reply {
        StubProtocol.Reply(status: status, body: Data(s.utf8), headers: ["Content-Type": "application/json"])
    }

    private func expectError(_ expected: ProxyError, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let e as ProxyError {
            XCTAssertEqual(e, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func testEndpoint() {
        let e = ProxyEndpoint(host: "127.0.0.1", port: 3456)
        XCTAssertEqual(e.baseURL.absoluteString, "http://127.0.0.1:3456")
        XCTAssertEqual(e.label, "127.0.0.1:3456")
        XCTAssertEqual(e.dashboardURL.absoluteString, "http://127.0.0.1:3456/teamclaude/dashboard")
        XCTAssertEqual(ProxyEndpoint(host: "::1", port: 4000).baseURL.absoluteString, "http://[::1]:4000", "an IPv6 literal from the config is bracketed")
        XCTAssertEqual(ProxyEndpoint(host: "[::1]", port: 4000).baseURL.absoluteString, "http://[::1]:4000")
        XCTAssertEqual(ProxyEndpoint(host: "not a host", port: 4000).baseURL.absoluteString, "http://127.0.0.1:3456", "a host that is not a URL falls back instead of trapping")
        XCTAssertTrue(ProxyEndpoint.isValid(host: "::1", port: 3456))
        XCTAssertTrue(ProxyEndpoint.isValid(host: "proxy.local", port: 65535))
        XCTAssertFalse(ProxyEndpoint.isValid(host: "not a host", port: 3456))
        XCTAssertFalse(ProxyEndpoint.isValid(host: "127.0.0.1", port: 0))
        XCTAssertFalse(ProxyEndpoint.isValid(host: "", port: 3456))
        XCTAssertNil(e.apiKey)
    }

    func testStatusDecodesAndSendsTheKey() async throws {
        StubProtocol.route("GET /teamclaude/status", StubProtocol.Reply(status: 200, body: Fixtures.data("status-live-1.1.16.json")))
        let s = try await client().status()
        XCTAssertEqual(s.currentAccount, "bob@example.com")
        XCTAssertEqual(s.accounts.count, 2)
        let req = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/teamclaude/status")
        XCTAssertEqual(req.header("x-api-key"), "tc-secret")
        XCTAssertEqual(req.header("accept"), "application/json")
        XCTAssertNil(req.body)
    }

    func testNoKeyMeansNoHeader() async throws {
        StubProtocol.route("GET /teamclaude/status", StubProtocol.Reply(status: 200, body: Fixtures.data("status-empty.json")))
        _ = try await client(apiKey: nil).status()
        XCTAssertNil(StubProtocol.requests.first?.header("x-api-key"))
        StubProtocol.reset()
        StubProtocol.route("GET /teamclaude/status", StubProtocol.Reply(status: 200, body: Fixtures.data("status-empty.json")))
        _ = try await client(apiKey: "").status()
        XCTAssertNil(StubProtocol.requests.first?.header("x-api-key"), "an empty key is not sent either")
    }

    func testUpdateEndpoint() async throws {
        let c = client(apiKey: nil)
        await c.update(endpoint: ProxyEndpoint(host: "127.0.0.1", port: 3456, apiKey: "tc-new"))
        StubProtocol.route("GET /teamclaude/quota", StubProtocol.Reply(status: 200, body: Fixtures.data("quota-live.json")))
        let q = try await c.quota()
        XCTAssertEqual(q.accounts.count, 2)
        XCTAssertEqual(StubProtocol.requests.first?.header("x-api-key"), "tc-new")
        let endpoint = await c.endpoint
        XCTAssertEqual(endpoint.apiKey, "tc-new")
    }

    func testUnauthorized() async {
        StubProtocol.route("GET /teamclaude/status", json(#"{"error":"unauthorized"}"#, status: 401))
        await expectError(.unauthorized) { _ = try await self.client().status() }
        StubProtocol.route("POST /teamclaude/switch", json(#"{"ok":false,"error":"unauthorized"}"#, status: 401))
        await expectError(.unauthorized) { _ = try await self.client().switchTo("bob") }
        XCTAssertEqual(ProxyError.unauthorized.message, "Proxy rejected the API key")
    }

    func testSomethingElseOnThePort() async {
        StubProtocol.route("GET /teamclaude/status", StubProtocol.Reply(status: 200, body: Data("<html>hello</html>".utf8), headers: ["Content-Type": "text/html"]))
        await expectError(.notTeamClaude(200)) { _ = try await self.client().status() }
        StubProtocol.route("GET /teamclaude/status", json(#"{"ok":true,"message":"not a status payload"}"#))
        await expectError(.notTeamClaude(200)) { _ = try await self.client().status() }
        StubProtocol.route("GET /teamclaude/quota", json(#"{"accounts":"nope"}"#))
        await expectError(.notTeamClaude(200)) { _ = try await self.client().quota() }
        StubProtocol.route("GET /teamclaude/status", StubProtocol.Reply(status: 500, body: Data("boom".utf8)))
        await expectError(.notTeamClaude(500)) { _ = try await self.client().status() }
        StubProtocol.reset()
        await expectError(.notTeamClaude(404)) { _ = try await self.client().quota() }
        XCTAssertEqual(ProxyError.notTeamClaude(502).message, "Something else is answering on the proxy port (HTTP 502)")
    }

    func testSwitchPostsJSONAndDecodesTheReply() async throws {
        StubProtocol.route("POST /teamclaude/switch", json(#"{"ok":true,"account":"bob","eligible":false,"reason":"no route allows this account"}"#))
        let r = try await client().switchTo("bob")
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.account, "bob")
        XCTAssertEqual(r.eligible, false)
        XCTAssertEqual(r.reason, "no route allows this account")
        XCTAssertNil(r.error)
        let req = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/teamclaude/switch")
        XCTAssertEqual(req.header("content-type"), "application/json")
        XCTAssertEqual(req.header("x-api-key"), "tc-secret")
        let body = try XCTUnwrap(req.body)
        XCTAssertEqual(try JSON.parse(body), .object(["account": .string("bob")]))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"account":"bob"}"#)
    }

    func testSwitchEligible() async throws {
        StubProtocol.route("POST /teamclaude/switch", json(#"{"ok":true,"account":"alice@example.com","eligible":true}"#))
        let r = try await client().switchTo("alice@example.com")
        XCTAssertEqual(r.eligible, true)
        XCTAssertNil(r.reason)
        XCTAssertEqual(Derived.switchOutcome(r).text, "switched to alice@example.com")
    }

    func testRejected() async {
        StubProtocol.route("POST /teamclaude/switch", json(#"{"ok":false,"error":"no such account"}"#, status: 404))
        await expectError(.rejected("no such account")) { _ = try await self.client().switchTo("nobody") }
        StubProtocol.route("POST /teamclaude/switch", json(#"{"ok":false,"error":"no such account"}"#, status: 200))
        await expectError(.rejected("no such account")) { _ = try await self.client().switchTo("nobody") }
        StubProtocol.route("POST /teamclaude/switch", json(#"{"ok":false}"#, status: 400))
        await expectError(.rejected("request refused")) { _ = try await self.client().switchTo("nobody") }
        XCTAssertEqual(ProxyError.rejected("why").message, "why")
    }

    func testUnsupportedOnOlderServers() async {
        StubProtocol.route("POST /teamclaude/reload", StubProtocol.Reply(status: 404, body: Data()))
        await expectError(.unsupported) { _ = try await self.client().reload() }
        StubProtocol.route("POST /teamclaude/reload", StubProtocol.Reply(status: 501, body: Data("Not Implemented".utf8)))
        await expectError(.unsupported) { _ = try await self.client().reload() }
        // Nothing routed at all → the stub's own 404.
        await expectError(.unsupported) { _ = try await self.client().switchTo("bob") }
    }

    func testBadReply() async {
        StubProtocol.route("POST /teamclaude/reload", StubProtocol.Reply(status: 500, body: Data("oops".utf8)))
        await expectError(.badReply("HTTP 500")) { _ = try await self.client().reload() }
        StubProtocol.route("POST /teamclaude/reload", json(#"{"added":1}"#))
        await expectError(.badReply("HTTP 200")) { _ = try await self.client().reload() }
    }

    func testReload() async throws {
        StubProtocol.route("POST /teamclaude/reload", json(#"{"ok":true,"added":2}"#))
        let r = try await client().reload()
        XCTAssertEqual(r, ReloadResult(ok: true, added: 2))
        let req = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(req.method, "POST")
        XCTAssertNil(req.body ?? (req.body?.isEmpty == true ? nil : req.body), "no body on reload")
        XCTAssertNil(req.header("content-type"))
    }

    func testTooLarge() async {
        StubProtocol.route("GET /teamclaude/status", StubProtocol.Reply(status: 200, body: Data(count: ProxyClient.maxReplyBytes + 1)))
        await expectError(.tooLarge) { _ = try await self.client().status() }
        StubProtocol.route("POST /teamclaude/switch", StubProtocol.Reply(status: 200, body: Data(count: ProxyClient.maxReplyBytes + 1)))
        await expectError(.tooLarge) { _ = try await self.client().switchTo("bob") }
    }

    func testExactlyTheLimitIsFine() async {
        var body = Data(#"{"accounts":[]}"#.utf8)
        body.append(Data(repeating: 0x20, count: ProxyClient.maxReplyBytes - body.count))
        StubProtocol.route("GET /teamclaude/status", StubProtocol.Reply(status: 200, body: body))
        do {
            let s = try await client().status()
            XCTAssertEqual(s.accounts, [])
        } catch {
            XCTFail("\(error)")
        }
    }

    func testUnreachable() async {
        // A closed port on loopback: no stub, the real transport.
        let c = ProxyClient(endpoint: ProxyEndpoint(host: "127.0.0.1", port: 1, apiKey: nil))
        do {
            _ = try await c.status()
            XCTFail("expected unreachable")
        } catch let e as ProxyError {
            guard case .unreachable = e else { return XCTFail("\(e)") }
            XCTAssertEqual(e.message, "Proxy is not running")
        } catch {
            XCTFail("\(error)")
        }
    }
}
