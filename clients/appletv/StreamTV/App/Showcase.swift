import Foundation

/// Stream without a server: made-up titles, generated artwork and the
/// answers the API would give, from Resources/Showcase (written by
/// Scripts/showcase.py). For the UI tests' screenshots and for looking at a
/// screen in the simulator; never on a real Apple TV unless launched so.
enum Showcase {
    static let server = URL(string: "https://showcase.stream.invalid")!

    static var directory: URL? { Bundle.main.url(forResource: "Showcase", withExtension: nil) }

    /// "showcase/northbound-poster.jpg" → the bundled file.
    static func file(_ path: String) -> URL? {
        let name = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard name.hasPrefix("showcase/"), let directory else { return nil }
        let url = directory.appendingPathComponent(String(name.dropFirst("showcase/".count)))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static let timeKeys: Set<String> = ["now", "from", "to", "starts_at", "ends_at", "server_now"]

    /// The Grid's times, moved so the answer's "now" is now: the showcase's
    /// channels are always on the air.
    static func shifted(_ data: Data) -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let now = root["now"] as? String else { return data }
        let delta = Date().timeIntervalSince(LiveTime.date(now))
        let formatter = ISO8601DateFormatter()
        func walk(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return Dictionary(uniqueKeysWithValues: object.map { key, inner -> (String, Any) in
                    if timeKeys.contains(key), let text = inner as? String, LiveTime.date(text) != .distantPast {
                        return (key, formatter.string(from: LiveTime.date(text).addingTimeInterval(delta)))
                    }
                    return (key, walk(inner))
                })
            }
            if let array = value as? [Any] { return array.map(walk) }
            return value
        }
        return (try? JSONSerialization.data(withJSONObject: walk(root))) ?? data
    }

    /// The canned answer to a request: "GET api/v1/shows/deep-field" reads
    /// api_v1_shows_deep-field.json; any other method reads the file with
    /// the method first (post_api_v1_playback_sessions.json), and a write
    /// with no file of its own simply succeeds.
    static func answer<T: Decodable>(_ method: String, _ path: String, decoder: JSONDecoder) throws -> T {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let base = trimmed.replacingOccurrences(of: "/", with: "_")
        var name = method == "GET" ? base : "\(method.lowercased())_\(base)"
        // The screens before Home, for their screenshots.
        if name == "api_v1_profiles_current", UserDefaults.standard.bool(forKey: "StreamShowcasePicker") { name += "_picker" }
        if let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("\(name).json")) {
            return try decoder.decode(T.self, from: shifted(data))
        }
        if method != "GET", let empty = Empty() as? T { return empty }
        throw APIError(status: 404, messages: ["The showcase has nothing for \(method) \(path)."])
    }
}
