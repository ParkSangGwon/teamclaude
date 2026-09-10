import Foundation

/// A minimal HTTP/1.1 client over BSD sockets for the loopback control plane.
///
/// CFNetwork's user-space networking path was observed stalling in SYN_SENT
/// against a long-running proxy that curl, the CLI (Node) and every other
/// BSD-socket client reached instantly. The app talks to one local server with
/// small JSON replies, so a plain socket per request — the same thing the CLI
/// does — is both simpler and more predictable than URLSession here.
public enum SocketHTTP {
    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data
    }

    public enum Failure: Error, Sendable, Equatable {
        case refused
        case timedOut
        case io(String)
        case malformed(String)
        case tooLarge
    }

    public static func request(host: String, port: Int, method: String, path: String, headers: [String: String] = [:],
                               body: Data? = nil, timeout: TimeInterval = 5, maxBody: Int = 1024 * 1024) throws -> Response {
        let fd = try connect(host: host, port: port, timeout: timeout)
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\nAccept: application/json\r\n"
        // A CR or LF inside a header value would let a config string inject its own header line.
        for (k, v) in headers { head += "\(sanitizeHeader(k)): \(sanitizeHeader(v))\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        try sendAll(fd, out)

        let raw = try readAll(fd, max: maxBody + 64 * 1024, deadline: Date().addingTimeInterval(timeout))
        return try parse(raw, maxBody: maxBody)
    }

    /// On scalars, not characters: "\r\n" is one grapheme cluster and would slip past a `Character` filter.
    static func sanitizeHeader(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 != "\r" && $0 != "\n" })) }

    static func connect(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo(ai_flags: AI_NUMERICSERV, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { throw Failure.io("cannot resolve \(host)") }
        defer { freeaddrinfo(info) }
        var lastErr: Int32 = ECONNREFUSED
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            defer { ai = a.pointee.ai_next }
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd < 0 { lastErr = errno; continue }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let rc = Foundation.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen)
            if rc != 0 && errno != EINPROGRESS { lastErr = errno; close(fd); continue }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            if ready == 0 { close(fd); throw Failure.timedOut }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if ready < 0 || soErr != 0 { lastErr = soErr != 0 ? soErr : errno; close(fd); continue }
            _ = fcntl(fd, F_SETFL, flags)
            return fd
        }
        if lastErr == ECONNREFUSED { throw Failure.refused }
        if lastErr == ETIMEDOUT { throw Failure.timedOut }
        throw Failure.io(String(cString: strerror(lastErr)))
    }

    static func sendAll(_ fd: Int32, _ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            while sent < buf.count {
                let n = send(fd, buf.baseAddress! + sent, buf.count - sent, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw errno == EAGAIN ? Failure.timedOut : Failure.io(String(cString: strerror(errno)))
                }
                sent += n
            }
        }
    }

    /// Reads until the peer closes, or until the reply is provably complete
    /// (`Content-Length` reached, or the last chunk seen) — a server that ignores
    /// `Connection: close` would otherwise turn every reply into a timeout.
    static func readAll(_ fd: Int32, max: Int, deadline: Date) throws -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var bodyStart: Int?
        var expectedLength: Int?
        var chunked = false
        while true {
            if Date() > deadline { throw Failure.timedOut }
            let n = recv(fd, &buf, buf.count, 0)
            if n == 0 { return data }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw Failure.timedOut }
                throw Failure.io(String(cString: strerror(errno)))
            }
            data.append(buf, count: n)
            if data.count > max { throw Failure.tooLarge }
            if bodyStart == nil, let sep = data.range(of: Data("\r\n\r\n".utf8)) {
                bodyStart = sep.upperBound
                let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self).lowercased()
                for line in head.components(separatedBy: "\r\n") {
                    if line.hasPrefix("content-length:") { expectedLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
                    if line.hasPrefix("transfer-encoding:"), line.contains("chunked") { chunked = true }
                }
            }
            if let bodyStart {
                if let expectedLength, data.count - bodyStart >= expectedLength { return data }
                if chunked, data.suffix(5) == Data("0\r\n\r\n".utf8) { return data }
            }
        }
    }

    static func parse(_ raw: Data, maxBody: Int) throws -> Response {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { throw Failure.malformed("no header terminator") }
        let headText = String(decoding: raw[raw.startIndex..<sep.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw Failure.malformed("empty head") }
        lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { throw Failure.malformed("bad status line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(raw[sep.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try dechunk(body)
        } else if let len = headers["content-length"].flatMap(Int.init) {
            guard len >= 0 else { throw Failure.malformed("content-length") }
            if body.count > len { body = body.prefix(len) }
        }
        if body.count > maxBody { throw Failure.tooLarge }
        return Response(status: status, headers: headers, body: body)
    }

    static func dechunk(_ data: Data) throws -> Data {
        var out = Data()
        var i = data.startIndex
        while i < data.endIndex {
            guard let lineEnd = data[i...].range(of: Data("\r\n".utf8)) else { throw Failure.malformed("chunk size") }
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            // `Int(_:radix:)` accepts a leading minus; a negative size would trap in the slice below.
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { throw Failure.malformed("chunk size") }
            if size == 0 { break }
            let start = lineEnd.upperBound
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[start..<end])
            i = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }
}
