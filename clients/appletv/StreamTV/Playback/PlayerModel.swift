import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// One playback on the Apple TV, behind Stream's own controls (PROPOSAL
/// §7.3, as the web's player): where the playhead is, what's buffered,
/// the subtitle cue on screen, Skip intro and its Always skip, SponsorBlock,
/// Up next with its countdown, scrubbing with thumbnails, speed, and
/// telling Stream — and the system's Now Playing — where the viewer is.
@MainActor
@Observable
final class PlayerModel {
    /// What the player asks of whoever opened it.
    struct Actions {
        /// Play what's next; automatic when the countdown or the end did it.
        var next: (PlaybackSession.NextUp, _ automatic: Bool) -> Void = { _, _ in }
        /// Finished with nothing next.
        var ended: () -> Void = {}
        /// The same title again from here: a picture subtitle burned in (or
        /// not), or another audio track.
        var restart: (_ burn: Int?, _ audio: Int?, _ position: Double) -> Void = { _, _, _ in }
        /// This play can't go on as it is: carry it on a rung down the
        /// ladder from here. nil shows
        /// why it stopped instead.
        var fallback: ((_ failureClass: String, _ cause: String, _ position: Double) -> Void)?
    }

    /// A wait this long while meant to be playing is a play that's stuck.
    static let stallLimit: Duration = .seconds(30)

    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    let session: PlaybackSession
    let player: AVPlayer
    /// Up next asks rather than counts: episodes in a row with nobody touching anything.
    let stillWatching: Bool
    private let api: StreamAPI
    private let actions: Actions

    private(set) var current: Double = 0
    private(set) var duration: Double
    private(set) var buffered: Double = 0
    private(set) var playing = false
    /// Waiting for bytes while meant to be playing.
    private(set) var stalled = false
    private(set) var failure: String?
    private(set) var rate: Float = 1

    /// The words on screen now, and the track they come from.
    private(set) var caption: String?
    private(set) var subtitle: PlaybackSession.Subtitle?

    /// What this profile always skips (Always skip changes it here too).
    private(set) var skip: PlaybackSession.Skip
    /// A SponsorBlock span skipped a moment ago, to take back.
    private(set) var sponsorSkipped: PlaybackSession.Segment?

    /// Where the scrub head is while someone scrubs; nil when they aren't.
    private(set) var scrubTime: Double?

    /// Up next was waved away ("Watch credits").
    private(set) var upNextDismissed = false
    /// Seconds until Up next plays itself.
    private(set) var upNextLeft = 0

    @ObservationIgnored private var cues: WebVTT?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var commands: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var lastNowPlaying = Date.distantPast
    @ObservationIgnored private var skippedMarkers: Set<String> = []
    @ObservationIgnored private var skippedSegments: Set<String> = []
    @ObservationIgnored private var upNextDeadline: Date?
    @ObservationIgnored private var sponsorToastTask: Task<Void, Never>?
    @ObservationIgnored private var sheets: [Int: CGImage] = [:]
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var fellBack = false
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    /// What this play tells Stream about itself (docs/APPLETV_STALLS.md › R0).
    @ObservationIgnored private var telemetry: PlayerTelemetry?
    @ObservationIgnored private let startup: StartupClock

    private static let languageKey = "subtitleLanguage"

    /// `startup`: when Play was pressed and when the session was answered,
    /// so the first frame is counted from the press like the web's.
    init(session: PlaybackSession, player: AVPlayer, api: StreamAPI, stillWatching: Bool = false,
         startup: StartupClock = StartupClock(requestedAt: Date(), answeredAt: Date()), actions: Actions) {
        self.session = session
        self.player = player
        self.api = api
        self.stillWatching = stillWatching
        self.startup = startup
        self.actions = actions
        duration = session.durationSeconds ?? 0
        skip = session.skip ?? PlaybackSession.Skip(intro: false, recap: false, credits: false)
        current = session.resumeAt
    }

