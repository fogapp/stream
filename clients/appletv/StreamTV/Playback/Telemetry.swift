import AVFoundation
import Foundation

/// What a player tells Stream about how a play went (PROPOSAL §4.4), in the
/// web player's shapes (frontend/src/components/player/timing.ts,
/// recoveries.ts, Player.tsx) so the Playback decisions page reads an Apple
/// TV's evening like a browser's: `startup` (press to first frame),
/// `stall` (a wait after the picture first moved, and why AVPlayer waited),
/// `seek` (how long, and whether it landed in the buffer), `recovery` (an
/// error log entry the play got past), and `summary` (the access log's
/// totals when the play ends). Posted to the session's `events` URL
/// (docs/APPLETV_STALLS.md › R0).
struct PlaybackEvents: Encodable {
    struct Event: Encodable, Equatable {
        let kind: String
        let position: Double
        let detail: EventDetail
    }

    let events: [Event]
}

/// A detail in the keys MediaController#events keeps (EVENT_DETAIL); a key
/// left nil is left out.
struct EventDetail: Encodable, Equatable {
    var ms: Int?
    var ready: Bool?
    var seconds: Double?
    var message: String?
    var cause: String?
    var count: Int?
    /// Why AVPlayer waited (reasonForWaitingToPlay), or how an end was noticed.
    var via: String?
    var sessionMs: Int?
    var frameMs: Int?
    var stalls: Int?
    var droppedFrames: Int?
    var watchedSeconds: Int?
    var bitrate: Int?

    enum CodingKeys: String, CodingKey {
        case ms, ready, seconds, message, cause, count, via, stalls, bitrate
        case sessionMs = "session_ms"
        case frameMs = "frame_ms"
        case droppedFrames = "dropped_frames"
        case watchedSeconds = "watched_seconds"
    }
}

/// From the press to the picture moving, each step counted from the press
/// like the web's (timing.ts › startupDetail): the session answered, the
/// first frame. AVPlayer fetches the playlist, init and fragments itself,
/// so those steps are absent, as they are for the web's native HLS.
struct StartupClock: Equatable {
    let requestedAt: Date
    let answeredAt: Date

    func detail(firstFrameAt: Date) -> EventDetail {
        let since = { (at: Date) in max(0, Int((at.timeIntervalSince(requestedAt) * 1000).rounded())) }
        return EventDetail(ms: since(firstFrameAt), sessionMs: since(answeredAt), frameMs: since(firstFrameAt))
    }
}

/// A wait while meant to be playing, after the picture first moved: how
/// long it lasted and why. Waiting before the first frame is startup, not a
/// stall, and is left to StartupClock.
struct StallClock: Equatable {
    private(set) var began: Date?
    private(set) var reason: String?

    mutating func waiting(at: Date, reason: String?) {
        guard began == nil else { return }
        began = at
        self.reason = reason
    }

    /// Playing again: the stall just over, or nil when there wasn't one.
    mutating func resumed(at: Date) -> EventDetail? {
        guard let began else { return nil }
        defer {
            self.began = nil
            reason = nil
        }
        let seconds = (at.timeIntervalSince(began) * 10).rounded() / 10
        return EventDetail(seconds: seconds, via: reason)
    }
}

/// What a play got past by itself, counted by what it was (recoveries.ts):
/// an error log entry, a stalled notification. Drained a few seconds after
/// the first, or when the play ends.
struct RecoveryLog: Equatable {
    private var seen: [String: PlaybackEvents.Event] = [:]
    private var order: [String] = []

    var isEmpty: Bool { seen.isEmpty }

    mutating func add(_ message: String, position: Double, cause: String? = nil) {
        if var before = seen[message] {
            before = PlaybackEvents.Event(kind: "recovery", position: before.position,
                                          detail: EventDetail(message: message, cause: before.detail.cause, count: (before.detail.count ?? 0) + 1))
            seen[message] = before
        } else {
            seen[message] = PlaybackEvents.Event(kind: "recovery", position: position, detail: EventDetail(message: message, cause: cause, count: 1))
            order.append(message)
        }
    }

