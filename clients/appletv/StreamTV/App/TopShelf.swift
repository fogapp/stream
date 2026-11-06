import TVServices
import UIKit

/// Keeps the Top Shelf's snapshot (Shared/TopShelfSnapshot.swift) up to
/// date from what Home just loaded: Continue watching, then what's on Live
/// TV now, each with its picture saved beside it.
enum TopShelf {
    static func publish(home: Home, guide: Guide?, api: StreamAPI) async {
        guard TopShelfSnapshot.directory != nil else { return }
        var sections: [TopShelfSnapshot.Section] = []

        if let hub = home.hubs.first(where: { $0.kind == "continue" }) {
            var items: [TopShelfSnapshot.Item] = []
            for card in hub.items.prefix(10) {
                if let item = await item(card, api: api) { items.append(item) }
            }
            if !items.isEmpty { sections.append(.init(title: hub.title, items: items)) }
        }

        if let guide {
            let now = Date().addingTimeInterval(LiveTime.skew(serverNow: guide.now))
            var items: [TopShelfSnapshot.Item] = []
            for station in guide.stations.prefix(10) {
                guard let airing = LiveTime.onAt(station.airings, now).current else { continue }
                let link = StreamLink.live(number: station.number).url.absoluteString
                items.append(.init(id: "live-\(station.id)", title: "\(station.number) · \(airing.title)",
                                   image: await save(airing.still, as: "live-\(station.id)-\(airing.id)", api: api),
                                   display: link, play: link))
            }
            if !items.isEmpty { sections.append(.init(title: "On now", items: items)) }
        }

        let snapshot = TopShelfSnapshot(sections: sections)
        guard snapshot != TopShelfSnapshot.read(), snapshot.write() else { return }
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private static func item(_ card: Card, api: StreamAPI) async -> TopShelfSnapshot.Item? {
        let play = StreamLink.play(kind: card.kind, id: card.id).url.absoluteString
        let display: String
        let title: String
        switch card.kind {
        case "movie":
            display = StreamLink.page(kind: "movie", id: card.id).url.absoluteString
            title = card.heading
        case "episode":
            let show = card.show?.id ?? ""
            display = show.isEmpty ? play : StreamLink.page(kind: "show", id: show).url.absoluteString
            title = [card.show?.title, card.code].compactMap { $0 }.joined(separator: " · ")
        default:
            display = play
            title = card.heading
        }
        return .init(id: "\(card.kind)-\(card.id)", title: title, image: await save(card.wideImage, as: "\(card.kind)-\(card.id)", api: api),
                     progress: card.progress, display: display, play: play)
    }

    /// The picture as a file the Top Shelf can read: 16:9, large enough for 4K.
    private static func save(_ artwork: Artwork?, as name: String, api: StreamAPI) async -> String? {
        guard let artwork, let directory = TopShelfSnapshot.directory,
              let url = api.absolute(artwork.source(forWidth: 800, scale: 2)),
              let image = await ImagePipeline.shared.image(url), let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let file = "\(name.replacingOccurrences(of: "/", with: "-")).jpg"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: directory.appendingPathComponent(file), options: .atomic)) != nil ? file : nil
    }
}

extension Route {
    /// A page by the web's names for it, for a stream:// link.
    init?(kind: String, id: String) {
        switch kind {
        case "movie": self = .movie(id)
        case "show": self = .show(id)
        case "person": self = .person(id)
        case "collection": self = .collection(id)
        case "channel": self = .channel(id)
        case "video": self = .video(id)
        case "playlist": self = .playlist(id)
        default: return nil
        }
    }
}
