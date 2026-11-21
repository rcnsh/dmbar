import Foundation

/// An error reply from the daemon, or a failure to reach it.
nonisolated struct APIError: LocalizedError, Sendable {
    var code: String
    var message: String
    var errorDescription: String? { message }
}

/// Splits a server-sent event stream into events. Each of the daemon's
/// events is one `event:` line and one `data:` line.
nonisolated struct EventParser: Sendable {
    private var name = ""

    /// Takes one line and returns an event when the line completes one.
    mutating func feed(_ line: String) -> (name: String, data: Data)? {
        if let v = line.strip(prefix: "event:") {
            name = v
        } else if let v = line.strip(prefix: "data:") {
            defer { name = "" }
            return (name, Data(v.utf8))
        }
        return nil  // a comment, or a field this app doesn't use
    }
}

private extension String {
    nonisolated func strip(prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : nil
    }
}

/// The daemon's HTTP API (docs/api.md).
nonisolated struct Client: Sendable {
    let base: URL
    let token: String
    private let session: URLSession

    init(base: URL, token: String) {
        self.base = base
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90  // the event stream pings every 25 s
        config.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: config)
    }

    private struct Empty: Decodable {}
    private struct Failure: Decodable {
        struct Detail: Decodable { var code: String; var message: String }
        var error: Detail
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: (any Encodable)? = nil) throws -> URLRequest {
        var parts = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var req = URLRequest(url: parts.url!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            let e = JSONEncoder()
            e.keyEncodingStrategy = .convertToSnakeCase
            req.httpBody = try e.encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func call<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: (any Encodable)? = nil) async throws -> T {
        let (data, response) = try await session.data(for: request(method, path, query: query, body: body))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if let f = try? JSONDecoder().decode(Failure.self, from: data) {
                throw APIError(code: f.error.code, message: f.error.message)
            }
            throw APIError(code: "http", message: "The daemon answered with an error.")
        }
        return try JSONDecoder.api.decode(T.self, from: data)
    }

    struct Page: Decodable { var messages: [Message]; var more: Bool }

    func history(thread: String, before: String?, limit: Int = 40) async throws -> Page {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { q.append(URLQueryItem(name: "before", value: before)) }
        return try await call("GET", "v1/threads/\(thread)/messages", query: q)
    }

    /// A fresh ID for a send, chosen before sending so a retry can reuse it.
    func newOTID() async throws -> String {
        struct Reply: Decodable { var otid: String }
        let r: Reply = try await call("POST", "v1/otid")
        return r.otid
    }

    /// Sends text and returns the send's `otid`.
    func send(thread: String, text: String, otid: String?, replyTo: String?) async throws -> String {
        struct Body: Encodable { var text: String; var otid: String?; var replyTo: String? }
        struct Reply: Decodable { var otid: String }
        let r: Reply = try await call("POST", "v1/threads/\(thread)/messages", body: Body(text: text, otid: otid, replyTo: replyTo))
        return r.otid
    }

    func markRead(thread: String, messageId: String, atMs: Int64) async throws {
        struct Body: Encodable { var messageId: String; var atMs: Int64 }
        let _: Empty = try await call("POST", "v1/threads/\(thread)/read", body: Body(messageId: messageId, atMs: atMs))
    }

    func typing(thread: String, active: Bool) async throws {
        struct Body: Encodable { var active: Bool }
        let _: Empty = try await call("POST", "v1/threads/\(thread)/typing", body: Body(active: active))
    }

    func login(cookies: [String: String]) async throws {
        struct Body: Encodable { var cookies: [String: String] }
        // Cookie names are sent as they are, not snake-cased.
        var req = try request("POST", "v1/login/cookies")
        req.httpBody = try JSONEncoder().encode(Body(cookies: cookies))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let f = try? JSONDecoder().decode(Failure.self, from: data)
            throw APIError(code: f?.error.code ?? "http", message: f?.error.message ?? "Login failed.")
        }
    }

    func logout() async throws {
        let _: Empty = try await call("POST", "v1/logout")
    }

    /// The event stream. It ends, or throws, when the connection does; the
    /// caller reconnects, and the first event of the new stream is the whole
    /// state.
    func events() -> AsyncThrowingStream<ServerEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request("GET", "v1/events"))
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw APIError(code: "http", message: "The daemon refused the event stream.")
                    }
                    var parser = EventParser()
                    // Split on "\n" alone. `bytes.lines` also breaks on
                    // U+0085, U+2028 and U+2029, which message text can hold.
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        guard byte == 0x0A else {
                            line.append(byte)
                            continue
                        }
                        let text = String(decoding: line, as: UTF8.self)
                        line.removeAll(keepingCapacity: true)
                        guard let (name, data) = parser.feed(text) else { continue }
                        // One event that can't be read is skipped: ending the
                        // stream over it would end every later stream too.
                        if let event = try? ServerEvent.decode(name: name, data: data) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
