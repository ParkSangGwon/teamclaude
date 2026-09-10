import Foundation

public struct ProxyEndpoint: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var apiKey: String?

    public init(host: String = "127.0.0.1", port: Int = 3456, apiKey: String? = nil) {
        self.host = host; self.port = port; self.apiKey = apiKey
    }

    /// `host` comes from the config: an IPv6 literal needs brackets, and a value that
    /// is not a URL host at all must not trap the app on its first poll.
    public var baseURL: URL {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "http://\(h):\(port)") ?? URL(string: "http://127.0.0.1:3456")!
    }
    public var label: String { "\(host):\(port)" }

    /// Whether the config's host/port describe something that can be dialled.
    public static func isValid(host: String, port: Int) -> Bool {
        guard (1...65535).contains(port), !host.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:[]_"))
        guard host.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return ProxyEndpoint(host: host, port: port).baseURL.host != nil
    }
    public var dashboardURL: URL { baseURL.appending(path: "teamclaude/dashboard") }
}

public enum ProxyError: Error, Sendable, Equatable {
    /// Connection refused or no route: nothing is listening.
    case unreachable(String)
    /// Accepted but never answered: a stalled or overloaded server.
    case timedOut
    /// 401: the key on file is not the one the server wants.
    case unauthorized
    /// Something else answers on the port.
    case notTeamClaude(Int)
    /// 404/501 without an `ok:false` body: a server predating the endpoint.
    case unsupported
    /// The control plane refused with a reason.
    case rejected(String)
    case badReply(String)
    case tooLarge

    public var message: String {
        switch self {
        case .unreachable: return "Proxy is not running"
        case .timedOut: return "Proxy did not answer — the event loop may be stalled; check the log"
        case .unauthorized: return "Proxy rejected the API key"
        case .notTeamClaude(let code): return "Something else is answering on the proxy port (HTTP \(code))"
        case .unsupported: return "This proxy version does not support that action"
        case .rejected(let why): return why
        case .badReply(let why): return "Unexpected reply: \(why)"
        case .tooLarge: return "Reply too large"
        }
    }
}

