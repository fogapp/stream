import SwiftUI

/// Every design piece in every state, for looking at (the UI tests
/// screenshot it): `-StreamShowcase YES -StreamGallery YES` on launch.
struct DesignGallery: View {
    @State private var season = 1
    @State private var chip = true

    private let poster = Artwork(src: "showcase/glass-harbor-poster.jpg", color: "#0b3d3a")
    private let backdrop = Artwork(src: "showcase/deep-field-backdrop.jpg", color: "#10002b")
    private let logo = Artwork(src: "showcase/northbound-logo.png", color: nil)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.rowGap) {
                Text("Stream").textStyle(.display, color: Palette.primary)
                SectionHeader(title: "Recently added", detail: "in Movies")
                ScrollView(.horizontal) { HStack(alignment: .top, spacing: Space.cardGap) {
                    ArtworkImage(artwork: poster, width: 260).frame(width: 260, height: 390)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    ZStack(alignment: .bottomLeading) {
                        ArtworkImage(artwork: backdrop, width: 460).frame(width: 460, height: 259)
                        ProgressBar(value: 0.4)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    ArtworkImage(artwork: nil, width: 260, fallback: "No Artwork Yet").frame(width: 260, height: 390)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    ArtworkImage(artwork: logo, width: 600, contentMode: .fit, logo: true).frame(width: 600, height: 150)
                    Shimmer(width: 260, height: 390)
                } }.scrollClipDisabled()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Continue watching").textStyle(.eyebrow, color: Palette.primary)
                    Text("Display").textStyle(.display)
                    Text("Title").textStyle(.title)
                    Text("Title 2").textStyle(.title2)
                    Text("Headline").textStyle(.headline)
                    Text("Body — the everyday text.").textStyle(.body)
                    Text("Callout, muted").textStyle(.callout, color: Palette.muted)
                    Text("Caption").textStyle(.caption, color: Palette.muted)
                    Text("12.1").textStyle(.number)
                }
                ScrollView(.horizontal) { HStack(spacing: 30) {
                    Button {} label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.primary)
                    Button {} label: { Label("Start over", systemImage: "arrow.counterclockwise") }.buttonStyle(.secondary)
                    Button {} label: { Label("More info", systemImage: "info.circle") }.buttonStyle(.ghost)
                    Button {} label: { Text("Compact") }.buttonStyle(.stream(.secondary, compact: true))
                    Button {} label: { Text("Disabled") }.buttonStyle(.secondary).disabled(true)
                    IconButton(label: "Mute", systemImage: "speaker.slash.fill") {}
                }.padding(.vertical, 20) }.scrollClipDisabled()
                HStack(spacing: 20) {
                    Badge(text: "Neutral")
                    Badge(text: "Watched", tone: .success, systemImage: "checkmark")
                    Badge(text: "4K", tone: .info)
                    Badge(text: "Converting", tone: .warning)
                    Badge(text: "Missing", tone: .danger)
                    CornerMark(kind: .count(3))
                    CornerMark(kind: .watched)
                }
                PillTabs(tabs: [(1, "Season 1"), (2, "Season 2"), (3, "Season 3")], selection: $season)
                HStack(spacing: 20) {
                    Chip(label: "Unwatched", on: chip) { chip.toggle() }
                    Chip(label: "4K", on: false) {}
                }

                HStack(alignment: .top, spacing: 40) {
                    LoadingState().frame(width: 420)
                    ErrorState(message: "Stream didn't answer.") {}.frame(width: 560)
                    EmptyState(title: "Nothing here yet", detail: "Titles arrive as the library is read.").frame(width: 600)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.margin)
        }
        .background(Palette.background)
    }
}
