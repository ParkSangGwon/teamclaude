import Foundation
import XCTest
@testable import TeamClaudeCore

/// The hand-written HTTP client is the transport the app actually uses, so the
/// wire cases run through it: a real loopback listener answers each request with
/// canned bytes, including the shapes a hostile or foreign server could send.
final class SocketHTTPTests: XCTestCase {
    // MARK: parsing

    func testDechunk() throws {
        XCTAssertEqual(try SocketHTTP.dechunk(Data("5\r\nhello\r\n0\r\n\r\n".utf8)), Data("hello".utf8))
        XCTAssertEqual(try SocketHTTP.dechunk(Data("5;ext=1\r\nhello\r\n1\r\n!\r\n0\r\n\r\n".utf8)), Data("hello!".utf8), "a chunk extension is ignored")
        XCTAssertEqual(try SocketHTTP.dechunk(Data("5\r\nhel".utf8)), Data("hel".utf8), "a truncated last chunk yields what arrived")
        XCTAssertThrowsError(try SocketHTTP.dechunk(Data("-5\r\nhello\r\n0\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? SocketHTTP.Failure, .malformed("chunk size"), "a negative size must not trap the slice")
        }
        XCTAssertThrowsError(try SocketHTTP.dechunk(Data("zz\r\nhello\r\n".utf8)))
        XCTAssertThrowsError(try SocketHTTP.dechunk(Data("5 hello".utf8)))
    }

    func testParseHeadersAndBody() throws {
        let r = try SocketHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}extra".utf8), maxBody: 1024)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.headers["content-type"], "application/json")
        XCTAssertEqual(r.body, Data("{}".utf8), "bytes past Content-Length are dropped")
        let chunked = try SocketHTTP.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n".utf8), maxBody: 1024)
        XCTAssertEqual(chunked.body, Data("{}".utf8))
        XCTAssertThrowsError(try SocketHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n{}".utf8), maxBody: 1024)) {
            XCTAssertEqual($0 as? SocketHTTP.Failure, .malformed("content-length"))
        }
        XCTAssertThrowsError(try SocketHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 2".utf8), maxBody: 1024)) {
            XCTAssertEqual($0 as? SocketHTTP.Failure, .malformed("no header terminator"))
        }
        XCTAssertThrowsError(try SocketHTTP.parse(Data("garbage\r\n\r\n".utf8), maxBody: 1024)) {
            XCTAssertEqual($0 as? SocketHTTP.Failure, .malformed("bad status line"))
        }
        let oversized = "HTTP/1.1 200 OK\r\n\r\n" + String(repeating: "x", count: 20)
        XCTAssertThrowsError(try SocketHTTP.parse(Data(oversized.utf8), maxBody: 10)) {
            XCTAssertEqual($0 as? SocketHTTP.Failure, .tooLarge)
        }
    }

    func testHeaderValuesCannotInjectLines() {
        XCTAssertEqual(SocketHTTP.sanitizeHeader("tc-key\r\nX-Injected: 1"), "tc-keyX-Injected: 1")
    }

    // MARK: over a real socket

    /// Accepts one connection, reads the request head, writes `reply`, and closes (or hangs when `reply` is nil).
    final class LoopbackServer: @unchecked Sendable {
        final class RequestBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored = ""
            var text: String {
                get { lock.lock(); defer { lock.unlock() }; return stored }
                set { lock.lock(); stored = newValue; lock.unlock() }
            }
        }

        let port: Int
        private let fd: Int32
        private let box = RequestBox()

        init(reply: String?, closeAfterReply: Bool = true) {
            let listening = socket(AF_INET, SOCK_STREAM, 0)
            var one: Int32 = 1
            setsockopt(listening, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listening, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            precondition(bound == 0)
            precondition(listen(listening, 4) == 0)
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(listening, $0, &len) } }
            fd = listening
            port = Int(UInt16(bigEndian: addr.sin_port))
            let box = self.box
            let thread = Thread {
                let client = accept(listening, nil, nil)
                guard client >= 0 else { return }
                var buf = [UInt8](repeating: 0, count: 8192)
                var got = Data()
                while got.range(of: Data("\r\n\r\n".utf8)) == nil {
                    let n = recv(client, &buf, buf.count, 0)
                    if n <= 0 { break }
                    got.append(buf, count: n)
                    if got.count > 65536 { break }
                }
                box.text = String(decoding: got, as: UTF8.self)
                if let reply {
                    _ = reply.withCString { send(client, $0, strlen($0), 0) }
                    if !closeAfterReply { Thread.sleep(forTimeInterval: 30) }
                } else {
                    Thread.sleep(forTimeInterval: 30)
                }
                close(client)
            }
            thread.start()
        }