    mutating func drain() -> [PlaybackEvents.Event] {
        let events = order.compactMap { seen[$0] }
        seen = [:]
        order = []
        return events
    }
}

/// The access log's totals over a play (AVPlayerItemAccessLog): what the
/// web can't see of itself but AVPlayer counts for us.
struct AccessTotals: Equatable {
    var stalls = 0
    var droppedFrames = 0
    var watchedSeconds = 0.0
    var bitrate: Double?
    var startupSeconds: Double?

    /// Each access log event: a stretch of the play, oldest first. Counters
    /// AVPlayer couldn't measure are negative and are left out.
    mutating func add(stalls: Int, droppedFrames: Int, watchedSeconds: Double, bitrate: Double, startupSeconds: Double) {
        if stalls >= 0 { self.stalls += stalls }
        if droppedFrames >= 0 { self.droppedFrames += droppedFrames }
        if watchedSeconds >= 0 { self.watchedSeconds += watchedSeconds }
        if bitrate > 0 { self.bitrate = bitrate }
        if startupSeconds >= 0, self.startupSeconds == nil { self.startupSeconds = startupSeconds }
    }

    var detail: EventDetail {
        EventDetail(ms: startupSeconds.map { Int(($0 * 1000).rounded()) }, stalls: stalls, droppedFrames: droppedFrames,
                    watchedSeconds: Int(watchedSeconds.rounded()), bitrate: bitrate.map { Int($0.rounded()) })
    }

    static func of(_ log: AVPlayerItemAccessLog?) -> AccessTotals? {
        guard let events = log?.events, !events.isEmpty else { return nil }
        var totals = AccessTotals()
        for event in events {
            totals.add(stalls: event.numberOfStalls, droppedFrames: event.numberOfDroppedVideoFrames, watchedSeconds: event.durationWatched,
                       bitrate: event.observedBitrate, startupSeconds: event.startupTime)
        }
        return totals
    }
}

/// Watches one AVPlayer for Stream: the clocks above, driven by the
/// player's own status and logs, posted to the session's events URL.
/// PlayerModel (a title), ChannelDeck (the channel on screen) and
/// StreamPlayerView (a live stream) each attach one.
@MainActor
final class PlayerTelemetry {
    static let recoveriesEvery: Duration = .seconds(5)

    private let player: AVPlayer
    private let events: String?
    private let api: StreamAPI
    private var startup: StartupClock?
    private var stall = StallClock()
    private var recoveries = RecoveryLog()
    private var started = false
    private var stopped = false
    private var observations: [NSKeyValueObservation] = []
    private var notices: [NSObjectProtocol] = []
    private var drainTask: Task<Void, Never>?

