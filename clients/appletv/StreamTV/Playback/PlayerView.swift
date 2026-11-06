import AVFoundation
import SwiftUI

/// Pressing Play (PROPOSAL §6.2) on an Apple TV: ask Stream for a session
/// with this device's capabilities, and play the original file or the HLS
/// stream it answers with, behind Stream's own controls (the web's player,
/// for a remote).
struct PlayerView: View {
    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    let request: PlaybackCoordinator.Request
    @State private var model: PlayerModel?
    @State private var error: String?

    var body: some View {
        ZStack {
            Palette.scrim.ignoresSafeArea()
            if let model {
                PlayerScreen(model: model, request: request)
            } else if let error {
                VStack(spacing: 36) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 64)).foregroundStyle(Palette.negative)
                    Text("This didn't play").textStyle(.title2)
                    Text(error).textStyle(.body, color: Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 1100)
                    Button("Close") { playback.stop() }.buttonStyle(.secondary)
                }
                .onExitCommand { playback.stop() }
            } else {
                VStack(spacing: 30) {
                    ProgressView().tint(Palette.primary).scaleEffect(1.6)
                    Text("Starting…").textStyle(.callout, color: Palette.muted)
                }
                .focusable()
                .onExitCommand { playback.stop() }
            }
        }
        .task { await start() }
        .onDisappear {
            model?.finish()
            if playback.player === model?.player { playback.player = nil }
        }
    }

    private func start() async {
        let requestedAt = Date()
        do {
            let body = SessionBody(playableType: request.kind, playableId: request.playableId, capabilities: Capabilities.current(),
                                   deviceKey: state.deviceKey, start: request.start, burnSubtitle: request.burnSubtitle,
                                   audioIndex: request.audioIndex, playlistId: request.playlistId)
            let session: PlaybackSession = try await state.api.post("api/v1/playback_sessions", body: body)
            try await begin(session, startup: StartupClock(requestedAt: requestedAt, answeredAt: Date()))
        } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }

    /// Plays a session the server answered with: the first, or one a
    /// failed play carried on as (carryOn). `startup` is when it was asked
    /// for and answered, for the startup event.
    private func begin(_ session: PlaybackSession, startup: StartupClock) async throws {
        guard let url = state.api.absolute(session.source.url) else { throw APIError(status: 0, messages: ["No stream to play."]) }
        let player = AVPlayer(playerItem: Buffering.item(url: url, standby: false))
        let coordinator = playback
        let limit = session.stillWatchingAfter ?? 3
        var actions = PlayerModel.Actions()
        actions.next = { next, automatic in
            if automatic {
                // Still watching? is the card's to ask; here it only counts.
                coordinator.advance(kind: next.kind, id: next.id, playlistId: next.playlistId, limit: 0)
            } else {
                coordinator.play(kind: next.kind, id: next.id, playlistId: next.playlistId)
            }
        }
        actions.ended = {
            if !coordinator.advance(kind: nil, id: nil, playlistId: nil, limit: 0) { coordinator.stop() }
        }
        actions.restart = { burn, audio, position in coordinator.restart(burning: burn, audio: audio, at: position) }
        actions.fallback = { failureClass, cause, position in
            Task { await carryOn(from: session, failureClass: failureClass, cause: cause, position: position) }
        }
        let model = PlayerModel(session: session, player: player, api: state.api,
                                stillWatching: limit > 0 && coordinator.runOfAutomatic >= limit, startup: startup, actions: actions)
        self.model = model
        playback.player = player
        await model.start()
    }

    /// A play that failed carries on a rung down the ladder, from where it
    /// got to; with no rung left, the
    /// server says what it tried, and that's what's shown.
    private func carryOn(from session: PlaybackSession, failureClass: String, cause: String, position: Double) async {
        let failed = model
        let requestedAt = Date()
        do {
            let body = FallbackBody(failureClass: failureClass, cause: cause, position: position)
            let next: PlaybackSession = try await state.api.post("api/v1/playback_sessions/\(session.id)/fallback", body: body)
            failed?.finish()
            model = nil
            try await begin(next, startup: StartupClock(requestedAt: requestedAt, answeredAt: Date()))
        } catch {
            failed?.finish()
            model = nil
            self.error = error.localizedDescription
        }
    }
}

