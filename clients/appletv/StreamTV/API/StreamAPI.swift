import Foundation

/// A failed request, with the server's own words when it sent some
/// (`{ "errors": [...] }`, the only error envelope Stream uses).
struct APIError: LocalizedError {
    let status: Int
    let messages: [String]

    var errorDescription: String? {
        messages.first ?? (status == 0 ? "Stream didn't answer." : "Stream answered \(status).")
    }
}

/// Talks to one Stream server: the bearer token from pairing, the chosen
/// profile's token (X-Stream-Profile), and this Apple TV's device key
/// (X-Stream-Device) on every call.
struct StreamAPI {
    let server: URL
    var sessionToken: String?
    var profileToken: String?
    var deviceKey: String
    /// Answer from the bundled showcase instead of a server.
    var showcase = false

    static let userAgent = "StreamTV/1.0 (Apple TV; tvOS)"

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    /// A path the server hands out (artwork, media) made absolute.
    func absolute(_ path: String) -> URL? {
        if showcase, let local = Showcase.file(path) { return local }
        if let url = URL(string: path), url.scheme != nil { return url }
        return URL(string: path, relativeTo: server)?.absoluteURL
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send("GET", path, query: query, body: Optional<Empty>.none)
    }

    /// `timeout` for a request that waits on something slow upstream (an MLB.tv stream read the first time it plays).
    func post<T: Decodable, B: Encodable>(_ path: String, body: B, timeout: TimeInterval = 20) async throws -> T {
        try await send("POST", path, body: body, timeout: timeout)
    }

    func patch<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await send("PATCH", path, body: body)
    }

    func put<T: Decodable>(_ path: String) async throws -> T {
        try await send("PUT", path, body: Optional<Empty>.none)
    }

    func put<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await send("PUT", path, body: body)
    }

    func delete(_ path: String, query: [String: String] = [:]) async throws {
        let _: Empty = try await send("DELETE", path, query: query, body: Optional<Empty>.none)
    }

    /// Fire and forget, for progress reports: a lost one is followed by the next.
    func postQuietly<B: Encodable>(_ path: String, body: B) async {
        let _: Empty? = try? await send("POST", path, body: body)
    }

    func patchQuietly<B: Encodable>(_ path: String, body: B) async {
        let _: Empty? = try? await send("PATCH", path, body: body)
    }

    private func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, query: [String: String] = [:], body: B?,
                                                  timeout: TimeInterval = 20) async throws -> T {
        if showcase { return try Showcase.answer(method, path, decoder: Self.decoder) }
        guard var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError(status: 0, messages: ["That isn't a server address."])
        }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw APIError(status: 0, messages: ["That isn't a server address."]) }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Stream names this device from it ("Apple TV app").
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let sessionToken { request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization") }
        if let profileToken { request.setValue(profileToken, forHTTPHeaderField: "X-Stream-Profile") }
        request.setValue(deviceKey, forHTTPHeaderField: "X-Stream-Device")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError(status: 0, messages: ["Stream didn't answer: \(error.localizedDescription)"])
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let messages = (try? Self.decoder.decode(ErrorEnvelope.self, from: data))?.errors ?? []
            throw APIError(status: status, messages: messages)
        }
        if T.self == Empty.self || data.isEmpty, let empty = Empty() as? T { return empty }
        return try Self.decoder.decode(T.self, from: data)
    }
}

struct Empty: Codable {}

private struct ErrorEnvelope: Decodable {
    let errors: [String]
}
