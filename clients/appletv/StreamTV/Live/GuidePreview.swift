import AVFoundation
import SwiftUI

/// The guide's preview window (PROPOSAL §7.7, the web's GuidePreview): the
/// focused channel, live and muted, over its program's still until the
/// picture arrives. Tuned on standby (never a play) once focus has settled
/// on it, and let go when focus moves on.
struct GuidePreview: View {
    @Environment(AppState.self) private var state
    let stationId: String?
    let airing: Airing?
    var size = CGSize(width: 400, height: 225)

    @State private var player: AVPlayer?
    @State private var picture = false

    private var onNow: Bool {
        guard let airing else { return false }
        let now = Date()
        return airing.starts <= now && airing.ends > now
    }

    var body: some View {
        ZStack {
            ArtworkImage(artwork: airing?.still, width: size.width, fallback: airing?.title ?? "")
            if let player {
                PlayerLayerView(player: player, gravity: .resizeAspectFill)
                    .opacity(picture ? 1 : 0)
                    .animation(.easeIn(duration: 0.3), value: picture)
            }
            if onNow {
                VStack {
                    HStack {
                        Spacer()
                        LivePill(compact: true).padding(12)
                    }
                    Spacer()
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.border, lineWidth: 1.5))
        .task(id: onNow ? stationId : nil) { await tune() }
    }

    private func tune() async {
        picture = false
        player = nil
        guard onNow, let stationId else { return }
        // Only once focus has settled here.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        let api = state.api
        guard let session: PlaybackSession = try? await api.post("api/v1/playback_sessions",
                                                                 body: TuneBody(stationId: stationId, standby: true, capabilities: Capabilities.current(),
                                                                                deviceKey: state.deviceKey)) else { return }
        defer { Task { try? await api.delete("api/v1/playback_sessions/\(session.id)") } }
        guard !Task.isCancelled, let url = api.absolute(session.source.url) else { return }
        let player = AVPlayer(playerItem: Buffering.item(url: url, standby: true))
        defer { player.letGo() }
        player.isMuted = true
        let skew = session.live.map { LiveTime.skew(serverNow: $0.serverNow) } ?? 0
        // A stream (a game on a channel, too) plays from its newest; a file, from where live is.
        if session.liveStream == nil {
            let at = session.live.map { LiveTime.position($0, at: Date().addingTimeInterval(skew)) } ?? session.resumeAt
            await player.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        }
        guard !Task.isCancelled else { return }
        self.player = player
        player.play()
        // Showing once it moves; held until focus leaves (the task is cancelled).
        for _ in 0..<100 where player.timeControlStatus != .playing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        picture = player.timeControlStatus == .playing
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
    }
}

/// The web's red LIVE mark.
struct LivePill: View {
    var compact = false

    var body: some View {
        Label("Live", systemImage: "dot.radiowaves.left.and.right")
            .font((compact ? TextStyle.caption : TextStyle.callout).font.weight(.bold))
            .textCase(.uppercase)
            .tracking(1.5)
            .foregroundStyle(Palette.foreground)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 4 : 8)
            .background(Palette.negative, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}
