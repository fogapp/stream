import SwiftUI

/// A show's page (the web's ShowDetail): the hero with what plays next, the
/// seasons as tabs, each season's episodes as rows, then extras, cast and
/// what's like it.
struct ShowView: View {
    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(Toasts.self) private var toasts
    let id: String
    @State private var show: ShowDetail?
    @State private var error: String?
    @State private var season = 1
    @State private var trailerMuted = true

    var body: some View {
        Group {
            if let show {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.rowGap) {
                        hero(show)
                        seasons(show)
                        ExtrasRow(extras: show.extras ?? [])
                        CastRow(cast: show.cast ?? [])
                        SimilarRow(kind: "show", id: show.id)
                    }
                    .padding(.bottom, 80)
                }
                .ignoresSafeArea()
            } else if let error {
                ErrorState(message: error) { Task { await load() } }
            } else {
                LoadingState()
            }
        }
        .environment(\.reload, Reload { await load() })
        .task { await load() }
    }

    private func hero(_ show: ShowDetail) -> some View {
        Hero(images: show.images, title: show.title, trailer: show.trailer.flatMap { state.api.absolute($0.url) }, height: 900,
             trailerMuted: $trailerMuted) {
            VStack(alignment: .leading, spacing: 18) {
                FactsRow(facts: [show.year.map(String.init), show.network, show.contentRating, (show.genres ?? []).prefix(3).joined(separator: ", "),
                                 show.status].compactMap { $0 }.filter { !$0.isEmpty })
                if let overview = show.overview {
                    Text(overview).textStyle(.body, color: Palette.foreground.opacity(0.9)).lineLimit(4).frame(maxWidth: 1150, alignment: .leading)
                }
            }
            HStack(spacing: 28) {
                if let next = show.nextUp {
                    Button { playback.play(kind: "episode", id: next.episodeId) } label: {
                        Label(next.resumeAt != nil ? "Resume \(next.code)" : (next.startedShow ? "Play next: \(next.code)" : "Play \(next.code)"),
                              systemImage: "play.fill")
                    }
                    .buttonStyle(.primary)
                }
                if show.trailer != nil {
                    IconButton(label: trailerMuted ? "Hear the trailer" : "Mute the trailer",
                               systemImage: trailerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") { trailerMuted.toggle() }
                }
                if (show.unwatchedCount ?? 0) > 0 {
                    Button { Task { await markAll(show) } } label: { Label("Mark all watched", systemImage: "eye") }.buttonStyle(.ghost)
                }
            }
            .focusSection()
            HStack(spacing: 40) {
                StarRating(kind: "show", id: show.id, value: show.myRating)
                CollectionChips(collections: show.collections ?? [])
            }
            .focusSection()
        }
    }

    @ViewBuilder private func seasons(_ show: ShowDetail) -> some View {
        let available = show.seasons.filter { $0.availableCount > 0 }
        if available.isEmpty {
            EmptyState(title: "No episodes yet", detail: "Episodes show up here as soon as their files are read.")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                PillTabs(tabs: available.map { ($0.seasonNumber, $0.title) }, selection: $season)
                    .padding(.horizontal, Space.margin - 28)
                Rectangle().fill(Palette.border).frame(height: 1.5).padding(.horizontal, Space.margin)
                SeasonEpisodes(showId: show.id, showTitle: show.title, number: season)
            }
            .focusSection()
        }
    }

    private func markAll(_ show: ShowDetail) async {
        do {
            let _: Empty = try await state.api.post("api/v1/shows/\(show.id)/watched", body: ["watched": true])
            toasts.show("\(show.title): marked watched")
            await load()
        } catch {
            toasts.show("That didn't go through.", failed: true)
        }
    }

    private func load() async {
        do {
            let loaded: ShowDetail = try await state.api.get("api/v1/shows/\(id)")
            if show == nil {
                let regular = loaded.seasons.filter { $0.availableCount > 0 && $0.seasonNumber > 0 }
                season = regular.first?.seasonNumber ?? loaded.seasons.first?.seasonNumber ?? 1
            }
            show = loaded
            error = nil
        } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }
}

/// One season's episodes, as the web lists them.
struct SeasonEpisodes: View {
    @Environment(AppState.self) private var state
    let showId: String
    let showTitle: String?
    let number: Int
    @State private var season: SeasonDetail?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let season {
                if let overview = season.overview { Text(overview).textStyle(.callout, color: Palette.muted).lineLimit(2).frame(maxWidth: 1300, alignment: .leading) }
                ForEach(season.episodes) { EpisodeRow(episode: $0, showTitle: showTitle) }
            } else if let error {
                ErrorState(message: error) { Task { await load() } }
            } else {
                ForEach(0..<3, id: \.self) { _ in Shimmer(width: 1500, height: 190) }
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, 24)
        .task(id: number) { await load() }
    }

    private func load() async {
        do {
            season = try await state.api.get("api/v1/shows/\(showId)/seasons/\(number)")
            error = nil
        } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }
}

/// An episode: its still with how far in, "3. Title", when it aired and how
/// long it is, what happens, and whether it's watched. Plays when chosen.
struct EpisodeRow: View {
    @Environment(PlaybackCoordinator.self) private var playback
    let episode: SeasonDetail.Episode
    let showTitle: String?

    var body: some View {
        Button { playback.play(kind: "episode", id: episode.id) } label: {
            Focused { focused in
                HStack(alignment: .top, spacing: 36) {
                    ZStack(alignment: .bottomLeading) {
                        ArtworkImage(artwork: episode.images?["still"] ?? episode.images?["thumb"], width: 340, fallback: episode.code)
                        if focused && episode.available {
                            Image(systemName: "play.fill").font(.system(size: 30, weight: .bold)).foregroundStyle(Palette.foreground)
                                .frame(width: 72, height: 72).background(Palette.background.opacity(0.8), in: Circle())
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if let progress = episode.progress, progress > 0 { ProgressBar(value: progress) }
                    }
                    .frame(width: 340, height: 191)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text("\(episode.episodeNumber.map(String.init) ?? episode.code).").textStyle(.headline, color: Palette.muted)
                            Text(episode.title ?? episode.code).textStyle(.headline).lineLimit(1)
                            if episode.watched == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.primary).font(.system(size: 26)) }
                        }
                        let meta = [episode.airDate.map { String($0.prefix(10)) }, Clock.runtime(episode.runtimeMinutes)].compactMap { $0 }
                        if !meta.isEmpty { Text(meta.joined(separator: " · ")).textStyle(.caption, color: Palette.muted) }
                        if let overview = episode.overview { Text(overview).textStyle(.callout, color: Palette.foreground.opacity(0.8)).lineLimit(3) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
                .background(focused ? Palette.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(focused ? Palette.primary : .clear, lineWidth: 4))
                .focusGrow(focused, 1.015)
                .focusMotion(focused)
                .opacity(episode.available ? 1 : 0.55)
            }
        }
        .buttonStyle(.streamCard)
        .disabled(!episode.available)
        .itemActions(episode.card(show: showTitle))
        .accessibilityLabel([episode.code, episode.title, episode.watched == true ? "watched" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A season on its own page (from a remote command, or an old link).
struct SeasonView: View {
    let showId: String
    let number: Int

    var body: some View {
        ScrollView { SeasonEpisodes(showId: showId, showTitle: nil, number: number).padding(.vertical, Space.margin) }
    }
}