    func start() async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        telemetry = PlayerTelemetry(player: player, events: session.eventsUrl, api: api, startup: startup)
        if session.resumeAt > 0 {
            await player.seek(to: CMTime(seconds: session.resumeAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.statusChanged(status) }
        })
        if let item = player.currentItem {
            observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let failureClass = PlayerModel.failureClass(of: item.error)
                let message = item.error?.localizedDescription
                Task { @MainActor in self?.failed(failureClass, message) }
            })
            observations.append(item.observe(\.duration, options: [.new]) { [weak self] item, _ in
                let seconds = item.duration.seconds
                Task { @MainActor in if seconds.isFinite, seconds > 0 { self?.duration = seconds } }
            })
        }
        takeRemoteCommands()
        player.play()
        // A burned-in subtitle is in the picture already.
        if session.burnedSubtitle == nil { await select(defaultSubtitle()) }
    }

    // MARK: Playing

    func togglePlay() {
        if playing { pause() } else { play() }
    }

    func play() {
        if duration > 0, current >= duration - 0.5 { seek(to: 0) }
        player.playImmediately(atRate: rate)
    }

    func pause() {
        player.pause()
        report(current, force: true)
    }

    func seek(to seconds: Double) {
        let upper = duration > 0 ? duration - 0.5 : seconds
        let target = min(max(seconds, 0), max(upper, 0))
        current = target
        caption = cues?.text(at: target)
        let seeking = telemetry?.seeking(to: target)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard finished else { return }
            Task { @MainActor in seeking?.landed() }
        }
        publishNowPlaying()
    }

    func jump(by seconds: Double) { seek(to: current + seconds) }

    func setRate(_ value: Float) {
        rate = value
        player.defaultRate = value
        if playing { player.rate = value }
        publishNowPlaying()
    }

    private func statusChanged(_ status: AVPlayer.TimeControlStatus) {
        playing = status != .paused
        let waiting = status == .waitingToPlayAtSpecifiedRate && player.reasonForWaitingToPlay != .noItemToPlay
        if waiting && !stalled {
            stallTask?.cancel()
            stallTask = Task { [weak self] in
                try? await Task.sleep(for: PlayerModel.stallLimit)
                guard !Task.isCancelled, let self, self.stalled else { return }
                self.failed("stalled", "waited 30 s for the stream")
            }
        } else if !waiting {
            stallTask?.cancel()
        }
        stalled = waiting
        publishNowPlaying()
    }

    /// Carried on a rung down, once; only with nowhere to go is the viewer told why.
    private func failed(_ failureClass: String, _ message: String?) {
        guard !fellBack, !finished else { return }
        fellBack = true
        report(current, force: true)
        if let fallback = actions.fallback {
            fallback(failureClass, String((message ?? "AVPlayer failed").prefix(300)), current)
        } else {
            failure = "Playback stopped" + (message.map { ": \($0)" } ?? ".")
        }
    }

    /// AVPlayer's error in the classes the server falls back by
    /// (PlaybackSession::FailureClass).
    nonisolated static func failureClass(of error: Error?) -> String {
        guard let error = error as NSError? else { return "unsupported" }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        if error.domain == NSURLErrorDomain || underlying?.domain == NSURLErrorDomain { return "network" }
        if error.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: error.code) {
            case .decodeFailed?, .decoderNotFound?, .decoderTemporarilyUnavailable?, .mediaServicesWereReset?: return "decode"
            default: break
            }
        }
        // CoreMedia carries an HTTP failure's status: 424 is the transcoder giving up.
        if "\(error) \(underlying.map { "\($0)" } ?? "")".contains("424") { return "server" }
        return "unsupported"
    }

    // MARK: Scrubbing (the touch surface)

    func beginScrub() {
        if scrubTime == nil { scrubTime = current }
    }

    func scrub(by seconds: Double) {
        let from = scrubTime ?? current
        scrubTime = min(max(from + seconds, 0), duration > 0 ? duration : from + seconds)
    }

    func commitScrub() {
        guard let scrubTime else { return }
        self.scrubTime = nil
        seek(to: scrubTime)
    }

    func cancelScrub() { scrubTime = nil }

    /// How far a point of swipe moves the scrub head: a full swipe across
    /// the surface covers about half of a film.
    var secondsPerPoint: Double { max(duration / 4000, 0.05) }

    // MARK: Trickplay

    /// The thumbnail for a moment, cut from its sprite sheet.
    func thumbnail(at seconds: Double) async -> UIImage? {
        guard let trickplay = session.trickplay, trickplay.count > 0 else { return nil }
        let index = min(max(Int(seconds / trickplay.interval), 0), trickplay.count - 1)
        let perSheet = trickplay.columns * trickplay.rows
        let sheetIndex = index / perSheet
        let within = index % perSheet
        if sheets[sheetIndex] == nil {
            let path = trickplay.sheetUrl.replacingOccurrences(of: "{index}", with: String(sheetIndex))
            guard let url = api.absolute(path), let image = await ImagePipeline.shared.image(url), let cg = image.cgImage else { return nil }
            sheets[sheetIndex] = cg
        }
        guard let sheet = sheets[sheetIndex] else { return nil }
        // Tiles by the sheet's own pixels, in case it was made at another scale.
        let tileWidth = CGFloat(sheet.width) / CGFloat(trickplay.columns)
        let tileHeight = CGFloat(sheet.height) / CGFloat(trickplay.rows)
        let rect = CGRect(x: CGFloat(within % trickplay.columns) * tileWidth, y: CGFloat(within / trickplay.columns) * tileHeight,
                          width: tileWidth, height: tileHeight)
        return sheet.cropping(to: rect.integral).map { UIImage(cgImage: $0) }
    }

    /// The chapter a moment falls in.
    func chapter(at seconds: Double) -> PlaybackSession.Chapter? {
        session.chapters?.first { seconds >= $0.start && seconds < $0.end }
    }

    // MARK: Subtitles

    /// Text tracks the app draws itself.
    var textTracks: [PlaybackSession.Subtitle] { session.subtitles.filter { $0.vtt != nil } }
    /// Pictures (PGS, DVD, DVB): Stream draws them into the video.
    var pictureTracks: [PlaybackSession.Subtitle] { session.subtitles.filter { $0.vtt == nil && $0.burnable } }

    /// A forced track (signs, foreign dialogue) always; else the language
    /// chosen last time; else the file's default, if any.
    private func defaultSubtitle() -> PlaybackSession.Subtitle? {
        let tracks = textTracks
        if let forced = tracks.first(where: \.forced) { return forced }
        if let language = UserDefaults.standard.string(forKey: Self.languageKey) {
            return language.isEmpty ? nil : tracks.first { $0.language == language && !$0.forced }
        }
        return tracks.first { $0.default == true }
    }

    /// Off, a text track, or a picture track (which restarts the stream).
    func choose(_ track: PlaybackSession.Subtitle?) {
        if let track, track.vtt == nil {
            guard let index = track.streamIndex, session.burnedSubtitle != track.id else { return }
            actions.restart(index, session.audioStreamIndex, current)
            return
        }
        if session.burnedSubtitle != nil {
            if track != nil { UserDefaults.standard.set(track?.language ?? "", forKey: Self.languageKey) }
            actions.restart(nil, session.audioStreamIndex, current)
            return
        }
        Task { await select(track, remember: true) }
    }

    func select(_ track: PlaybackSession.Subtitle?, remember: Bool = false) async {
        subtitle = track
        cues = nil
        caption = nil
        if remember { UserDefaults.standard.set(track?.language ?? "", forKey: Self.languageKey) }
        guard let track, let path = track.vtt, let url = api.absolute(path) else { return }
        // Still being taken out of the file: asked again when Stream says
        // (docs/APPLETV_STALLS.md › R5), for as long as it's the pick.
        let giveUpAt = Date().addingTimeInterval(SubtitleWait.patience)
        var fetched: Data?
        while subtitle == track, !finished {
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { return }
            let http = response as? HTTPURLResponse
            guard let delay = SubtitleWait.delay(status: http?.statusCode ?? 200, retryAfter: http?.value(forHTTPHeaderField: "Retry-After")) else {
                fetched = (http?.statusCode ?? 200) == 200 ? data : nil
                break
            }
            guard Date().addingTimeInterval(delay) < giveUpAt else { return }
            try? await Task.sleep(for: .seconds(delay))
        }
        guard let data = fetched, let text = String(data: data, encoding: .utf8) else { return }
        guard subtitle == track else { return }
        cues = WebVTT(parsing: text)
        caption = cues?.text(at: current)
    }

    func chooseAudio(_ track: PlaybackSession.Track) {
        guard track.index != session.audioStreamIndex else { return }
        actions.restart(session.burnedSubtitle.flatMap { id in session.subtitles.first { $0.id == id }?.streamIndex }, track.index, current)
    }

    // MARK: Skip intro, SponsorBlock

    /// Intro, recap or credits under the playhead, offered as a button —
    /// credits only when Up next isn't there to take them.
    var activeMarker: PlaybackSession.Marker? {
        guard let marker = session.markers.first(where: { current >= $0.start && current < $0.end - 1 }) else { return nil }
        if marker.kind == "credits", session.nextUp != nil { return nil }
        return skipsItself(marker) ? nil : marker
    }

    /// Skip it this time.
    func skip(_ marker: PlaybackSession.Marker) { seek(to: marker.end) }

    /// Skip it every time on this show, starting now.
    func alwaysSkip(_ marker: PlaybackSession.Marker) {
        skip = PlaybackSession.Skip(intro: skip.intro || marker.kind == "intro", recap: skip.recap || marker.kind == "recap",
                                    credits: skip.credits || marker.kind == "credits")
        if let show = session.showId {
            let api = api
            let body = SkipPreference(kind: marker.kind)
            Task { await api.patchQuietly("api/v1/shows/\(show)/preferences", body: body) }
        }
        seek(to: marker.end)
    }

    private func skipsItself(_ marker: PlaybackSession.Marker) -> Bool {
        switch marker.kind {
        case "intro": return skip.intro
        case "recap": return skip.recap
        case "credits": return skip.credits
        default: return false
        }
    }

    /// A span set to ask, under the playhead.
    var askingSegment: PlaybackSession.Segment? {
        session.segments?.first { $0.action == "ask" && current >= $0.start && current < $0.end - 0.5 }
    }

    func undoSponsorSkip() {
        guard let skipped = sponsorSkipped else { return }
        sponsorSkipped = nil
        seek(to: skipped.start)
    }

    // MARK: Up next

    /// At the credits, or in the last seconds when there are none marked.
    var showUpNext: Bool {
        guard session.nextUp != nil, !upNextDismissed, duration > 0 else { return false }
        return current >= creditsAt
    }

    private var creditsAt: Double {
        if let credits = session.markers.first(where: { $0.kind == "credits" }) { return credits.start }
        return duration > 120 ? duration - max(session.upNextSeconds ?? 10, 20) : .infinity
    }

    func playNext(automatic: Bool) {
        guard let next = session.nextUp else { return }
        finish()
        actions.next(next, automatic)
    }

    func dismissUpNext() {
        upNextDismissed = true
        upNextDeadline = nil
    }

    // MARK: Every quarter second

    private func tick(_ time: Double) {
        guard time.isFinite else { return }
        current = time
        caption = cues?.text(at: time)
        if let range = player.currentItem?.loadedTimeRanges.last?.timeRangeValue {
            buffered = (range.start + range.duration).seconds
        }
        report(time)
        if Date().timeIntervalSince(lastNowPlaying) > 15 { publishNowPlaying() }

        if let marker = session.markers.first(where: { time >= $0.start && time < $0.end - 1 }), skipsItself(marker) {
            let key = "\(marker.kind):\(marker.start)"
            if !skippedMarkers.contains(key) {
                skippedMarkers.insert(key)
                if marker.kind == "credits", session.nextUp != nil { playNext(automatic: true) } else { seek(to: marker.end) }
                return
            }
        }

        if let segment = session.segments?.first(where: { $0.action == "skip" && time >= $0.start && time < $0.end - 0.5 }) {
            let key = "\(segment.category):\(segment.start)"
            if !skippedSegments.contains(key) {
                skippedSegments.insert(key)
                seek(to: segment.end)
                sponsorSkipped = segment
                sponsorToastTask?.cancel()
                sponsorToastTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    self?.sponsorSkipped = nil
                }
            }
        }

        if showUpNext, !stillWatching, playing {
            let deadline = upNextDeadline ?? Date().addingTimeInterval(session.upNextSeconds ?? 10)
            upNextDeadline = deadline
            upNextLeft = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
            if upNextLeft <= 0 { playNext(automatic: true) }
        } else if !showUpNext {
            upNextDeadline = nil
            upNextLeft = Int(session.upNextSeconds ?? 10)
        }
    }

    private func ended() {
        if session.nextUp != nil {
            // Still watching? waits on screen for an answer.
            if stillWatching {
                upNextDismissed = false
                current = duration
                return
            }
            playNext(automatic: true)
            return
        }
        finish()
        actions.ended()
    }

    // MARK: Telling Stream, and the system

    private func report(_ time: Double, ended: Bool = false, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastReport) >= 10 else { return }
        lastReport = Date()
        let api = api
        let path = session.progressUrl
        Task { await api.postQuietly(path, body: Progress(position: max(0, time), ended: ended)) }
    }

    private func publishNowPlaying() {
        guard !finished else { return }
        lastNowPlaying = Date()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: session.title ?? "Stream",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: current,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let subtitle = session.subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Control Center and the phone's remote: play, pause, ±10 s, a position, next.
    private func takeRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ handle: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let token = command.addTarget { event in
                MainActor.assumeIsolated { handle(event) }
                return .success
            }
            commands.append((command, token))
        }
        on(center.playCommand) { [weak self] _ in self?.play() }
        on(center.pauseCommand) { [weak self] _ in self?.pause() }
        on(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlay() }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        on(center.skipForwardCommand) { [weak self] _ in self?.jump(by: 10) }
        on(center.skipBackwardCommand) { [weak self] _ in self?.jump(by: -10) }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: event.positionTime) }
        }
        if session.nextUp != nil {
            on(center.nextTrackCommand) { [weak self] _ in self?.playNext(automatic: false) }
        }
    }

    /// Stopped, one way or another: say where, once, and let go.
    func finish() {
        guard !finished else { return }
        let position = player.currentTime().seconds
        telemetry?.stop()
        player.letGo()
        report(position.isFinite ? position : 0, ended: true, force: true)
        finished = true
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        observations.forEach { $0.invalidate() }
        observations = []
        for (command, token) in commands { command.removeTarget(token) }
        commands = []
        sponsorToastTask?.cancel()
        stallTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

private struct Progress: Encodable {
    let position: Double
    let ended: Bool
}

/// PATCH /shows/:id/preferences: skip_intro, skip_recap or skip_credits.
private struct SkipPreference: Encodable {
    let kind: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(["skip_\(kind)": true])
    }
}

extension AVPlayer {
    /// Done with it: a paused player still buffers its item, and a SwiftUI
    /// player layer can keep it alive after we drop it — asking Stream for
    /// segments of a session that's been ended, hundreds of 404s a minute.
    /// Without an item it fetches nothing.
    func letGo() {
        pause()
        replaceCurrentItem(with: nil)
    }
}
