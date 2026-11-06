import AVFoundation
import SwiftUI
import UIKit

/// A Grid channel on the Apple TV (PROPOSAL §7.7, the web's LivePlayer):
/// up and down on the remote change channel — the neighbours are already
/// tuned, so it's showing another picture — left and right go back or
/// forward ten seconds (never past live), Play/Pause pauses, a click brings
/// up the controls (Restart, Jump to live, the guide over the picture, the
/// last channel), and Menu leaves.
struct LivePlayerView: View {
    enum Focus: Hashable { case surface, play, back, restart, live, guide, last }

    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    let startNumber: String

    @State private var deck: ChannelDeck?
    @State private var guide: Guide?
    @State private var number = ""
    @State private var last: String?
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var miniGuide = false
    @State private var guideStart = GuideGrid.halfHour(Date())
    @State private var now = Date()
    @State private var error: String?
    @FocusState private var focus: Focus?
    @FocusState private var guideFocus: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stations: [GuideStation] { guide?.stations ?? [] }
    private var station: GuideStation? { stations.first { $0.number == number } }
    private var skew: TimeInterval { deck?.active?.skew ?? 0 }
    private var timeZone: String { guide?.timeZone ?? "UTC" }

    var body: some View {
        ZStack {
            Palette.scrim.ignoresSafeArea()
            pictures
            tuningCard
            // In and out rather than faded: tvOS won't give focus to a
            // view that was drawn at opacity 0.
            if controls || miniGuide {
                overlay.transition(.opacity)
            }
            if miniGuide { mini.transition(.slide(from: .bottom, reduceMotion: reduceMotion)) }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: miniGuide)
        .animation(.easeInOut(duration: 0.3), value: controls)
        .onPlayPauseCommand {
            guard let player = deck?.active?.player else { return }
            if player.timeControlStatus == .paused { player.play() } else { player.pause() }
            reveal()
        }
        .task { await start() }
        .task(id: "clock") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
                watchForTheEnd()
            }
        }
        .task(id: "listings") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await loadGuide()
            }
        }
        .onChange(of: focus) { _, focus in
            if focus == .surface { reveal() } else if focus != nil { show() }
        }
        .onDisappear { deck?.stop() }
    }

    // MARK: The picture

    private var pictures: some View {
        ZStack {
            if let deck {
                ForEach(Array(deck.slots.keys), id: \.self) { id in
                    if let player = deck.slots[id]?.player {
                        PlayerLayerView(player: player).ignoresSafeArea().opacity(id == deck.activeId ? 1 : 0)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .focusable(!miniGuide)
        .focusEffectDisabled()
        .focused($focus, equals: .surface)
        .onMoveCommand { direction in
            switch direction {
            case .up: flip(1)
            case .down: flip(-1)
            case .left: seek(by: -10)
            case .right: seek(by: 10)
            @unknown default: break
            }
        }
        .onTapGesture {
            show()
            // Once the row is on screen.
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                focus = .play
            }
        }
        .onExitCommand {
            if controls, deck?.active?.player?.timeControlStatus != .paused {
                hide()
            } else {
                leave()
            }
        }
        .onAppear { focus = .surface }
    }

    /// Between programs, tuning, or a channel that can't play here.
    @ViewBuilder private var tuningCard: some View {
        let slot = deck?.active
        if let error {
            card(title: error, detail: nil)
        } else if slot?.state != .ready || slot == nil {
            let (_, next) = LiveTime.onAt(station?.airings ?? [], now.addingTimeInterval(skew))
            switch slot?.state {
            case .gap:
                card(title: next.map { "Up next at \(LiveTime.clock($0.starts, timeZone: timeZone))" } ?? "Nothing on right now",
                     detail: next?.title)
            case .unavailable, .failed:
                card(title: "This channel can't play here right now.", detail: "Try another with ▲ or ▼.")
            default:
                VStack(spacing: 24) {
                    ProgressView().tint(Palette.primary).scaleEffect(1.6)
                    Text("Tuning to \(number)…").textStyle(.callout, color: Palette.muted)
                }
            }
        }
    }

    private func card(title: String, detail: String?) -> some View {
        VStack(spacing: 14) {
            Text(station.map { "\($0.number) · \($0.name)" } ?? number).textStyle(.eyebrow, color: Palette.muted)
            Text(title).textStyle(.title2).multilineTextAlignment(.center)
            if let detail { Text(detail).textStyle(.body, color: Palette.muted) }
        }
        .padding(.horizontal, 60).padding(.vertical, 44)
        .background(Palette.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.border, lineWidth: 1.5))
    }

    // MARK: The controls

    private var overlay: some View {
        let slot = deck?.active
        let serverNow = now.addingTimeInterval(skew)
        let (current, next) = LiveTime.onAt(station?.airings ?? [], serverNow)
        return VStack(spacing: 0) {
            HStack(alignment: .top) {
                Label("Grid", systemImage: "dot.radiowaves.left.and.right").textStyle(.callout, color: Palette.muted)
                Spacer()
                Text(now.formatted(date: .omitted, time: .shortened)).font(TextStyle.title2.font.monospacedDigit()).foregroundStyle(Palette.foreground)
            }
            .padding(.horizontal, Space.margin).padding(.top, 60).padding(.bottom, 120)
            .background(LinearGradient(colors: [Palette.scrim.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
            Spacer(minLength: 0)
            if !miniGuide {
                VStack(alignment: .leading, spacing: 22) {
                    banner(current: current, next: next, slot: slot, serverNow: serverNow)
                    LiveBar(slot: slot, serverNow: serverNow)
                    row(slot: slot, serverNow: serverNow)
                }
                .padding(.horizontal, Space.margin).padding(.top, 160).padding(.bottom, 56)
                .background(LinearGradient(colors: [.clear, Palette.background.opacity(0.7), Palette.background.opacity(0.95)],
                                           startPoint: .top, endPoint: .bottom))
            }
        }
        .ignoresSafeArea()
    }

    private func banner(current: Airing?, next: Airing?, slot: ChannelDeck.Slot?, serverNow: Date) -> some View {
        HStack(alignment: .bottom, spacing: 36) {
            VStack(spacing: 6) {
                Text(station?.number ?? number).font(.system(size: 76, weight: .semibold, design: .monospaced))
                Text(station?.name ?? "").textStyle(.eyebrow, color: Palette.muted).lineLimit(1)
            }
            .frame(minWidth: 180)
            VStack(alignment: .leading, spacing: 8) {
                Text(current?.title ?? slot?.session?.title ?? "").textStyle(.title2).lineLimit(1)
                if let current {
                    // A stream's channel has no times: it's the stream all day. (A
                    // game on a scheduled channel has its slot's.)
                    Text([current.subtitle, current.contentRating,
                          station?.liveStreamId != nil ? nil
                              : "\(LiveTime.clock(current.starts, timeZone: timeZone)) – \(LiveTime.clock(current.ends, timeZone: timeZone))"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .textStyle(.callout, color: Palette.muted).lineLimit(1)
                }
                if let next {
                    Text("Next at \(LiveTime.clock(next.starts, timeZone: timeZone)): \(next.title)\(next.subtitle.map { " · \($0)" } ?? "")")
                        .textStyle(.caption, color: Palette.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if behind(slot, serverNow) < 8 {
                LivePill()
            } else {
                Text("−\(Clock.format(behind(slot, serverNow))) behind live").textStyle(.callout, color: Palette.muted)
            }
        }
        .foregroundStyle(Palette.foreground)
    }

    private func row(slot: ChannelDeck.Slot?, serverNow: Date) -> some View {
        let paused = slot?.player?.timeControlStatus == .paused
        return HStack(spacing: 18) {
            ControlButton(label: paused ? "Play" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") {
                guard let player = deck?.active?.player else { return }
                if player.timeControlStatus == .paused { player.play() } else { player.pause() }
            }
            .focused($focus, equals: .play)
            ControlButton(label: "Back 10 seconds", systemImage: "gobackward.10") { seek(by: -10) }
                .focused($focus, equals: .back)
            if slot?.session?.liveStream == nil {
                ControlButton(label: "Restart this program", systemImage: "backward.end.fill") { restart() }
                    .focused($focus, equals: .restart)
            }
            if behind(slot, serverNow) >= 8 {
                ControlButton(label: "Jump to live", systemImage: "dot.radiowaves.left.and.right") { jumpToLive() }
                    .focused($focus, equals: .live)
            }
            if let slot, slot.session?.liveStream == nil, let live = slot.session?.live, let player = slot.player {
                let base = live.mediaStart ?? 0
                let length = live.ends.timeIntervalSince(live.starts)
                Text("\(Clock.format(max(player.currentTime().seconds - base, 0))) / \(Clock.format(length))")
                    .font(TextStyle.callout.font.monospacedDigit()).foregroundStyle(Palette.muted)
                    .padding(.leading, 10)
            }
            Spacer(minLength: 0)
            if let last, stations.contains(where: { $0.number == last }) {
                ControlButton(label: "Back to \(last)", systemImage: "arrow.uturn.backward") { change(to: last) }
                    .focused($focus, equals: .last)
            }
            ControlButton(label: "Guide", systemImage: "square.grid.3x3.topleft.filled") { openGuide() }
                .focused($focus, equals: .guide)
        }
        .focusSection()
        .onMoveCommand { if $0 == .up { focus = .surface } }
        .onExitCommand { focus = .surface }
    }

    private func behind(_ slot: ChannelDeck.Slot?, _ serverNow: Date) -> Double {
        if let slot, slot.session?.liveStream != nil, let player = slot.player, let deck {
            return max((deck.streamEdge(player) ?? 0) - player.currentTime().seconds, 0)
        }
        guard let slot, let live = slot.session?.live, let player = slot.player else { return 0 }
        return max(LiveTime.position(live, at: serverNow) - player.currentTime().seconds, 0)
    }

    // MARK: The guide over the picture

    /// The next few hours of every channel along the bottom, starting on
    /// the one being watched, so browsing never stops what's on.
    private var mini: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("What's on").textStyle(.title2)
                Spacer()
                Text("Choose what's on to change channel · Menu to close").textStyle(.caption, color: Palette.muted)
            }
            GuideGrid(stations: stations, timeZone: timeZone, now: now, start: $guideStart,
                      reach: GuideGrid.halfHour(Date())...Date().addingTimeInterval(8 * 3600),
                      sizes: .init(channelWidth: 200, rowHeight: 88, headerHeight: 48, span: 2.5 * 3600),
                      focus: $guideFocus,
                      choose: { station, airing in
                          let now = Date()
                          guard airing.starts <= now, airing.ends > now else { return }
                          closeGuide()
                          change(to: station.number)
                      })
        }
        .padding(.horizontal, Space.margin).padding(.top, 36).padding(.bottom, 40)
        .frame(maxWidth: .infinity)
        .frame(height: 620)
        .background(Palette.background.opacity(0.95).ignoresSafeArea())
        .frame(maxHeight: .infinity, alignment: .bottom)
        .onExitCommand { closeGuide() }
    }

    private func openGuide() {
        guideStart = GuideGrid.halfHour(Date())
        miniGuide = true
        if let station, let airing = LiveTime.onAt(station.airings, Date()).current { guideFocus = airing.id }
    }

    private func closeGuide() {
        miniGuide = false
        focus = .surface
    }

    // MARK: Showing and hiding

    private func reveal() {
        show()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, focus == .surface, !miniGuide, deck?.active?.player?.timeControlStatus != .paused else { return }
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

    // MARK: -

    private func start() async {
        number = startNumber
        deck = ChannelDeck(api: state.api, deviceKey: state.deviceKey)
        await loadGuide()
        arrange()
        reveal()
    }

    private func loadGuide() async {
        do {
            guide = try await state.api.get("api/v1/guide")
            error = station == nil && guide != nil ? "There's no channel \(number)." : nil
        } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }

    private func arrange() {
        guard let deck, let station else { return }
        let up = LiveTime.adjacent(stations, number: number, step: 1, numberOf: \.number)
        let down = LiveTime.adjacent(stations, number: number, step: -1, numberOf: \.number)
        let previous = last.flatMap { wanted in stations.first { $0.number == wanted } }
        deck.arrange(active: station.id, neighbours: [up?.id, down?.id, previous?.id].compactMap { $0 })
    }

    private func flip(_ step: Int) {
        guard let target = LiveTime.adjacent(stations, number: number, step: step, numberOf: \.number) else { return }
        change(to: target.number)
    }

    private func change(to target: String) {
        guard target != number else { return }
        last = number
        number = target
        arrange()
        reveal()
    }

    private func seek(by seconds: Double) {
        guard let slot = deck?.active, let player = slot.player, let deck else { return }
        let floor = slot.session?.liveStream != nil ? deck.streamStart(player) : slot.session?.live?.mediaStart ?? 0
        let target = min(max(player.currentTime().seconds + seconds, floor), deck.livePosition(slot))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        reveal()
    }

    private func jumpToLive() {
        guard let slot = deck?.active, let player = slot.player, let deck else { return }
        player.seek(to: CMTime(seconds: deck.livePosition(slot), preferredTimescale: 600))
        player.play()
    }

    /// Back to the program's beginning: its first part when it airs in parts.
    private func restart() {
        guard let slot = deck?.active, let live = slot.session?.live else { return }
        let parts = (station?.airings ?? []).filter { airing in
            airing.playableId == station?.airings.first(where: { $0.id == live.airingId })?.playableId && airing.starts <= live.starts
        }
        let first = parts.first { ($0.mediaStart ?? 0) == 0 }
        if (live.mediaStart ?? 0) == 0 || first == nil {
            slot.player?.seek(to: CMTime(seconds: live.mediaStart ?? 0, preferredTimescale: 600))
        } else {
            deck?.retune(airingId: first?.id, start: 0)
        }
    }

    /// A program over (or a part of one): the next, as far behind live as the viewer was.
    private func watchForTheEnd() {
        guard let deck, let slot = deck.active, let live = slot.session?.live, let player = slot.player, slot.state == .ready else { return }
        // A game on a channel is a stream with a slot: over when the slot is.
        if slot.session?.liveStream != nil {
            if live.ends <= Date().addingTimeInterval(slot.skew) { deck.retune() }
            return
        }
        let time = player.currentTime().seconds
        let fileEnd = player.currentItem?.duration.seconds ?? .infinity
        let partEnd = live.mediaEnd ?? fileEnd
        guard time.isFinite, time >= partEnd - 0.25 || (fileEnd.isFinite && time >= fileEnd - 0.25) else { return }
        let serverNow = Date().addingTimeInterval(slot.skew)
        let behind = max(LiveTime.position(live, at: serverNow) - time, 0)
        let following = (station?.airings ?? []).first { $0.starts >= live.ends.addingTimeInterval(-1) }
        player.pause()
        if let following, following.starts <= serverNow, behind > 5 {
            let offset = LiveTime.offset(starts: following.starts, ends: following.ends, at: serverNow)
            deck.retune(airingId: following.id, start: (following.mediaStart ?? 0) + max(offset - behind, 0))
        } else {
            deck.retune()
        }
    }

    private func leave() {
        deck?.stop()
        playback.stopLive()
    }
}

/// An AVPlayer's picture, without AVKit's controls: Grid has its own.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// The program's timeline (the web's live bar): how far live has got,
/// where the picture is in cyan, and a red mark at live.
struct LiveBar: View {
    let slot: ChannelDeck.Slot?
    let serverNow: Date

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let (played, live) = fractions
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.foreground.opacity(0.2))
                Rectangle().fill(Palette.foreground.opacity(0.3)).frame(width: width * live)
                Rectangle().fill(Palette.primary).frame(width: width * played)
            }
            .frame(height: 10)
            .clipShape(Capsule())
            .overlay(alignment: .leading) {
                Rectangle().fill(Palette.negative).frame(width: 5, height: 28).offset(x: width * live - 2.5)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Position in this program")
    }

    private var fractions: (played: CGFloat, live: CGFloat) {
        guard let slot, let live = slot.session?.live, let player = slot.player else { return (0, 0) }
        let length = live.ends.timeIntervalSince(live.starts)
        guard length > 0 else { return (0, 0) }
        // A game's slot, by the clock: a stream has no place in a file.
        if slot.session?.liveStream != nil {
            let done = CGFloat(min(max(serverNow.timeIntervalSince(live.starts) / length, 0), 1))
            return (done, done)
        }
        let base = live.mediaStart ?? 0
        let atLive = LiveTime.position(live, at: serverNow) - base
        let at = player.currentTime().seconds - base
        return (CGFloat(min(max(at / length, 0), 1)), CGFloat(min(max(atLive / length, 0), 1)))
    }
}
