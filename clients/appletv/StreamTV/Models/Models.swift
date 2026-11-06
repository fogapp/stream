import Foundation

// The shapes the Stream API returns (swagger/v1/openapi.yaml), only as much
// of each as the Apple TV uses. Keys arrive snake_case and are converted.

struct User: Codable, Equatable {
    let id: String
    let name: String
    let role: String
}

struct SessionResponse: Decodable {
    let token: String
    let user: User
}

struct Pairing: Decodable {
    let code: String
    let pollToken: String
    let expiresAt: String
}

struct PairingPoll: Decodable {
    let state: String
    let token: String?
    let user: User?
}

struct Profile: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let color: String
    /// An emoji, or nil for the name's initial.
    var avatar: String? = nil
    let hasPin: Bool
    let kind: String
}

/// A library, for the sidebar (GET /api/v1/libraries).
struct Library: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let kind: String

    var systemImage: String {
        switch kind {
        case "movies": return "film"
        case "shows": return "tv"
        case "channels": return "play.rectangle"
        case "home_videos": return "camera"
        case "live": return "video"
        default: return "rectangle.stack"
        }
    }
}

/// A collection on the Collections page (GET /api/v1/collections).
struct CollectionCard: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let collectionKind: String?
    let itemCount: Int?
    let images: [String: Artwork]?
}

struct CurrentProfile: Decodable {
    let profile: Profile
    let chosen: Bool
    let needsPicker: Bool
}

struct ProfileSelection: Decodable {
    let token: String
    let profile: Profile

    init(token: String, profile: Profile) {
        self.token = token
        self.profile = profile
    }
}

/// One rendered piece of artwork; `src` is a signed path on the server,
/// `srcset` the same picture at other widths, `placeholder` a tiny blurred
/// copy (a data: URI) and `color` its average — shown while it loads.
struct Artwork: Decodable, Equatable {
    let src: String
    let color: String?
    var srcset: String? = nil
    var placeholder: String? = nil
    var width: Int? = nil
    var height: Int? = nil
}

/// Anything a row shows: a film, show, episode, channel video or home video.
struct Card: Decodable, Identifiable, Equatable {
    struct Parent: Decodable, Equatable {
        let id: String
        let title: String
        let images: [String: Artwork]?
    }

    let kind: String
    let id: String
    let title: String?
    let code: String?
    let year: Int?
    let images: [String: Artwork]?
    let progress: Double?
    let watched: Bool?
    let show: Parent?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let unwatchedCount: Int?
    let arrival: String?
    /// Who's in it or made it, when the row is about them.
    var credit: String? = nil
    var contentRating: String? = nil
    var runtimeMinutes: Int? = nil
    /// A channel video's or home video's length.
    var durationSeconds: Double? = nil
    /// A channel video's channel.
    var channel: ChannelRef? = nil
    var uploadDate: String? = nil
    /// A home video's moment and place.
    var capturedAt: String? = nil
    var city: String? = nil
    var country: String? = nil
    var favorite: Bool? = nil

    struct ChannelRef: Decodable, Equatable {
        let id: String
        let title: String
        var avatar: Artwork? = nil
    }

    /// What the card says under its picture.
    var heading: String {
        if kind == "episode" { return show?.title ?? title ?? code ?? "Episode" }
        return title ?? "Untitled"
    }

    var detail: String? {
        switch kind {
        case "episode": return [code, title].compactMap { $0 }.joined(separator: " · ")
        case "show", "collection": return arrival ?? credit ?? year.map(String.init)
        case "video": return channel?.title
        case "clip": return [city, capturedAt.map { Captured.day($0) }].compactMap { $0 }.joined(separator: " · ")
        default: return credit ?? year.map(String.init)
        }
    }

    /// Tall posters for films, shows and collections; wide stills for everything else.
    var isPoster: Bool { kind == "movie" || kind == "show" || kind == "collection" }

    var image: Artwork? {
        let own = images ?? [:]
        if isPoster { return own["poster"] ?? own["backdrop"] }
        return wideImage
    }

    /// The 16:9 picture: an episode's still, a film's backdrop.
    var wideImage: Artwork? {
        let own = images ?? [:]
        return own["still"] ?? own["thumb"] ?? own["backdrop"] ?? show?.images?["backdrop"] ?? own["poster"] ?? show?.images?["poster"]
    }
}

struct Hub: Decodable, Identifiable {
    let key: String
    let title: String
    let kind: String
    let items: [Card]
    var id: String { key }
}