private struct FallbackBody: Encodable {
    let failureClass: String
    let cause: String
    let position: Double
}

private struct SessionBody: Encodable {
    let playableType: String
    let playableId: String
    let capabilities: Capabilities
    let deviceKey: String
    let start: Double?
    let burnSubtitle: Int?
    let audioIndex: Int?
    let playlistId: String?
}

/// The picture and everything over it. The picture holds focus while
/// watching: a click plays or pauses, left and right jump ten seconds, a
/// swipe scrubs (a click keeps where it landed, Menu lets it go), down
/// goes to the row of buttons, Menu hides the controls and then leaves.
private struct PlayerScreen: View {
    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    let model: PlayerModel
    let request: PlaybackCoordinator.Request

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: PlayerFocus?
    @State private var controls = true
    @State private var panel: PlayerPanel?
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubIdle: Task<Void, Never>?
    /// A swipe also arrives as a move command; this keeps it from jumping too.
    @State private var lastPan = Date.distantPast
    @State private var related: (title: String, items: [Card])?

    var body: some View {
        reactingToPrompts
            .onChange(of: model.playing) { _, playing in
                if playing { reveal() } else { show() }
            }
            .onChange(of: focus) { _, focus in
                if focus == .surface { reveal() } else if focus != nil { show() }
            }
            .onPlayPauseCommand(perform: click)
            .onAppear {
                focus = .surface
                reveal()
            }
            .task { related = await loadRelated() }
            .task { await showcaseScrub() }
    }

    /// The showcase's screenshots of a scrub (-StreamShowcaseScrub 12),
    /// since a UI test's remote can't swipe.
    private func showcaseScrub() async {
        guard state.showcase, UserDefaults.standard.object(forKey: "StreamShowcaseScrub") != nil else { return }
        try? await Task.sleep(for: .seconds(2))
        model.beginScrub()
        model.scrub(by: UserDefaults.standard.double(forKey: "StreamShowcaseScrub") - model.current)
        show()
    }

    private var layers: some View {
        ZStack {
            picture
            if model.stalled && model.scrubTime == nil {
                ProgressView().tint(Palette.primary).scaleEffect(1.8).allowsHitTesting(false)
            }
            CaptionView(model: model, raised: controls)
                .opacity(model.scrubTime == nil ? 1 : 0)
            // In and out rather than faded: tvOS won't give focus to a view
            // that was drawn at opacity 0.
            if controls {
                overlay.transition(.opacity)
            }
            prompts
                .opacity(model.scrubTime == nil ? 1 : 0)
                .disabled(model.scrubTime != nil)
            if let panel { sheet(panel).transition(.slide(from: .trailing, reduceMotion: reduceMotion)) }
            if let failure = model.failure { failed(failure) }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: panel)
        .animation(.easeInOut(duration: 0.3), value: controls)
    }

    /// Each prompt takes focus as it comes and gives it back as it goes.
    private var reactingToPrompts: some View {
        let skip: Set<PlayerFocus> = [.skip, .alwaysSkip]
        let upNext: Set<PlayerFocus> = [.upNextPlay, .upNextDismiss]
        return layers
            .onChange(of: model.activeMarker) { _, marker in steer(marker != nil, to: .skip, from: skip) }
            .onChange(of: model.askingSegment) { _, segment in steer(segment != nil, to: .sponsor, from: [.sponsor]) }
            .onChange(of: model.sponsorSkipped) { _, skipped in steer(skipped != nil, to: .undo, from: [.undo]) }
            .onChange(of: model.showUpNext) { _, shown in steer(shown, to: .upNextPlay, from: upNext) }
            .onChange(of: model.failure) { _, failure in if failure != nil { focus = .close } }
    }

    // MARK: The picture