    /// `startup` nil when something else reports the first frame (the deck's `tune`).
    init(player: AVPlayer, events: String?, api: StreamAPI, startup: StartupClock?) {
        self.player = player
        self.events = events
        self.api = api
        self.startup = startup
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            let reason = player.reasonForWaitingToPlay?.rawValue
            Task { @MainActor in self?.status(status, reason: reason) }
        })
        if let item = player.currentItem {
            notices.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.errorLogged() }
            })
            notices.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recovered("playbackStalled") }
            })
        }
    }

    /// A seek asked for: `landed` when AVPlayer has what it needs there.
    func seeking(to target: Double) -> (ready: Bool, landed: () -> Void) {
        let ready = player.currentItem?.loadedTimeRanges.contains { range in
            let value = range.timeRangeValue
            return value.start.seconds <= target && target <= (value.start + value.duration).seconds
        } ?? false
        let began = Date()
        return (ready, { [weak self] in
            let ms = Int((Date().timeIntervalSince(began) * 1000).rounded())
            self?.post(PlaybackEvents.Event(kind: "seek", position: target, detail: EventDetail(ms: ms, ready: ready)))
        })
    }

    /// The play is over: what was got past, then the access log's totals.
    func stop() {
        guard !stopped else { return }
        stopped = true
        drainTask?.cancel()
        observations.forEach { $0.invalidate() }
        observations = []
        notices.forEach { NotificationCenter.default.removeObserver($0) }
        notices = []
        var batch = recoveries.drain()
        if let totals = AccessTotals.of(player.currentItem?.accessLog()) {
            batch.append(PlaybackEvents.Event(kind: "summary", position: position, detail: totals.detail))
        }
        post(batch)
    }

    // MARK: -

    private var position: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    private func status(_ status: AVPlayer.TimeControlStatus, reason: String?) {
        guard !stopped else { return }
        let now = Date()
        switch status {
        case .playing:
            if !started {
                started = true
                if let startup { post(PlaybackEvents.Event(kind: "startup", position: position, detail: startup.detail(firstFrameAt: now))) }
            } else if let detail = stall.resumed(at: now) {
                post(PlaybackEvents.Event(kind: "stall", position: position, detail: detail))
            }
        case .waitingToPlayAtSpecifiedRate:
            guard started, reason != AVPlayer.WaitingReason.noItemToPlay.rawValue else { return }
            stall.waiting(at: now, reason: reason.map(Self.shortReason))
        case .paused:
            // Paused by hand mid-stall: the stall is over as far as the viewer is concerned.
            if let detail = stall.resumed(at: now) { post(PlaybackEvents.Event(kind: "stall", position: position, detail: detail)) }
        @unknown default:
            break
        }
    }

    private func errorLogged() {
        guard let event = player.currentItem?.errorLog()?.events.last else { return }
        let message = event.errorStatusCode != 0 ? "HTTP \(event.errorStatusCode)" : event.errorDomain
        recovered(message, cause: event.errorComment)
    }

    private func recovered(_ message: String, cause: String? = nil) {
        guard !stopped else { return }
        recoveries.add(message, position: position, cause: cause)
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            try? await Task.sleep(for: PlayerTelemetry.recoveriesEvery)
            guard !Task.isCancelled, let self else { return }
            self.drainTask = nil
            self.post(self.recoveries.drain())
        }
    }

    private func post(_ event: PlaybackEvents.Event) { post([event]) }

    private func post(_ batch: [PlaybackEvents.Event]) {
        guard let events, !batch.isEmpty else { return }
        let api = api
        Task { await api.postQuietly(events, body: PlaybackEvents(events: batch)) }
    }

    /// "AVPlayerWaitingToMinimizeStallsReason" → "minimizeStalls".
    nonisolated static func shortReason(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("AVPlayerWaiting") { name.removeFirst("AVPlayerWaiting".count) }
        if name.hasSuffix("Reason") { name.removeLast("Reason".count) }
        guard let first = name.first else { return raw }
        return first.lowercased() + name.dropFirst()
    }
}

/// How far ahead AVPlayer buffers (docs/APPLETV_STALLS.md › R4). Left to
/// itself on tvOS it kept a few seconds for the first minute — every slow
/// segment a freeze — then fetched minutes at once and went quiet. Stream's
/// transcoder makes about two minutes ahead of what a player last asked
/// for (Supervisor::AHEAD_PAUSE_MS), so a minute is always there to have.
enum Buffering {
    /// Something on screen: the web player's buffer goal (source.ts).
    static let watching: TimeInterval = 60
    /// A channel tuned ahead, or the guide's glance at one: enough to show
    /// at once when switched to, without reading what nobody may watch.
    static let standby: TimeInterval = 10

    static func item(url: URL, standby: Bool) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = standby ? Self.standby : watching
        return item
    }

    /// A player changing role, on standby or on screen.
    @MainActor static func set(_ player: AVPlayer?, standby: Bool) {
        player?.currentItem?.preferredForwardBufferDuration = standby ? Self.standby : watching
    }
}

/// A subtitle track Stream is still taking out of its file answers 503 with
/// Retry-After (docs/APPLETV_STALLS.md › R5): how long to wait before asking
/// again, or nil when the answer is the answer.
enum SubtitleWait {
    static let patience: TimeInterval = 15 * 60
    static let longest: TimeInterval = 30

    static func delay(status: Int, retryAfter: String?) -> TimeInterval? {
        guard status == 503 else { return nil }
        let seconds = retryAfter.flatMap(TimeInterval.init) ?? 10
        return min(max(seconds, 1), longest)
    }
}