/// The top of Home (Viewing::Home#heroes): one of what you were watching,
/// what's next, and the newest arrivals, picked at random by the server,
/// with a trailer to play behind it.
struct HomeHero: Decodable, Equatable {
    struct Play: Decodable, Equatable {
        let kind: String
        let id: String
    }

    struct Trailer: Decodable, Equatable {
        let url: String
    }

    let kind: String
    let id: String
    let title: String
    let subtitle: String?
    let label: String
    let overview: String?
    let images: [String: Artwork]?
    let play: Play
    let progress: Double?
    let resumeAt: Double?
    let trailer: Trailer?
}

struct Home: Decodable {
    var hero: HomeHero? = nil
    let hubs: [Hub]
}

/// Someone in the cast or crew (CatalogSerializer#cast).
struct CastMember: Decodable, Identifiable, Equatable {
    let personId: String
    let name: String
    let role: String
    let character: String?
    let job: String?
    let image: Artwork?
    var id: String { personId + role }
}

/// A trailer, featurette or deleted scene.
struct ExtraCard: Decodable, Identifiable, Equatable {
    let id: String
    let kindLabel: String?
    let title: String
    let durationSeconds: Double?
    let images: [String: Artwork]?
}

struct CollectionRef: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
}

/// One file of a title, when there's more than one to choose from.
struct Version: Decodable, Identifiable, Equatable {
    let mediaFileId: String
    let edition: String?
    let filename: String?
    let video: String?
    let audio: String?
    let playable: Bool
    let unplayableReason: String?
    var id: String { mediaFileId }
}

struct Trailer: Decodable, Equatable {
    let url: String
    let name: String?
}

struct MovieDetail: Decodable {
    let id: String
    let title: String
    let year: Int?
    let overview: String?
    let images: [String: Artwork]?
    let resumeAt: Double?
    let runtimeMinutes: Int?
    let contentRating: String?
    var tagline: String? = nil
    var genres: [String]? = nil
    var watched: Bool? = nil
    var progress: Double? = nil
    var myRating: Double? = nil
    var trailer: Trailer? = nil
    var versions: [Version]? = nil
    var cast: [CastMember]? = nil
    var extras: [ExtraCard]? = nil
    var collections: [CollectionRef]? = nil

    var directors: [String] { (cast ?? []).filter { $0.role == "director" }.map(\.name) }
    var playable: Bool { (versions ?? []).isEmpty || (versions ?? []).contains(where: \.playable) }
}

struct ShowDetail: Decodable {
    struct Season: Decodable, Identifiable {
        let seasonNumber: Int
        let title: String
        let availableCount: Int
        var watchedCount: Int? = nil
        var episodeCount: Int? = nil
        var id: Int { seasonNumber }
    }

    struct NextUp: Decodable {
        let episodeId: String
        let code: String
        let title: String?
        let resumeAt: Double?
        let startedShow: Bool
    }

    let id: String
    let title: String
    let year: Int?
    let overview: String?
    let images: [String: Artwork]?
    let seasons: [Season]
    let nextUp: NextUp?
    var contentRating: String? = nil
    var genres: [String]? = nil
    var network: String? = nil
    var status: String? = nil
    var unwatchedCount: Int? = nil
    var myRating: Double? = nil
    var trailer: Trailer? = nil
    var cast: [CastMember]? = nil
    var extras: [ExtraCard]? = nil
    var collections: [CollectionRef]? = nil
}

struct SeasonDetail: Decodable {
    struct Episode: Decodable, Identifiable {
        let id: String
        let code: String
        let title: String?
        let overview: String?
        let available: Bool
        let watched: Bool?
        let progress: Double?
        let resumeAt: Double?
        let images: [String: Artwork]?
        var episodeNumber: Int? = nil
        var airDate: String? = nil
        var runtimeMinutes: Int? = nil

        /// The episode as a card, for the long-press menu.
        func card(show: String?) -> Card {
            Card(kind: "episode", id: id, title: title, code: code, year: nil, images: images, progress: progress, watched: watched,
                 show: show.map { Card.Parent(id: "", title: $0, images: nil) }, seasonNumber: nil, episodeNumber: episodeNumber,
                 unwatchedCount: nil, arrival: nil)
        }
    }

    let seasonNumber: Int
    let title: String
    let episodes: [Episode]
    var overview: String? = nil
}

struct PersonDetail: Decodable {
    let id: String
    let name: String
    let image: Artwork?
    let movies: [Card]
    let shows: [Card]
}

struct CollectionDetail: Decodable {
    let id: String
    let title: String
    let overview: String?
    let images: [String: Artwork]?
    let items: [Card]
}