        var receivedRequest: String { box.text }

        deinit { close(fd) }
    }

    private func client(_ server: LoopbackServer, key: String? = "tc-test") -> ProxyClient {
        ProxyClient(endpoint: ProxyEndpoint(host: "127.0.0.1", port: server.port, apiKey: key))
    }

    func testStatusOverChunkedSocketReplySendsTheKey() async throws {
        let body = String(decoding: Fixtures.data("status-empty.json"), as: UTF8.self)
        let srv = LoopbackServer(reply: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n\(String(body.utf8.count, radix: 16))\r\n\(body)\r\n0\r\n\r\n")
        let s = try await client(srv).status()
        XCTAssertEqual(s.accounts, [])
        XCTAssertTrue(srv.receivedRequest.hasPrefix("GET /teamclaude/status HTTP/1.1\r\n"))
        XCTAssertTrue(srv.receivedRequest.lowercased().contains("x-api-key: tc-test\r\n"))
        XCTAssertTrue(srv.receivedRequest.contains("Connection: close\r\n"))
    }

    func testContentLengthReplyReturnsWithoutWaitingForClose() async throws {
        let body = "{\"ok\":true,\"added\":1}"
        let srv = LoopbackServer(reply: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)", closeAfterReply: false)
        let started = Date()
        let r = try await client(srv).reload()
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.added, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a keep-alive server must not turn a complete reply into a timeout")
    }

    func testStatusCodesMapToProxyErrors() async throws {
        let unauthorized = LoopbackServer(reply: "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")
        await XCTAssertThrowsErrorAsync(try await client(unauthorized).status()) { XCTAssertEqual($0 as? ProxyError, .unauthorized) }

        let refusal = "{\"ok\":false,\"error\":\"not eligible\"}"
        let refused = LoopbackServer(reply: "HTTP/1.1 409 Conflict\r\nContent-Length: \(refusal.utf8.count)\r\n\r\n\(refusal)")
        await XCTAssertThrowsErrorAsync(try await client(refused).switchTo("bob")) { XCTAssertEqual($0 as? ProxyError, .rejected("not eligible")) }

        let older = LoopbackServer(reply: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        await XCTAssertThrowsErrorAsync(try await client(older).reload()) { XCTAssertEqual($0 as? ProxyError, .unsupported) }

        let foreign = LoopbackServer(reply: "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
        await XCTAssertThrowsErrorAsync(try await client(foreign).status()) { XCTAssertEqual($0 as? ProxyError, .notTeamClaude(200)) }

        let broken = LoopbackServer(reply: "not http at all\r\n")
        await XCTAssertThrowsErrorAsync(try await client(broken).status()) {
            guard case .badReply = $0 as? ProxyError else { return XCTFail("\($0)") }
        }
    }

    func testOversizedReplyIsRejected() async throws {
        let big = String(repeating: "x", count: ProxyClient.maxReplyBytes + 100)
        let srv = LoopbackServer(reply: "HTTP/1.1 200 OK\r\nContent-Length: \(big.utf8.count)\r\n\r\n\(big)")
        await XCTAssertThrowsErrorAsync(try await client(srv).status()) { XCTAssertEqual($0 as? ProxyError, .tooLarge) }
    }

    func testSilentListenerTimesOutWithinTheRequestDeadline() async throws {
        let srv = LoopbackServer(reply: nil)
        let started = Date()
        await XCTAssertThrowsErrorAsync(try await client(srv).reload()) { XCTAssertEqual($0 as? ProxyError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 25)
    }
}