    private var picture: some View {
        PlayerLayerView(player: model.player)
            .background(touchSurface)
            .focusable(panel == nil)
            .focusEffectDisabled()
            .focused($focus, equals: .surface)
            .onTapGesture(perform: click)
            .onMoveCommand(perform: move)
            .onExitCommand(perform: menu)
            .accessibilityLabel(model.session.title ?? "Video")
    }

    private var touchSurface: TouchSurface {
        TouchSurface(enabled: focus == .surface && panel == nil,
                     began: {
                         touched()
                         lastPan = Date()
                         model.beginScrub()
                         show()
                     },
                     moved: { dx in
                         lastPan = Date()
                         model.scrub(by: Double(dx) * model.secondsPerPoint)
                         idleScrub()
                     },
                     ended: { lastPan = Date() })
    }

    /// Select: keep a scrub where it landed, else play or pause.
    private func click() {
        touched()
        if model.scrubTime != nil { model.commitScrub() } else { model.togglePlay() }
        reveal()
    }

    private func move(_ direction: MoveCommandDirection) {
        touched()
        switch direction {
        case .left, .right:
            guard Date().timeIntervalSince(lastPan) > 0.4 else { return }
            let by: Double = direction == .left ? -10 : 10
            if model.scrubTime != nil {
                model.scrub(by: by)
                idleScrub()
            } else {
                model.jump(by: by)
            }
            reveal()
        case .down:
            show()
            // Once the row is on screen.
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                focus = .play
            }
        case .up:
            reveal()
        @unknown default:
            break
        }
    }

    /// Menu: let a scrub go, else hide the controls, else leave.
    private func menu() {
        if model.scrubTime != nil {
            model.cancelScrub()
            reveal()
        } else if controls && model.playing {
            hide()
        } else {
            close()
        }
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            PlayerTopBar(model: model)
            Spacer(minLength: 0)
            PlayerBottomBar(model: model, hasRelated: related.map { !$0.items.isEmpty } ?? false, focus: $focus,
                            open: { panel = $0 }, back: { focus = .surface })
                .disabled(panel != nil)
                .onExitCommand { focus = .surface }
        }
    }

    // MARK: What asks for a press

    @ViewBuilder private var prompts: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                sponsor
                Spacer()
                if model.showUpNext, let next = model.session.nextUp {
                    UpNextCard(next: next, left: model.upNextLeft, stillWatching: model.stillWatching, focus: $focus,
                               play: {
                                   touched()
                                   model.playNext(automatic: false)
                               },
                               dismiss: {
                                   if model.stillWatching { close() } else { model.dismissUpNext() }
                               })
                        .onExitCommand { model.dismissUpNext() }
                        .transition(.slide(from: .trailing, reduceMotion: reduceMotion))
                } else if let marker = model.activeMarker {
                    HStack(spacing: 18) {
                        if model.session.showId != nil {
                            Button("Always skip") { model.alwaysSkip(marker) }
                                .buttonStyle(.ghost)
                                .focused($focus, equals: .alwaysSkip)
                        }
                        Button { model.skip(marker) } label: { Label(PlayerModel.skipTitle(marker.kind), systemImage: "forward.end.fill") }
                            .buttonStyle(.secondary)
                            .focused($focus, equals: .skip)
                    }
                    .focusSection()
                    .onExitCommand { focus = .surface }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, Space.margin)
            .padding(.bottom, controls ? 360 : 90)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controls)
        }
        .animation(.easeInOut(duration: 0.25), value: model.showUpNext)
        .animation(.easeInOut(duration: 0.25), value: model.activeMarker)
    }

    @ViewBuilder private var sponsor: some View {
        if let skipped = model.sponsorSkipped {
            HStack(spacing: 20) {
                Label("Skipped \(skipped.label.lowercased())", systemImage: "forward.fill").textStyle(.callout)
                Button("Undo") { model.undoSponsorSkip() }
                    .buttonStyle(.stream(.ghost, compact: true))
                    .focused($focus, equals: .undo)
            }
            .padding(.leading, 28).padding(.trailing, 12).padding(.vertical, 10)
            .background(Palette.surface.opacity(0.95), in: Capsule())
            .onExitCommand { focus = .surface }
            .transition(.opacity)
        } else if let segment = model.askingSegment {
            Button { model.seek(to: segment.end) } label: { Label("Skip \(segment.label.lowercased())", systemImage: "forward.end.fill") }
                .buttonStyle(.secondary)
                .focused($focus, equals: .sponsor)
                .onExitCommand { focus = .surface }
                .transition(.opacity)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 30) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 56)).foregroundStyle(Palette.negative)
            Text(message).textStyle(.body).multilineTextAlignment(.center).frame(maxWidth: 1000)
            Button("Close") { close() }.buttonStyle(.secondary).focused($focus, equals: .close)
        }
        .padding(60)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onExitCommand { close() }
    }

    // MARK: Sheets

    @ViewBuilder private func sheet(_ panel: PlayerPanel) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                switch panel {
                case .subtitles:
                    PlayerSheet(title: "Subtitles") {
                        ForEach(Array(subtitleChoices.enumerated()), id: \.offset) { index, choice in
                            SheetOption(label: choice.label, detail: choice.detail, selected: choice.selected) { self.choose(choice.track) }
                                .focused($focus, equals: .option(index))
                        }
                    }
                case .audio:
                    PlayerSheet(title: "Audio") {
                        ForEach(Array((model.session.mediaFile?.audio ?? []).enumerated()), id: \.offset) { index, track in
                            SheetOption(label: track.label, selected: track.index == model.session.audioStreamIndex) {
                                close(panel: .audio)
                                model.chooseAudio(track)
                            }
                            .focused($focus, equals: .option(index))
                        }
                    }
                case .speed:
                    PlayerSheet(title: "Speed") {
                        ForEach(Array(PlayerModel.speeds.enumerated()), id: \.offset) { index, speed in
                            SheetOption(label: speedLabel(speed), selected: model.rate == speed) {
                                model.setRate(speed)
                                close(panel: .speed)
                            }
                            .focused($focus, equals: .option(index))
                        }
                    }
                case .related:
                    PlayerSheet(title: related?.title ?? "Related") {
                        ForEach(Array((related?.items ?? []).enumerated()), id: \.offset) { index, card in
                            RelatedRow(card: card, playing: isPlaying(card)) {
                                guard !isPlaying(card) else { return close(panel: .related) }
                                model.finish()
                                playback.play(kind: card.kind, id: card.id, playlistId: model.session.playlistId)
                            }
                            .focused($focus, equals: .option(index))
                        }
                    }
                }
            }
            .onExitCommand { close(panel: panel) }
            // Focus goes to the choice in use (the one playing, in Related).
            .onAppear { focus = .option(selectedIndex(panel)) }
        }
    }

    private struct SubtitleChoice {
        let label: String
        var detail: String?
        let selected: Bool
        let track: PlaybackSession.Subtitle?
    }

    private var subtitleChoices: [SubtitleChoice] {
        let burned = model.session.burnedSubtitle
        return [SubtitleChoice(label: "Off", selected: model.subtitle == nil && burned == nil, track: nil)]
            + model.textTracks.map { SubtitleChoice(label: $0.label, selected: model.subtitle == $0 && burned == nil, track: $0) }
            + model.pictureTracks.map {
                SubtitleChoice(label: $0.label, detail: "Drawn into the picture; restarts the stream", selected: burned == $0.id, track: $0)
            }
    }

    private func selectedIndex(_ panel: PlayerPanel) -> Int {
        let index: Int? = switch panel {
        case .subtitles: subtitleChoices.firstIndex(where: \.selected)
        case .audio: model.session.mediaFile?.audio.firstIndex { $0.index == model.session.audioStreamIndex }
        case .speed: PlayerModel.speeds.firstIndex(of: model.rate)
        case .related: related?.items.firstIndex(where: isPlaying)
        }
        return index ?? 0
    }

    private func isPlaying(_ card: Card) -> Bool {
        card.kind == request.kind && card.id == request.playableId
    }

    private func choose(_ track: PlaybackSession.Subtitle?) {
        close(panel: .subtitles)
        model.choose(track)
    }

    private func close(panel closing: PlayerPanel) {
        panel = nil
        focus = switch closing {
        case .subtitles: .subtitles
        case .audio: .audio
        case .speed: .speed
        case .related: .related
        }
    }

    /// What's related (the web's Related panel): the playlist it came from,
    /// the episode's season, a film's neighbours, the rest of a channel.
    private func loadRelated() async -> (String, [Card])? {
        let api = state.api
        if let playlist = model.session.playlistId {
            guard let detail: PlaylistDetail = try? await api.get("api/v1/playlists/\(playlist)") else { return nil }
            return (detail.title, detail.items)
        }
        switch request.kind {
        case "episode":
            guard let show = model.session.showId, let number = model.session.seasonNumber,
                  let season: SeasonDetail = try? await api.get("api/v1/shows/\(show)/seasons/\(number)") else { return nil }
            return (season.title, season.episodes.filter(\.available).map { $0.card(show: nil) })
        case "movie":
            guard let similar: [Card] = try? await api.get("api/v1/movies/\(request.playableId)/similar") else { return nil }
            return ("More like this", similar.filter { $0.kind == "movie" })
        case "video":
            guard let video: VideoDetail = try? await api.get("api/v1/videos/\(request.playableId)") else { return nil }
            return (video.channel?.title ?? "More from this channel", [video.card] + (video.moreFromChannel ?? []))
        default:
            return nil
        }
    }

    // MARK: Showing and hiding

    /// Controls up; down again after a few seconds of nothing, if playing
    /// and focus is on the picture.
    private func reveal() {
        show()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, model.playing, focus == .surface, panel == nil, model.scrubTime == nil else { return }
            controls = false
        }
    }

    private func show() {
        hideTask?.cancel()
        controls = true
    }

    private func hide() {
        hideTask?.cancel()
        controls = false
    }

    /// A scrub nobody finishes lets itself go.
    private func idleScrub() {
        scrubIdle?.cancel()
        scrubIdle = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            model.cancelScrub()
            reveal()
        }
    }

    /// A prompt that asks for a press takes focus from the picture when it
    /// comes, and gives it back when it goes.
    private func steer(_ shown: Bool, to target: PlayerFocus, from owned: Set<PlayerFocus>) {
        if shown {
            // Never mid-scrub: the picture keeps the remote until it's done.
            if model.scrubTime == nil, focus == .surface || focus == nil { focus = target }
        } else if let current = focus, owned.contains(current) {
            focus = .surface
        }
    }

    private func touched() {
        playback.touched()
    }

    private func close() {
        model.finish()
        playback.stop()
    }
}

extension PlayerModel {
    nonisolated static func skipTitle(_ kind: String) -> String {
        switch kind {
        case "intro": return "Skip intro"
        case "recap": return "Skip recap"
        case "credits": return "Skip credits"
        default: return "Skip"
        }
    }
}

extension VideoDetail {
    /// The video itself, as the Related panel lists it.
    var card: Card {
        Card(kind: "video", id: id, title: title, code: nil, year: nil, images: images, progress: nil, watched: watched,
             show: nil, seasonNumber: nil, episodeNumber: nil, unwatchedCount: nil, arrival: nil,
             durationSeconds: durationSeconds, channel: channel)
    }
}

/// The current cue, low and centred, legible over anything; up out of the
/// way while the controls are showing.
struct CaptionView: View {
    let model: PlayerModel
    var raised = false

    var body: some View {
        VStack {
            Spacer()
            if let caption = model.caption {
                Text(caption)
                    .font(.system(size: 44, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.foreground)
                    .shadow(color: Palette.scrim, radius: 3)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Palette.scrim.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, raised ? 330 : 90)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: raised)
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}
