import AVFoundation
import SwiftUI

/// The top of a page (the web's Hero): the backdrop fading into the page
/// from the bottom and the left, the logo (or the title), and what the page
/// puts under it. After a moment a trailer plays behind it, muted — never
/// with Reduce Motion — and the page can offer to unmute it.
struct Hero<Content: View>: View {
    let images: [String: Artwork]?
    let title: String
    var trailer: URL?
    var height: CGFloat = 820
    @Binding var trailerMuted: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVPlayer?
    @State private var playing = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            VStack(alignment: .leading, spacing: 26) {
                if let logo = images?["logo"] {
                    ArtworkImage(artwork: logo, width: 720, contentMode: .fit, logo: true, fallback: title)
                        .frame(width: 720, height: 200, alignment: .leading)
                        .accessibilityLabel(title)
                } else {
                    Text(title).textStyle(.display).lineLimit(2).frame(maxWidth: 1300, alignment: .leading)
                }
                content()
            }
            .padding(.horizontal, Space.margin)
            .padding(.bottom, 56)
        }
        .frame(height: height)
        .task(id: trailer) { await startTrailer() }
        .onDisappear {
            player?.pause()
            playing = false
        }
        .onChange(of: trailerMuted) { _, muted in player?.isMuted = muted }
    }

    private var backdrop: some View {
        ZStack {
            ArtworkImage(artwork: images?["backdrop"] ?? images?["thumb"], width: 1920)
            if let player, playing {
                PlayerLayerView(player: player, gravity: .resizeAspectFill).transition(.opacity)
            }
            LinearGradient(stops: [.init(color: Palette.background.opacity(0.1), location: 0), .init(color: Palette.background.opacity(0.62), location: 0.55),
                                   .init(color: Palette.background, location: 0.9), .init(color: Palette.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: [.init(color: Palette.background.opacity(0.92), location: 0), .init(color: Palette.background.opacity(0.4), location: 0.5),
                                   .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
        }
        // Under the narrow sidebar too, to the screen's edge.
        .padding(.leading, -Sidebar.collapsed)
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }

    private func startTrailer() async {
        player?.pause()
        playing = false
        guard let trailer, !reduceMotion else { return }
        try? await Task.sleep(for: .seconds(2.5))
        guard !Task.isCancelled else { return }
        let item = AVPlayerItem(url: trailer)
        let player = AVPlayer(playerItem: item)
        player.isMuted = trailerMuted
        self.player = player
        player.play()
        withAnimation(.easeInOut(duration: 0.8)) { playing = true }
        let ended = NotificationCenter.default.notifications(named: .AVPlayerItemDidPlayToEndTime, object: item)
        for await _ in ended {
            withAnimation(.easeInOut(duration: 0.8)) { playing = false }
            break
        }
    }
}