/// Client for the four control-plane endpoints. Loopback is exempt from the key
/// gate by default, but `proxy.trustLoopback=false` is a supported deployment, so
/// the key is sent whenever it is known. URLSession sends neither `Origin` nor
/// `Sec-Fetch-Site`, which is what lets the writes past the CSRF gate.
public actor ProxyClient {
    public static let maxReplyBytes = 1024 * 1024

    public enum Transport: Sendable {
        /// BSD sockets, one connection per request — what the CLI and curl do.
        case socket
        /// URLSession; used by tests through a stubbed `URLProtocol`.
        case urlSession(URLSessionConfiguration)
    }

    public private(set) var endpoint: ProxyEndpoint
    private let session: URLSession?

    public init(endpoint: ProxyEndpoint, transport: Transport = .socket) {
        self.endpoint = endpoint
        switch transport {
        case .socket:
            session = nil
        case .urlSession(let configuration):
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 15
            configuration.waitsForConnectivity = false
            session = URLSession(configuration: configuration)
        }
    }

    public init(endpoint: ProxyEndpoint, configuration: URLSessionConfiguration) {
        self.init(endpoint: endpoint, transport: .urlSession(configuration))
    }

    public func update(endpoint: ProxyEndpoint) { self.endpoint = endpoint }

    public func status() async throws -> StatusSnapshot {
        let json = try await get("/teamclaude/status")
        do { return try StatusSnapshot(json: json) } catch { throw ProxyError.notTeamClaude(200) }
    }

    public func quota() async throws -> QuotaSnapshot {
        let json = try await get("/teamclaude/quota")
        do { return try QuotaSnapshot(json: json) } catch { throw ProxyError.notTeamClaude(200) }
    }

    public func switchTo(_ account: String) async throws -> SwitchResult {
        let json = try await post("/teamclaude/switch", body: .object(["account": .string(account)]))
        return SwitchResult(json: json)
    }

    public func reload() async throws -> ReloadResult {
        let json = try await post("/teamclaude/reload", body: nil)
        return ReloadResult(json: json)
    }

    // MARK: - transport

    private func get(_ path: String) async throws -> JSON {
        var req = URLRequest(url: endpoint.baseURL.appending(path: path))
        req.httpMethod = "GET"
        // A busy proxy's event loop can lag for seconds; the CLI's own status deadline is 5 s.
        req.timeoutInterval = 8
        applyHeaders(&req)
        let (data, http) = try await send(req)
        if http.statusCode == 401 { throw ProxyError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw ProxyError.notTeamClaude(http.statusCode) }
        guard let json = try? JSON.parse(data) else { throw ProxyError.notTeamClaude(http.statusCode) }
        return json
    }

    private func post(_ path: String, body: JSON?) async throws -> JSON {
        var req = URLRequest(url: endpoint.baseURL.appending(path: path))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        applyHeaders(&req)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body.any, options: [])
        }
        let (data, http) = try await send(req)
        if http.statusCode == 401 { throw ProxyError.unauthorized }
        let json = try? JSON.parse(data)
        // The control endpoints always answer `ok:false` plus a reason; a 404/501
        // without that came from somewhere else and means the feature is missing.
        if let json, json["ok"].bool == true { return json }
        if let json, json["ok"].bool == false {
            throw ProxyError.rejected(Text.safe(json["error"].string ?? "request refused", max: 200))
        }
        if http.statusCode == 404 || http.statusCode == 501 { throw ProxyError.unsupported }
        throw ProxyError.badReply("HTTP \(http.statusCode)")
    }

    private func applyHeaders(_ req: inout URLRequest) {
        if let key = endpoint.apiKey, !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-api-key") }
        req.setValue("application/json", forHTTPHeaderField: "accept")
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let session else { return try await sendOverSocket(req) }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw ProxyError.badReply("not HTTP") }
            if data.count > ProxyClient.maxReplyBytes { throw ProxyError.tooLarge }
            return (data, http)
        } catch let e as ProxyError {
            throw e
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw ProxyError.timedOut
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed:
                throw ProxyError.unreachable(e.localizedDescription)
            default: throw ProxyError.unreachable(e.localizedDescription)
            }
        } catch {
            throw ProxyError.badReply(error.localizedDescription)
        }
    }

    /// Blocking socket I/O stays off the cooperative pool: a stalled proxy can hold a
    /// call for the connect timeout plus the read timeout, and the pool is only as
    /// wide as the core count.
    private static let ioQueue = DispatchQueue(label: "teamclaude.socket-http", qos: .userInitiated, attributes: .concurrent)

    private func sendOverSocket(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let ep = endpoint
        let method = req.httpMethod ?? "GET"
        let path = req.url?.path ?? "/"
        let headers = req.allHTTPHeaderFields ?? [:]
        let body = req.httpBody
        let timeout = req.timeoutInterval > 0 ? req.timeoutInterval : 5
        let result: Result<SocketHTTP.Response, SocketHTTP.Failure> = await withCheckedContinuation { cont in
            ProxyClient.ioQueue.async {
                do { cont.resume(returning: .success(try SocketHTTP.request(host: ep.host, port: ep.port, method: method, path: path, headers: headers, body: body, timeout: timeout, maxBody: ProxyClient.maxReplyBytes))) }
                catch let f as SocketHTTP.Failure { cont.resume(returning: .failure(f)) }
                catch { cont.resume(returning: .failure(.io(error.localizedDescription))) }
            }
        }
        switch result {
        case .success(let r):
            guard let http = HTTPURLResponse(url: req.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers) else {
                throw ProxyError.badReply("bad status \(r.status)")
            }
            return (r.body, http)
        case .failure(.refused): throw ProxyError.unreachable("connection refused")
        case .failure(.timedOut): throw ProxyError.timedOut
        case .failure(.tooLarge): throw ProxyError.tooLarge
        case .failure(.io(let why)): throw ProxyError.unreachable(why)
        case .failure(.malformed(let why)): throw ProxyError.badReply(why)
        }
    }
}