struct ChannelDetail: Decodable {
    let id: String
    let title: String
    let description: String?
    let subscribed: Bool?
    let images: [String: Artwork]?
    let videos: [Card]
}

struct VideoDetail: Decodable {
    let id: String
    let title: String
    let description: String?
    let uploadDate: String?
    let durationSeconds: Double?
    let channel: Card.ChannelRef?
    let images: [String: Artwork]?
    let resumeAt: Double?
    let watched: Bool?
    let moreFromChannel: [Card]?
}

struct PlaylistDetail: Decodable {
    let id: String
    let title: String
    let items: [Card]
}

/// Everything a search found, grouped as the web groups it. The groups
/// after episodes came later, so an older server may leave them out.
struct SearchResults: Decodable {
    struct Named: Decodable, Identifiable, Equatable {
        let id: String
        let title: String
        let image: Artwork?
    }

    struct Person: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let image: Artwork?
    }

    /// Where it was said: a transcript line, the match inside << >>.
    struct Said: Decodable, Identifiable, Equatable {
        let kind: String
        let id: String
        let title: String
        let start: Double
        let snippet: String

        var key: String { "\(kind)-\(id)-\(start)" }
    }

    let movies: [Card]
    let shows: [Card]
    let episodes: [Card]
    var people: [Person]?
    var collections: [Named]?
    var channels: [Named]?
    var videos: [Card]?
    var said: [Said]?
    var clips: [Card]?

    var isEmpty: Bool {
        movies.isEmpty && shows.isEmpty && episodes.isEmpty && (people ?? []).isEmpty && (collections ?? []).isEmpty
            && (channels ?? []).isEmpty && (videos ?? []).isEmpty && (said ?? []).isEmpty && (clips ?? []).isEmpty
    }
}

/// A channels library's channel (PROPOSAL §5.4).
struct ChannelCard: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let handle: String?
    let avatar: Artwork?
    let banner: Artwork?
    let videoCount: Int
    let unwatchedCount: Int
}

/// A page of home videos, newest first, and how many each year holds.
struct ClipsPage: Decodable {
    struct Year: Decodable, Hashable {
        let year: Int
        let count: Int
    }

    let years: [Year]
    let clips: [Card]
    let more: Bool
}

/// What a home-videos library can be narrowed by.
struct ClipFilters: Decodable {
    struct Album: Decodable, Identifiable, Equatable {
        let id: String
        let title: String
        let count: Int
    }

    struct Person: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let count: Int
        let image: Artwork?
    }

    let albums: [Album]
    let people: [Person]
    let favorites: Int
}

struct PlaybackSession: Decodable {
    struct Source: Decodable {
        let kind: String
        let url: String
    }

    struct Decision: Decodable {
        let summary: String?
    }

    /// Carried on a rung down from a session that failed.
    struct Fallback: Decodable {
        let fromMethod: String
        let failureClass: String
        let upgradable: Bool
    }

    /// A text track, as WebVTT among its `urls` (ASS comes as WebVTT too).
    struct Subtitle: Decodable, Identifiable, Equatable {
        let id: String
        let language: String?
        let title: String?
        let forced: Bool
        let `default`: Bool?
        let urls: [String: String]
        let format: String?
        let streamIndex: Int?

        var vtt: String? { urls["vtt"] }

        /// A picture subtitle (PGS, DVD, DVB) the app can't draw: Stream
        /// burns it into the video instead, restarting the stream.
        var burnable: Bool { (format == "pgs" || format == "burn") && streamIndex != nil }

