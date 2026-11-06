import AVFoundation
import Foundation
import Observation

/// The channels a Grid screen holds (PROPOSAL §7.7): the one on screen,
/// and its neighbours — up, down, the last one — each tuned on standby in
/// its own AVPlayer, sought to live and prerolled, so changing channel is
/// showing another player. A neighbour that would need converting isn't
/// tuned ahead. Each change is timed and reported to Stream.
@MainActor
@Observable
final class ChannelDeck {
    enum State: Equatable { case tuning, ready, gap, unavailable, failed }

    struct Slot {
        var session: PlaybackSession?
        var player: AVPlayer?
        var state: State = .tuning
        var standby = true
        var skew: TimeInterval = 0
        var ticket = 0
        /// Watching the player while this channel is the one on screen.
        var telemetry: PlayerTelemetry?
        /// When Stream last heard this channel is still held on standby.
        var heldAt = Date.distantPast
    }

    /// How often a channel held on standby tells Stream it still is
    /// (docs/APPLETV_STALLS.md › R3): well inside the two minutes after
    /// which the transcoder stops a run nobody has fetched from.
    static let holdEvery: TimeInterval = 45

    private(set) var slots: [String: Slot] = [:]
    private(set) var activeId: String?
    @ObservationIgnored private let api: StreamAPI
    @ObservationIgnored private let deviceKey: String
    @ObservationIgnored private var keepLive: Task<Void, Never>?

