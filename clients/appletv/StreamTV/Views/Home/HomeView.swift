import SwiftUI

/// Home (PROPOSAL §7.1, the web's Home page): the hero — something you were
/// watching, what's next, or new, the server's pick each load — then the rows
/// in the profile's order.
struct HomeView: View {
    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var home: Home?
    @State private var guide: Guide?
    @State private var error: String?
    @State private var trailerMuted = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.rowGap) {
                if let home {
                    if let hero = home.hero { heroSection(hero) }
                    if let guide, !guide.stations.isEmpty { onNow(guide) }
                    if home.hubs.isEmpty && home.hero == nil {
                        EmptyState(title: "Nothing to watch yet", detail: "Once your libraries are read, films and shows appear here.")
                            .padding(.top, 200)
                    }
                    ForEach(home.hubs) { hub in row(hub) }
                } else if let error {
                    ErrorState(message: error) { Task { await load() } }.padding(.top, 200)
                } else {
                    VStack(alignment: .leading, spacing: 40) {
                        Shimmer(width: 1500, height: 600)
                        HStack(spacing: Space.cardGap) { ForEach(0..<4, id: \.self) { _ in Shimmer(width: 460, height: 259) } }
                    }
                    .padding(Space.margin)
                }
            }
            .padding(.bottom, 80)
        }
        // Edge to edge: the hero runs to the screen's edges; rows keep their own margins.
        .ignoresSafeArea()
        .environment(\.reload, Reload { await load() })
        .task { await load() }
    }

    private func heroSection(_ hero: HomeHero) -> some View {
        Hero(images: hero.images, title: hero.title, trailer: hero.trailer.flatMap { state.api.absolute($0.url) }, trailerMuted: $trailerMuted) {
            VStack(alignment: .leading, spacing: 14) {
                Text(hero.label).textStyle(.eyebrow, color: Palette.primary)
                if let subtitle = hero.subtitle { Text(subtitle).textStyle(.callout, color: Palette.muted) }
                if let progress = hero.progress { ProgressBar(value: progress, height: 8).frame(width: 440).clipShape(Capsule()) }
                if let overview = hero.overview {
                    Text(overview).textStyle(.body, color: Palette.foreground.opacity(0.9)).lineLimit(3).frame(maxWidth: 1000, alignment: .leading)
                }
            }
            HStack(spacing: 28) {
                PlayButtons(resumeAt: hero.resumeAt) { fromStart in playback.play(kind: hero.play.kind, id: hero.play.id, fromStart: fromStart) }
                RouteLink(hero.kind == "movie" ? Route.movie(hero.id) : Route.show(hero.id)) {
                    Label("More info", systemImage: "info.circle")
                }
                .buttonStyle(.ghost)
                if hero.trailer != nil {
                    IconButton(label: trailerMuted ? "Unmute the trailer" : "Mute the trailer",
                               systemImage: trailerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") { trailerMuted.toggle() }
                }
            }
            .focusSection()
        }
    }

    @ViewBuilder private func row(_ hub: Hub) -> some View {
        CardRow(title: hub.title) {
            ForEach(hub.items) { card in
                CardLink(card: card, style: style(hub.kind), dismissible: hub.key == "continue_watching")
            }
        }
        .onAppear { prefetch(hub) }
    }

    /// Grid, first thing (as the web's TV layout has it): what each
    /// channel is airing now; choosing one tunes in.
    private func onNow(_ guide: Guide) -> some View {
        let now = Date().addingTimeInterval(LiveTime.skew(serverNow: guide.now))
        return CardRow(title: "On now", detail: "Grid") {
            ForEach(guide.stations) { station in
                let current = LiveTime.onAt(station.airings, now).current
                Button { playback.watchLive(number: station.number) } label: {
                    Focused { focused in
                        LiveCard(station: station, airing: current, now: now, focused: focused)
                    }
                }
                .buttonStyle(.streamCard)
                .accessibilityLabel("Channel \(station.number), \(station.name)\(current.map { ", \($0.title)" } ?? "")")
            }
        }
    }

    private func style(_ kind: String) -> CardStyle {
        switch kind {
        case "poster": return .poster
        case "videos": return .video
        case "clips": return .clip
        default: return .wide
        }
    }

    /// A row's pictures, fetched as it comes into view.
    private func prefetch(_ hub: Hub) {
        let urls = hub.items.compactMap { card -> URL? in
            let art = hub.kind == "poster" ? card.image : card.wideImage
            return art.flatMap { state.api.absolute($0.source(forWidth: 460, scale: 2)) }
        }
        ImagePipeline.shared.prefetch(urls)
    }

    private func load() async {
        guide = try? await state.api.get("api/v1/guide")
        do {
            let loaded: Home = try await state.api.get("api/v1/home")
            home = loaded
            error = nil
            let (guide, api) = (guide, state.api)
            Task.detached(priority: .utility) { await TopShelf.publish(home: loaded, guide: guide, api: api) }
        } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }
}