        var label: String {
            let name = language.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? language ?? "Subtitles"
            return [name, title, forced ? "forced" : nil].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Intro, recap or credits, in seconds.
    struct Marker: Decodable, Equatable {
        let kind: String
        let start: Double
        let end: Double
    }

    /// What this profile always skips here.
    struct Skip: Decodable, Equatable {
        let intro: Bool
        let recap: Bool
        let credits: Bool
    }

    struct NextUp: Decodable, Equatable {
        let kind: String
        let id: String
        let code: String?
        let title: String?
        let showTitle: String?
        var image: Artwork? = nil
        /// Next in a playlist: keep playing through it.
        let playlistId: String?

        var label: String { [code, title].compactMap { $0 }.joined(separator: " · ") }
    }

    struct Chapter: Decodable, Equatable {
        let start: Double
        let end: Double
        let title: String?
    }

    /// Seek-bar thumbnails: sheets of columns × rows tiles, one per `interval` seconds.
    struct Trickplay: Decodable, Equatable {
        let sheetUrl: String
        let interval: Double
        let tileWidth: Int
        let tileHeight: Int
        let columns: Int
        let rows: Int
        let count: Int
    }

    /// A SponsorBlock span, and what this profile does about it: skip, ask or show.
    struct Segment: Decodable, Equatable {
        let category: String
        let start: Double
        let end: Double
        let action: String

        var label: String {
            switch category {
            case "sponsor": return "Sponsor"
            case "selfpromo": return "Self-promotion"
            case "interaction": return "Interaction reminder"
            case "intro": return "Intro"
            case "outro": return "Endcards and credits"
            case "preview": return "Preview or recap"
            case "filler": return "Filler tangent"
            case "music_offtopic": return "Non-music section"
            default: return "Segment"
            }
        }
    }

    /// One of the file's audio streams.
    struct Track: Decodable, Equatable, Identifiable {
        let index: Int
        let codec: String?
        let language: String?
        let title: String?
        let channels: Int?

        var id: Int { index }

        /// As the web writes it: "English · AC3 · 5.1".
        var label: String {
            let language = language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
            let layout: String? = switch channels {
            case 2: "Stereo"
            case 6: "5.1"
            case 8: "7.1"
            default: nil
            }
            return [title ?? language ?? "Unknown", title != nil ? language : nil, codec?.uppercased(), layout]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    struct MediaFile: Decodable, Equatable {
        let id: String
        let audio: [Track]
    }

    let id: String
    let method: String
    let title: String?
    let subtitle: String?
    let source: Source
    let fallback: Fallback?
    let progressUrl: String
    let resumeAt: Double
    let durationSeconds: Double?
    let decision: Decision?
    let subtitles: [Subtitle]
    let markers: [Marker]
    let skip: Skip?
    let nextUp: NextUp?
    let upNextSeconds: Double?
    /// The subtitle drawn into this stream, if one is (a Subtitle id).
    let burnedSubtitle: String?
    /// Episodes in a row before "Still watching?"; 0 never asks.
    let stillWatchingAfter: Int?
    let playlistId: String?
    /// Where to say what happened (stalls, errors, a channel change's timing).
    let eventsUrl: String?
    /// Tuned in on a Grid channel (PROPOSAL §7.7).
    let live: LiveInfo?
    /// A camera or web stream, relayed live (PROPOSAL §7.8): no file, no
    /// schedule — a live playlist that opens at its newest.
    var liveStream: LiveStreamInfo? = nil
    var chapters: [Chapter]? = nil
    var trickplay: Trickplay? = nil
    var segments: [Segment]? = nil
    /// An episode's show and season: Always skip, and the Related panel.
    var showId: String? = nil
    var seasonNumber: Int? = nil
    var mediaFile: MediaFile? = nil
    var audioStreamIndex: Int? = nil
}

/// Where live is on the channel a session is tuned to: the airing, when it
/// runs, the server's clock, and — for a program aired in parts, with breaks
/// between — where in the file this part runs.
struct LiveInfo: Decodable, Equatable {
    let stationId: String
    let number: String
    let name: String
    let airingId: String
    let startsAt: String
    let endsAt: String
    let serverNow: String
    let mediaStart: Double?
    let mediaEnd: Double?

    var starts: Date { LiveTime.date(startsAt) }
    var ends: Date { LiveTime.date(endsAt) }
}

/// The camera or web stream a session plays (PROPOSAL §7.8).
struct LiveStreamInfo: Decodable, Equatable {
    let id: String
    let name: String
    let kind: String
}

/// A camera or web stream's card (GET /api/v1/live_streams, PROPOSAL §7.8).
struct LiveStreamCard: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
    let status: String
    let description: String?
    /// Its picture from a few minutes ago, signed; nil until one's been taken.
    let stillUrl: String?
    let lastSeenAt: String?

    var online: Bool { status == "online" }
    var still: Artwork? { stillUrl.map { Artwork(src: $0, color: nil) } }
}

/// How a live stream's relay is going, from a progress report's answer.
struct LiveProgress: Decodable {
    struct Relay: Decodable, Equatable {
        let state: String
        let message: String?
    }

    let relay: Relay?
}

/// The Grid guide (GET /api/v1/guide).
struct Guide: Decodable {
    let now: String
    let timeZone: String
    let stations: [GuideStation]
}

struct GuideStation: Decodable, Identifiable, Equatable {
    let id: String
    let number: String
    let name: String
    let callSign: String?
    let favorite: Bool?
    /// Shows this camera or web stream instead of programming (PROPOSAL §7.8).
    var liveStreamId: String? = nil
    let airings: [Airing]
}

/// One program (or filler between programs) on a channel.
struct Airing: Decodable, Identifiable, Equatable {
    let id: String
    let stationId: String
    let startsAt: String
    let endsAt: String
    let kind: String
    let playableId: String
    let title: String
    let subtitle: String?
    let contentRating: String?
    let overview: String?
    let showId: String?
    let filler: Bool?
    let reminded: Bool?
    let mediaStart: Double?
    let mediaEnd: Double?
    let images: [String: Artwork]?

    var starts: Date { LiveTime.date(startsAt) }
    var ends: Date { LiveTime.date(endsAt) }
    var still: Artwork? { images?["still"] ?? images?["backdrop"] ?? images?["poster"] }
}

struct PlaylistCard: Decodable, Identifiable {
    struct First: Decodable {
        let kind: String
        let id: String
    }

    let id: String
    let title: String
    let itemCount: Int
    let watchLater: Bool
    let first: First?
}

struct RemoteCommand: Decodable, Identifiable {
    struct Payload: Decodable {
        let kind: String?
        let id: String?
        let title: String?
        let start: Double?
        let profileId: String?
        let profileToken: String?
        let seconds: Double?
        let by: Double?
        /// tune: a Grid channel.
        let number: String?
        let stationId: String?
        let name: String?
    }

    let id: String
    let kind: String
    let payload: Payload
}

struct RemoteDevice: Decodable {
    let id: String
    let name: String
    let remoteControl: Bool
}

// MARK: - Baseball (PROPOSAL §7.8, app/serializers/baseball_serializer.rb)

/// GET /api/v1/baseball: whether the household has an MLB.tv account, so
/// whether Baseball is in the sidebar.
struct BaseballAvailability: Decodable {
    let available: Bool
}

/// GET /api/v1/baseball/games?date=: a day of MLB's schedule.
struct BaseballDay: Decodable, Equatable {
    let date: String
    let today: String
    /// The nearest days either side with games.
    let previousDate: String?
    let nextDate: String?
    let games: [BaseballGame]
}

struct BaseballGame: Decodable, Identifiable, Equatable {
    /// upcoming, live, final, or off (postponed, suspended, cancelled).
    enum State: String, Decodable, CaseIterable {
        case live, upcoming, final, off
    }

    struct Series: Decodable, Equatable {
        let name: String?
        let status: String?
    }

    struct Inning: Decodable, Equatable {
        struct Bases: Decodable, Equatable {
            let first: Bool
            let second: Bool
            let third: Bool
        }

        let number: Int
        let ordinal: String
        /// top, middle, bottom or end.
        let half: String
        let outs: Int
        let balls: Int
        let strikes: Int
        let bases: Bases
    }

    struct Runs: Decodable, Equatable {
        let number: Int
        let away: Int?
        let home: Int?
    }

    struct Broadcast: Decodable, Equatable {
        let name: String
        /// away, home, or national.
        let side: String
    }

    struct Decisions: Decodable, Equatable {
        let winner: String?
        let loser: String?
        let save: String?
    }

    /// MLB's gamePk.
    let id: Int
    let startsAt: String
    let startTimeTbd: Bool
    let state: State
    /// MLB's own words: "In Progress", "Warmup", "Postponed: Rain".
    let status: String
    /// On MLB.tv now, or in its warm-up.
    let watchable: Bool
    let venue: String?
    let series: Series?
    let doubleHeader: Int?
    /// While it's on.
    let inning: Inning?
    let innings: [Runs]
    let scheduledInnings: Int
    let away: BaseballSide
    let home: BaseballSide
    let broadcasts: [Broadcast]
    let decisions: Decisions?

    var starts: Date { LiveTime.date(startsAt) }

    func side(_ side: BaseballSide.Which) -> BaseballSide {
        switch side {
        case .away: return away
        case .home: return home
        }
    }
}

struct BaseballSide: Decodable, Equatable {
    enum Which: String, Encodable, CaseIterable { case away, home }

    struct Team: Decodable, Equatable {
        let id: Int
        let name: String
        let club: String
        let location: String
        let abbreviation: String
        /// SVG, for the web; tvOS draws the PNG.
        let logoUrl: String
        let logoPngUrl: String
    }

    let team: Team
    /// "92-70"; in the postseason, the series so far.
    let record: String?
    let score: Int?
    let hits: Int?
    let errors: Int?
    let winner: Bool
    let probablePitcher: String?
}

/// POST /api/v1/baseball/games/:id/watch: the team's stream that plays it.
struct BaseballWatch: Decodable {
    let liveStreamId: String
    let name: String
}
