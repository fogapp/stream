import AVFoundation
import XCTest
@testable import StreamTV

/// The Apple TV client against real answers from Stream: the fixtures are
/// responses captured from the e2e harness (bin/rails e2e:seed), so a
/// serializer change that breaks the client shows up here.
final class StreamTVTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    func testDecodesHomeAndItsCards() throws {
        let home = try fixture("home", as: Home.self)
        XCTAssertFalse(home.hubs.isEmpty)
        let movies = home.hubs.flatMap(\.items).filter { $0.kind == "movie" }
        XCTAssertFalse(movies.isEmpty)
        XCTAssertTrue(movies.allSatisfy(\.isPoster))
    }

    func testDecodesTitlesSearchAndProfiles() throws {
        XCTAssertEqual(try fixture("movie", as: MovieDetail.self).title, "Heat")
        let show = try fixture("show", as: ShowDetail.self)
        XCTAssertEqual(show.nextUp?.code, "S01E01")
        XCTAssertEqual(try fixture("season", as: SeasonDetail.self).episodes.count, 2)
        XCTAssertEqual(try fixture("search", as: SearchResults.self).movies.count, 2)
        XCTAssertFalse(try fixture("current_profile", as: CurrentProfile.self).needsPicker)
        XCTAssertEqual(try fixture("profiles", as: [Profile].self).count, 1)
    }

    func testDecodesAPlaybackSession() throws {
        let session = try fixture("playback_session", as: PlaybackSession.self)
        XCTAssertEqual(session.source.kind, "hls")
        XCTAssertTrue(session.progressUrl.hasSuffix("/progress"))
    }

    func testDecodesTheLiveTVGuideAndATunedChannel() throws {
        let guide = try fixture("guide", as: Guide.self)
        XCTAssertEqual(guide.stations.map(\.number), ["2", "5"])
        let airing = try XCTUnwrap(guide.stations.first?.airings.first)
        XCTAssertLessThan(airing.starts, airing.ends)
        XCTAssertEqual(airing.filler, false)

        let session = try fixture("live_session", as: PlaybackSession.self)
        let live = try XCTUnwrap(session.live)
        XCTAssertEqual(live.number, "5")
        XCTAssertEqual(live.mediaStart, 0)
        XCTAssertNil(live.mediaEnd)
        XCTAssertTrue(session.eventsUrl?.hasSuffix("/events") ?? false)
    }

    /// Cameras and web streams (PROPOSAL §7.8): their cards, and a session
    /// that plays one — no file, no schedule, a live playlist.
    func testDecodesLiveStreamsAndASessionPlayingOne() throws {
        let streams = try fixture("live_streams", as: [LiveStreamCard].self)
        XCTAssertEqual(streams.map(\.name), ["Front door", "Harbour cam"])
        XCTAssertEqual(streams.map(\.online), [true, false])
        XCTAssertNotNil(streams.first?.still)
        XCTAssertNil(streams.last?.still)

        let session = try fixture("live_stream_session", as: PlaybackSession.self)
        let stream = try XCTUnwrap(session.liveStream)
        XCTAssertEqual(stream.name, "Front door")
        XCTAssertEqual(stream.kind, "camera")
        XCTAssertNil(session.live)
        XCTAssertNil(session.durationSeconds)
        XCTAssertTrue(session.source.url.hasSuffix("/live/index.m3u8"))
        XCTAssertNil(try fixture("playback_session", as: PlaybackSession.self).liveStream)
    }

    /// Baseball (PROPOSAL §7.8): a day of MLB's schedule, before a game and after one.
    func testDecodesADayOfBaseball() throws {
        let today = try fixture("baseball_day", as: BaseballDay.self)
        XCTAssertEqual(Baseball.dayLabel(today.date, today: today.today), "Today")
        XCTAssertEqual(today.previousDate, "2026-10-18")
        let upcoming = try XCTUnwrap(today.games.first)
        XCTAssertEqual(upcoming.state, .upcoming)
        XCTAssertEqual(upcoming.away.team.club, "Guardians")
        XCTAssertTrue(upcoming.home.team.logoPngUrl.contains("/team/139/"))
        XCTAssertEqual(upcoming.series?.name, "ALCS Game 6")
        XCTAssertNil(upcoming.inning)
        XCTAssertEqual(Baseball.unwatchable(upcoming), "MLB.tv starts this game's broadcast shortly before first pitch")

        let final = try XCTUnwrap(try fixture("baseball_final_day", as: BaseballDay.self).games.first)
        XCTAssertEqual(final.state, .final)
        XCTAssertEqual(Baseball.finalLabel(final), "Final")
        XCTAssertEqual(final.innings.count, 9)
        XCTAssertNotNil(final.decisions?.winner)
        XCTAssertEqual([final.away.winner, final.home.winner].filter { $0 }.count, 1)
    }

    /// What can be watched of a game: each team's broadcast, away first, or the national one once.
    func testOffersEachTeamsBroadcast() throws {
        var game = try XCTUnwrap(try fixture("baseball_day", as: BaseballDay.self).games.first)
        XCTAssertEqual(Baseball.choices(game), [Baseball.Choice(side: .home, team: nil, channel: "TBS")])
        XCTAssertEqual(Baseball.choices(game).first?.label, "Watch · TBS")

        let json = """
        [{"name": "SNY", "side": "home"}, {"name": "FDSN", "side": "away"}]
        """
        game = BaseballGame(id: game.id, startsAt: game.startsAt, startTimeTbd: false, state: .live, status: "In Progress", watchable: true,
                            venue: nil, series: nil, doubleHeader: nil,
                            inning: .init(number: 7, ordinal: "7th", half: "middle", outs: 3, balls: 0, strikes: 0,
                                          bases: .init(first: false, second: false, third: false)),
                            innings: [], scheduledInnings: 9, away: game.away, home: game.home,
                            broadcasts: try decoder.decode([BaseballGame.Broadcast].self, from: Data(json.utf8)), decisions: nil)
        XCTAssertEqual(Baseball.choices(game).map(\.label), ["Guardians broadcast · FDSN", "Rays broadcast · SNY"])
        XCTAssertEqual(Baseball.inningLabel(try XCTUnwrap(game.inning)), "Mid 7th")
        XCTAssertEqual(Baseball.refresh(BaseballDay(date: "2026-10-01", today: "2026-10-19", previousDate: nil, nextDate: nil, games: [game])),
                       .seconds(15))
        XCTAssertNil(Baseball.refresh(BaseballDay(date: "2026-10-01", today: "2026-10-19", previousDate: nil, nextDate: nil, games: [])))
        XCTAssertEqual(Baseball.dayLabel("2026-10-18", today: "2026-10-19"), "Yesterday")
    }

    /// A channel showing a stream is one program in the guide, the stream.
    func testDecodesAStreamsChannelInTheGuide() throws {
        let json = """
        {"id": "s", "number": "50", "name": "Door cam", "call_sign": null, "favorite": false, "live_stream_id": "x",
         "airings": [{"id": "a", "station_id": "s", "starts_at": "2026-10-09T17:00:00.000Z", "ends_at": "2026-10-09T20:00:00.000Z",
                      "kind": "live_stream", "playable_id": "x", "title": "Front door", "subtitle": "Live", "content_rating": null,
                      "overview": null, "show_id": null, "filler": false, "reminded": false, "media_start": 0, "media_end": null,
                      "images": {"still": {"src": "/artwork/live/x/1.webp?s=y", "srcset": "", "width": 640, "height": null,
                                           "placeholder": null, "color": null}}}]}
        """
        let station = try decoder.decode(GuideStation.self, from: Data(json.utf8))
        XCTAssertEqual(station.liveStreamId, "x")
        XCTAssertEqual(station.airings.first?.kind, "live_stream")
        XCTAssertEqual(station.airings.first?.still?.src, "/artwork/live/x/1.webp?s=y")
    }

    func testLiveIsWhereTheClockSays() throws {
        let starts = LiveTime.date("2026-09-27T20:00:00.000Z")
        let ends = LiveTime.date("2026-09-27T20:30:00Z")
        XCTAssertEqual(LiveTime.offset(starts: starts, ends: ends, at: starts.addingTimeInterval(600)), 600)
        XCTAssertEqual(LiveTime.offset(starts: starts, ends: ends, at: starts.addingTimeInterval(-60)), 0)
        XCTAssertEqual(LiveTime.offset(starts: starts, ends: ends, at: ends.addingTimeInterval(60)), 1800)
        XCTAssertEqual(LiveTime.skew(serverNow: "2026-09-27T20:00:05Z", receivedAt: starts), 5)

        let numbers = ["2", "4", "9"]
        XCTAssertEqual(LiveTime.adjacent(numbers, number: "4", step: 1, numberOf: { $0 }), "9")
        XCTAssertEqual(LiveTime.adjacent(numbers, number: "9", step: 1, numberOf: { $0 }), "2")
        XCTAssertEqual(LiveTime.adjacent(numbers, number: "2", step: -1, numberOf: { $0 }), "9")
    }

    func testAProgramInPartsIsOneInTheGuide() throws {
        func airing(_ id: String, _ from: String, _ to: String, start: Double, playable: String = "p", filler: Bool = false) -> Airing {
            Airing(id: id, stationId: "s", startsAt: "2026-09-27T\(from):00Z", endsAt: "2026-09-27T\(to):00Z", kind: "episode",
                   playableId: playable, title: id, subtitle: nil, contentRating: nil, overview: nil, showId: nil, filler: filler,
                   reminded: false, mediaStart: start, mediaEnd: nil, images: nil)
        }
        let programs = LiveTime.programs([
            airing("a", "20:00", "20:05", start: 0), airing("t", "20:05", "20:07", start: 0, playable: "trailer", filler: true),
            airing("b", "20:07", "20:28", start: 300), airing("c", "20:30", "21:00", start: 0, playable: "q"),
        ])
        XCTAssertEqual(programs.map(\.airing.id), ["a", "c"])
        XCTAssertEqual(programs.first?.ends, LiveTime.date("2026-09-27T20:28:00Z"))
    }

    func testArtworkPicksTheRenditionForItsSize() {
        let art = Artwork(src: "/a/640.webp", color: "#123456", srcset: "/a/320.webp 320w, /a/640.webp 640w, /a/1280.webp 1280w")
        XCTAssertEqual(art.source(forWidth: 260, scale: 1), "/a/320.webp")
        XCTAssertEqual(art.source(forWidth: 260, scale: 2), "/a/640.webp")
        XCTAssertEqual(art.source(forWidth: 1920, scale: 2), "/a/1280.webp")
        XCTAssertEqual(Artwork(src: "/b.webp", color: nil).source(forWidth: 400, scale: 2), "/b.webp")
    }

    func testColoursFromTheServer() {
        XCTAssertNotNil(Palette.from(hex: "#e5a00d"))
        XCTAssertNotNil(Palette.from(hex: "e5a00d"))
        XCTAssertNil(Palette.from(hex: "orange"))
        XCTAssertNil(Palette.from(hex: nil))
    }

    func testTheShowcaseAnswersFromTheBundle() throws {
        XCTAssertNotNil(Showcase.file("showcase/northbound-poster.jpg"))
        XCTAssertNil(Showcase.file("showcase/nothing.jpg"))
        XCTAssertNil(Showcase.file("/artwork/1/1/320.webp"))
        let empty: Empty = try Showcase.answer("PUT", "api/v1/stations/x/favorite", decoder: StreamAPI.decoder)
        XCTAssertNotNil(empty)
        XCTAssertThrowsError(try Showcase.answer("GET", "api/v1/nothing", decoder: StreamAPI.decoder) as Home)
    }

    func testCapabilitiesSpeakTheDecisionEnginesKeys() throws {
        let json = try JSONSerialization.jsonObject(with: {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return try encoder.encode(Capabilities.make(hevc: true, hdr: true, fourK: true))
        }()) as? [String: Any]
        XCTAssertEqual(json?["hls"] as? String, "native")
        XCTAssertEqual(json?["max_audio_channels"] as? Int, 8)
        XCTAssertEqual(json?["max_height"] as? Int, 2160)
        XCTAssertEqual(json?["video"] as? [String], ["h264", "hevc", "hevc_10"])
        XCTAssertEqual(Capabilities.make(hevc: false, hdr: false, fourK: false).video, ["h264"])
        XCTAssertEqual(Capabilities.make(hevc: false, hdr: false, fourK: false).hdr, [])
    }

    @MainActor
    func testServerAddressesAreForgiving() {
        XCTAssertEqual(AppState.normalize("stream.lan")?.absoluteString, "http://stream.lan")
        XCTAssertEqual(AppState.normalize(" https://stream.example/ ")?.absoluteString, "https://stream.example")
        XCTAssertEqual(AppState.normalize("192.168.1.200:3000")?.absoluteString, "http://192.168.1.200:3000")
        XCTAssertNil(AppState.normalize(""))
    }

    func testClock() {
        XCTAssertEqual(Clock.format(5423), "1:30:23")
        XCTAssertEqual(Clock.format(65), "1:05")
    }

    func testReadsWebVTTAndFindsTheCueOnScreen() {
        let vtt = WebVTT(parsing: """
        WEBVTT

        1
        00:00:01.000 --> 00:00:03.500 align:center
        <i>Hello</i> &amp; welcome

        00:00:03.000 --> 00:00:05.000
        Second line
        spans two

        01:00:00,000 --> 01:00:02,000
        An hour in
        """)
        XCTAssertEqual(vtt.cues.count, 3)
        XCTAssertNil(vtt.text(at: 0.5))
        XCTAssertEqual(vtt.text(at: 1.5), "Hello & welcome")
        XCTAssertEqual(vtt.text(at: 3.2), "Hello & welcome\nSecond line\nspans two")
        XCTAssertEqual(vtt.text(at: 3601), "An hour in")
        XCTAssertEqual(WebVTT.seconds("01:02.5"), 62.5)
    }

    func testDecodesSkippingAndUpNext() throws {
        let json = """
        {"id":"s","method":"direct","source":{"kind":"file","url":"/media/s/t/original.mp4"},"progress_url":"/media/s/t/progress",
         "resume_at":0,"duration_seconds":2700,"subtitles":[{"id":"e3","language":"eng","title":null,"forced":false,"default":true,
         "urls":{"vtt":"/media/s/t/subtitles/e3.vtt"}}],"markers":[{"kind":"intro","start":30,"end":75.5}],
         "skip":{"intro":true,"recap":false,"credits":false},"up_next_seconds":10,
         "next_up":{"kind":"episode","id":"e2","code":"S01E02","title":"Half Loop","show_title":"Severance","image":null,"playlist_id":null}}
        """
        let session = try decoder.decode(PlaybackSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.markers.first?.kind, "intro")
        XCTAssertEqual(session.skip?.intro, true)
        XCTAssertEqual(session.nextUp?.label, "S01E02 · Half Loop")
        XCTAssertEqual(session.subtitles.first?.vtt, "/media/s/t/subtitles/e3.vtt")
        XCTAssertEqual(PlayerModel.skipTitle("recap"), "Skip recap")
    }

    // A play carried on a rung down says
    // what it fell from, and AVPlayer's errors are classed the way Stream
    // falls back by.
    func testDecodesAFallbackAndClassesPlayerErrors() throws {
        XCTAssertNil(try fixture("playback_session", as: PlaybackSession.self).fallback)
        let json = """
        {"id":"s","method":"video_transcode","source":{"kind":"hls","url":"/media/s/t/hls/index.m3u8"},"progress_url":"/media/s/t/progress",
         "resume_at":612.5,"duration_seconds":2700,"subtitles":[],"markers":[],
         "fallback":{"from_method":"remux","failure_class":"decode","upgradable":false}}
        """
        let session = try decoder.decode(PlaybackSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.fallback?.fromMethod, "remux")
        XCTAssertEqual(session.fallback?.failureClass, "decode")
        XCTAssertEqual(session.fallback?.upgradable, false)

        XCTAssertEqual(PlayerModel.failureClass(of: NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue)), "decode")
        XCTAssertEqual(PlayerModel.failureClass(of: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)), "network")
        let http = NSError(domain: "CoreMediaErrorDomain", code: -12938, userInfo: [NSLocalizedDescriptionKey: "HTTP 424: Failed Dependency"])
        XCTAssertEqual(PlayerModel.failureClass(of: http), "server")
        XCTAssertEqual(PlayerModel.failureClass(of: NSError(domain: AVFoundationErrorDomain, code: AVError.Code.fileFormatNotRecognized.rawValue)), "unsupported")
    }

    func testDecodesPlaylists() throws {
        let json = """
        [{"id":"p1","title":"Watch later","item_count":2,"from_plex":false,"watch_later":true,"image":null,
          "first":{"kind":"episode","id":"e1"}},
         {"id":"p2","title":"Empty","item_count":0,"from_plex":false,"watch_later":false,"image":null,"first":null}]
        """
        let playlists = try decoder.decode([PlaylistCard].self, from: Data(json.utf8))
        XCTAssertEqual(playlists.first?.first?.id, "e1")
        XCTAssertTrue(playlists.first?.watchLater ?? false)
        XCTAssertNil(playlists.last?.first)
    }

    func testDrawsAPairingQRCode() throws {
        let image = try XCTUnwrap(QRCode.image(for: "http://stream.local/pair?code=ABCD-EFGH"))
        XCTAssertEqual(image.width, image.height)
        XCTAssertGreaterThanOrEqual(image.width, 21)
    }

    func testLabelsAudioTracksAsTheWebDoes() throws {
        let json = #"{"index": 2, "codec": "eac3", "language": null, "title": "Commentary", "channels": 6}"#
        let track = try StreamAPI.decoder.decode(PlaybackSession.Track.self, from: Data(json.utf8))
        XCTAssertEqual(track.label, "Commentary · EAC3 · 5.1")
    }

    func testShowsAFloatingCaptureTimeAsWritten() {
        // A camera's wall clock: no zone to convert from.
        XCTAssertTrue(Captured.moment("2026-08-14T10:12:00").contains("10:12"))
        XCTAssertEqual(Captured.month("2026-08-14T10:12:00").key, "2026-08")
    }

    func testReadsTheTopShelfsLinks() throws {
        XCTAssertEqual(StreamLink(URL(string: "stream://open/movie/northbound")!), .page(kind: "movie", id: "northbound"))
        XCTAssertEqual(StreamLink(URL(string: "stream://play/episode/deep-field-s1e3")!), .play(kind: "episode", id: "deep-field-s1e3"))
        XCTAssertEqual(StreamLink(URL(string: "stream://live/5")!), .live(number: "5"))
        XCTAssertNil(StreamLink(URL(string: "https://example.com/open/movie/x")!))
        XCTAssertNil(StreamLink(URL(string: "stream://open/movie")!))
        for link in [StreamLink.page(kind: "show", id: "a"), .play(kind: "movie", id: "b"), .live(number: "12")] {
            XCTAssertEqual(StreamLink(link.url), link)
        }
        XCTAssertEqual(Route(kind: "show", id: "x"), .show("x"))
        XCTAssertNil(Route(kind: "episode", id: "x"))
    }

    func testTheTopShelfSnapshotRoundTrips() throws {
        let snapshot = TopShelfSnapshot(sections: [.init(title: "Continue watching", items: [
            .init(id: "movie-northbound", title: "Northbound", image: "movie-northbound.jpg", progress: 0.42,
                  display: "stream://open/movie/northbound", play: "stream://play/movie/northbound"),
        ])])
        let decoded = try JSONDecoder().decode(TopShelfSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }
}