    init(api: StreamAPI, deviceKey: String) {
        self.api = api
        self.deviceKey = deviceKey
        keepLive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                await self?.nudgeStandby()
                self?.heartbeat()
            }
        }
    }

    var active: Slot? { activeId.flatMap { slots[$0] } }

    /// Tune what's wanted, let go of the rest; the active one plays.
    func arrange(active: String, neighbours: [String]) {
        let wanted = [active] + neighbours.filter { $0 != active }
        for id in slots.keys where !wanted.contains(id) { release(id) }
        let previous = activeId
        activeId = active
        for id in wanted where slots[id] == nil {
            slots[id] = Slot(standby: id != active)
            Task { await tune(id, body: TuneBody(stationId: id)) }
        }
        guard previous != active else { return }
        if let previous, let old = slots[previous]?.player {
            old.isMuted = true
            old.pause()
            Buffering.set(old, standby: true)
            slots[previous]?.telemetry?.stop()
            slots[previous]?.telemetry = nil
            // Changed away from, kept for Last: not a play any more, and its
            // run kept (the web's deck says the same).
            if let session = slots[previous]?.session, slots[previous]?.standby == false {
                slots[previous]?.standby = true
                slots[previous]?.heldAt = Date()
                let api = api
                let position = old.currentTime().seconds
                Task { await api.postQuietly("api/v1/playback_sessions/\(session.id)/standby", body: Watch(position: position.isFinite ? position : 0)) }
            }
        }
        activate(active)
    }

    /// Another airing on the channel on screen: the next program, or this
    /// one from the start (behind live).
    func retune(airingId: String? = nil, start: Double? = nil) {
        guard let id = activeId else { return }
        Task { await tune(id, body: airingId == nil ? TuneBody(stationId: id) : TuneBody(airingId: airingId, start: start)) }
    }

    func stop() {
        keepLive?.cancel()
        for id in slots.keys { release(id) }
    }

    // MARK: -

    private func activate(_ id: String) {
        guard var slot = slots[id] else { return }
        let began = Date()
        let ready = slot.state == .ready && slot.player?.currentItem?.status == .readyToPlay
        switch slot.state {
        case .gap, .unavailable, .failed:
            Task { await tune(id, body: TuneBody(stationId: id)) }
        case .ready, .tuning:
            if let session = slot.session, slot.standby {
                slot.standby = false
                slots[id] = slot
                let api = api
                Task { await api.postQuietly("api/v1/playback_sessions/\(session.id)/watch", body: Watch(position: livePosition(slot))) }
            }
            if let player = slot.player {
                player.isMuted = false
                Buffering.set(player, standby: false)
                if slot.session?.liveStream == nil || streamEdge(player) != nil {
                    player.seek(to: CMTime(seconds: livePosition(slot), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
                }
                player.play()
                timeFirstFrame(id, player: player, since: began, ready: ready)
                // The first frame is the tune event's; stalls and the summary are the telemetry's.
                slot.telemetry?.stop()
                slot.telemetry = PlayerTelemetry(player: player, events: slot.session?.eventsUrl, api: api, startup: nil)
                slots[id] = slot
            }
        }
    }

    private func tune(_ id: String, body: TuneBody) async {
        guard var slot = slots[id] else { return }
        slot.ticket += 1
        let ticket = slot.ticket
        slot.telemetry?.stop()
        slot.telemetry = nil
        if let session = slot.session { Task { [api] in try? await api.delete("api/v1/playback_sessions/\(session.id)") } }
        slot.player?.letGo()
        slot.player = nil
        slot.session = nil
        slot.state = .tuning
        slot.standby = id != activeId
        slots[id] = slot
        var request = body
        request.standby = slot.standby
        request.capabilities = Capabilities.current()
        request.deviceKey = deviceKey
        do {
            let session: PlaybackSession = try await api.post("api/v1/playback_sessions", body: request)
            guard var current = slots[id], current.ticket == ticket else {
                try? await api.delete("api/v1/playback_sessions/\(session.id)")
                return
            }
            guard let url = api.absolute(session.source.url) else { throw APIError(status: 0, messages: ["No stream to play."]) }
            let player = AVPlayer(playerItem: Buffering.item(url: url, standby: id != activeId))
            player.isMuted = id != activeId
            current.session = session
            current.player = player
            current.skew = session.live.map { LiveTime.skew(serverNow: $0.serverNow) } ?? 0
            current.state = .ready
            current.heldAt = Date()
            slots[id] = current
            // A stream's channel is a live playlist: AVPlayer opens it at its newest.
            if session.liveStream == nil {
                let from = body.start ?? livePosition(current)
                await player.seek(to: CMTime(seconds: from, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            }
            if id == activeId {
                player.play()
            } else {
                await preroll(player)
            }
        } catch let error as APIError where error.status == 409 {
            let message = error.messages.first ?? ""
            slots[id]?.state = message.contains("right now") || message.contains("started") ? .gap : .unavailable
        } catch {
            slots[id]?.state = .failed
        }
    }

    /// Standby: buffered and decoded at live, paused, ready to show.
    private func preroll(_ player: AVPlayer) async {
        for _ in 0..<50 where player.currentItem?.status != .readyToPlay {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard player.currentItem?.status == .readyToPlay, player.rate == 0 else { return }
        _ = await player.preroll(atRate: 1)
    }

    private func release(_ id: String) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        slot.telemetry?.stop()
        slot.player?.letGo()
        if let session = slot.session { Task { [api] in try? await api.delete("api/v1/playback_sessions/\(session.id)") } }
    }

    /// Every few seconds: where the channel on screen is, as the web's live
    /// player says it (it keeps the session seen, so the transcoder keeps
    /// its run while AVPlayer's buffer is full and it fetches nothing, and
    /// Grid watching is counted); and, now and then, that each channel on
    /// standby is still held.
    private func heartbeat() {
        let api = api
        for (id, slot) in slots {
            guard let session = slot.session, slot.state == .ready else { continue }
            if id == activeId && !slot.standby {
                guard let player = slot.player, player.timeControlStatus != .paused else { continue }
                let position = player.currentTime().seconds
                guard position.isFinite else { continue }
                Task { await api.postQuietly(session.progressUrl, body: DeckProgress(position: max(0, position), ended: false)) }
            } else if slot.standby, Date().timeIntervalSince(slot.heldAt) >= Self.holdEvery {
                slots[id]?.heldAt = Date()
                let position = slot.player?.currentTime().seconds ?? 0
                Task { await api.postQuietly("api/v1/playback_sessions/\(session.id)/standby", body: Watch(position: position.isFinite ? position : 0)) }
            }
        }
    }

    /// Standby channels stay at live, and move on when their program ends.
    private func nudgeStandby() async {
        for (id, slot) in slots where id != activeId {
            if slot.state == .gap || (slot.session?.live.map { $0.ends <= Date().addingTimeInterval(slot.skew) } ?? false) {
                await tune(id, body: TuneBody(stationId: id))
                continue
            }
            guard slot.state == .ready, let player = slot.player else { continue }
            if slot.session?.liveStream != nil, streamEdge(player) == nil { continue }
            await player.seek(to: CMTime(seconds: livePosition(slot), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            await preroll(player)
        }
    }

    func livePosition(_ slot: Slot) -> Double {
        if slot.session?.liveStream != nil, let player = slot.player { return max((streamEdge(player) ?? 0) - 3, 0) }
        guard let live = slot.session?.live else { return slot.session?.resumeAt ?? 0 }
        return LiveTime.position(live, at: Date().addingTimeInterval(slot.skew))
    }

    /// The newest a live playlist reaches (a stream's channel), once AVPlayer knows.
    func streamEdge(_ player: AVPlayer) -> Double? {
        guard let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return nil }
        let end = CMTimeRangeGetEnd(range).seconds
        return end.isFinite && end > 0 ? end : nil
    }

    /// The oldest a live playlist still has: how far back a stream's channel goes.
    func streamStart(_ player: AVPlayer) -> Double {
        player.currentItem?.seekableTimeRanges.first?.timeRangeValue.start.seconds ?? 0
    }

    /// From the press to the picture moving, told to Stream as a `tune` event.
    private func timeFirstFrame(_ id: String, player: AVPlayer, since began: Date, ready: Bool) {
        let api = api
        Task { [weak self] in
            for _ in 0..<500 {
                if player.timeControlStatus == .playing { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let session = self?.slots[id]?.session, let events = session.eventsUrl else { return }
            let milliseconds = Int(Date().timeIntervalSince(began) * 1000)
            await api.postQuietly(events, body: PlaybackEvents(events: [.init(kind: "tune", position: player.currentTime().seconds,
                                                                              detail: EventDetail(ms: milliseconds, ready: ready))]))
        }
    }
}

struct TuneBody: Encodable {
    var stationId: String? = nil
    var airingId: String? = nil
    var start: Double? = nil
    var standby = false
    var capabilities: Capabilities? = nil
    var deviceKey: String? = nil
}

private struct Watch: Encodable {
    let position: Double
}

private struct DeckProgress: Encodable {
    let position: Double
    let ended: Bool
}

