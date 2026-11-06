import Foundation

/// What the Top Shelf shows (PROPOSAL §7.4 on the TV): written by the app
/// whenever Home loads — Continue watching and what's on the Grid now, each
/// with its picture saved beside it — and read by the Top Shelf extension,
/// which never signs in or asks Stream for anything itself. Shared through
/// the app group's container; without one (an unsigned build) there is no
/// Top Shelf, and nothing else changes.
struct TopShelfSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable {
        let id: String
        let title: String
        /// The picture's file, beside the snapshot.
        var image: String?
        var progress: Double?
        /// Selecting it: the title's page (a stream:// link).
        let display: String
        /// Play/Pause on it: straight into the player.
        let play: String
    }

    struct Section: Codable, Equatable {
        let title: String
        let items: [Item]
    }

    var sections: [Section]

    static let appGroup = "group.com.fogstack.stream"

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("TopShelf", isDirectory: true)
    }

    private static var file: URL? { directory?.appendingPathComponent("snapshot.json") }

    static func read() -> TopShelfSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(TopShelfSnapshot.self, from: data)
    }

    /// Writes it, and lets go of pictures it no longer uses. False without a container.
    @discardableResult
    func write() -> Bool {
        guard let directory = Self.directory, let file = Self.file, let data = try? JSONEncoder().encode(self) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return false }
        let kept = Set(sections.flatMap(\.items).compactMap(\.image) + ["snapshot.json"])
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where !kept.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return true
    }
}

/// The app's links (stream://), from the Top Shelf and anything else that
/// opens it: a page, the player, or a Grid channel.
enum StreamLink: Equatable {
    case page(kind: String, id: String)
    case play(kind: String, id: String)
    case live(number: String)

    var url: URL {
        switch self {
        case .page(let kind, let id): return URL(string: "stream://open/\(kind)/\(id)")!
        case .play(let kind, let id): return URL(string: "stream://play/\(kind)/\(id)")!
        case .live(let number): return URL(string: "stream://live/\(number)")!
        }
    }

    init?(_ url: URL) {
        guard url.scheme == "stream", let host = url.host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (host, parts.count) {
        case ("open", 2): self = .page(kind: parts[0], id: parts[1])
        case ("play", 2): self = .play(kind: parts[0], id: parts[1])
        case ("live", 1): self = .live(number: parts[0])
        default: return nil
        }
    }
}
