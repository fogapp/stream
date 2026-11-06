import AVFoundation
import SwiftUI

/// A camera or web stream, full screen (PROPOSAL §7.8, the web's
/// StreamWatch): Stream relays it, so it's live HLS AVPlayer opens at its
/// newest. Play/Pause pauses, left and right go back or forward ten seconds
/// within what the relay keeps, a click shows the controls (Jump to live),
/// and when the source drops it says it's reconnecting until the picture's
/// back. Menu leaves.
struct StreamPlayerView: View {
    enum Focus: Hashable { case surface, play, back, live }

    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    let request: PlaybackCoordinator.StreamRequest

    @State private var session: PlaybackSession?
    @State private var player: AVPlayer?
    @State private var telemetry: PlayerTelemetry?
    @State private var error: String?
    @State private var relay: LiveProgress.Relay?
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var now = Date()
    @FocusState private var focus: Focus?

    var body: some View {
        ZStack {
            Palette.scrim.ignoresSafeArea()
            if let player { PlayerLayerView(player: player).ignoresSafeArea() }
            if let error {
                message(error, detail: nil)
            } else if player == nil || !playing && relay?.state != "reconnecting" && player?.currentItem?.status != .readyToPlay {
                VStack(spacing: 24) {
                    ProgressView().tint(Palette.primary).scaleEffect(1.6)
                    Text("Connecting to \(request.name)…").textStyle(.callout, color: Palette.muted)
                }
            } else if relay?.state == "reconnecting" {
                message("Reconnecting…", detail: relay?.message)
            }
            if controls { overlay.transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.3), value: controls)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .surface)
        .onMoveCommand { direction in
            switch direction {
            case .left: seek(by: -10)
            case .right: seek(by: 10)
            default: break
            }
        }
        .onTapGesture { show(); focus = .play }
        .onPlayPauseCommand { togglePlay() }
        .onExitCommand {
            if controls, focus != .surface { focus = .surface; reveal() } else { leave() }
        }
        .onAppear { focus = .surface }
        .task { await start() }
        .task(id: "report") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(relay?.state == "reconnecting" ? 2 : 10))
                await report()
            }
        }
        .task(id: "clock") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
        .onDisappear { stop() }
    }

    private var playing: Bool { player?.timeControlStatus == .playing }

    private var behind: Double {
        guard let player, let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return 0 }
        return max(CMTimeRangeGetEnd(range).seconds - player.currentTime().seconds, 0)
    }

    private func message(_ title: String, detail: String?) -> some View {
        VStack(spacing: 14) {
            Text(request.name).textStyle(.eyebrow, color: Palette.muted)
            Text(title).textStyle(.title2).multilineTextAlignment(.center)
            if let detail { Text(detail).textStyle(.body, color: Palette.muted).multilineTextAlignment(.center) }
        }
        .padding(.horizontal, 60).padding(.vertical, 44)
        .background(Palette.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.border, lineWidth: 1.5))
    }

    private var overlay: some View {
        let paused = player?.timeControlStatus == .paused
        let _ = now
        return VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session?.title ?? request.name).textStyle(.title2).lineLimit(1)
                    if let subtitle = session?.subtitle { Text(subtitle).textStyle(.callout, color: Palette.muted).lineLimit(1) }
                }
                Spacer()
                if behind < 12 {
                    LivePill()
                } else {
                    Text("−\(Clock.format(behind)) behind live").textStyle(.callout, color: Palette.muted)
                }
            }
            .padding(.horizontal, Space.margin).padding(.top, 60).padding(.bottom, 120)
            .background(LinearGradient(colors: [Palette.scrim.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
            Spacer(minLength: 0)
            HStack(spacing: 18) {
                ControlButton(label: paused ? "Play" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") { togglePlay() }
                    .focused($focus, equals: .play)
                ControlButton(label: "Back 10 seconds", systemImage: "gobackward.10") { seek(by: -10) }
                    .focused($focus, equals: .back)
                if behind >= 12 {
                    ControlButton(label: "Jump to live", systemImage: "dot.radiowaves.left.and.right") { jumpToLive() }
                        .focused($focus, equals: .live)
                }
                Spacer(minLength: 0)
            }
            .focusSection()
            .padding(.horizontal, Space.margin).padding(.top, 160).padding(.bottom, 56)
            .background(LinearGradient(colors: [.clear, Palette.background.opacity(0.7), Palette.background.opacity(0.95)],
                                       startPoint: .top, endPoint: .bottom))
            .onMoveCommand { if $0 == .up { focus = .surface } }
        }
        .ignoresSafeArea()
    }

    // MARK: -

    private func start() async {
        let requestedAt = Date()
        do {
            let made: PlaybackSession = try await state.api.post("api/v1/playback_sessions", body: StreamBody(
                playableId: request.streamId, capabilities: Capabilities.current(), deviceKey: state.deviceKey), timeout: 60)
            guard let url = state.api.absolute(made.source.url) else { throw APIError(status: 0, messages: ["No stream to play."]) }
            session = made
            let player = AVPlayer(url: url)
            self.player = player
            playback.player = player
            telemetry = PlayerTelemetry(player: player, events: made.eventsUrl, api: state.api,
                                        startup: StartupClock(requestedAt: requestedAt, answeredAt: Date()))
            player.play()
            reveal()
        } catch {
            state.handle(error)
            self.error = (error as? APIError)?.messages.first ?? error.localizedDescription
        }
    }

    /// Where the viewer is, which keeps the session open; the answer says
    /// how the relay is doing.
    private func report(ended: Bool = false) async {
        guard let session, let player else { return }
        let position = player.currentTime().seconds
        let answer: LiveProgress? = try? await state.api.post(session.progressUrl,
                                                              body: StreamProgress(position: position.isFinite ? position : 0, ended: ended))
        relay = answer?.relay
    }

    private func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        reveal()
    }

    private func seek(by seconds: Double) {
        guard let player, let item = player.currentItem,
              let first = item.seekableTimeRanges.first?.timeRangeValue, let last = item.seekableTimeRanges.last?.timeRangeValue else { return }
        let target = min(max(player.currentTime().seconds + seconds, first.start.seconds), CMTimeRangeGetEnd(last).seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        reveal()
    }

    private func jumpToLive() {
        guard let player, let last = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return }
        player.seek(to: CMTime(seconds: max(CMTimeRangeGetEnd(last).seconds - 3, 0), preferredTimescale: 600))
        player.play()
        focus = .surface
    }

    private func reveal() {
        controls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, focus == .surface, player?.timeControlStatus != .paused else { return }
            controls = false
        }
    }

    private func show() {
        hideTask?.cancel()
        controls = true
    }

    private func stop() {
        let session = session
        let player = player
        Task { [state] in
            if let session, let player {
                await state.api.postQuietly(session.progressUrl, body: StreamProgress(position: player.currentTime().seconds, ended: true))
            }
        }
        telemetry?.stop()
        telemetry = nil
        player?.letGo()
        playback.player = nil
    }

    private func leave() {
        stop()
        playback.stopStream()
    }
}

private struct StreamBody: Encodable {
    let playableType = "live_stream"
    let playableId: String
    let capabilities: Capabilities
    let deviceKey: String
}

private struct StreamProgress: Encodable {
    let position: Double
    let ended: Bool
}
