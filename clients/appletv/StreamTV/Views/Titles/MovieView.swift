import SwiftUI

/// A film's page (the web's MovieDetail): the hero with the logo, the facts,
/// your stars, the tagline and overview, who directed it, the collections
/// it's in and what can be done; then its extras, cast and what's like it.
struct MovieView: View {
    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(Toasts.self) private var toasts
    @Environment(WatchLater.self) private var watchLater
    let id: String
    @State private var movie: MovieDetail?
    @State private var error: String?
    @State private var trailerMuted = true

    var body: some View {
        Group {
            if let movie {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.rowGap) {
                        hero(movie)
                        ExtrasRow(extras: movie.extras ?? [])
                        CastRow(cast: movie.cast ?? [])
                        SimilarRow(kind: "movie", id: movie.id)
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

    private func hero(_ movie: MovieDetail) -> some View {
        Hero(images: movie.images, title: movie.title, trailer: movie.trailer.flatMap { state.api.absolute($0.url) }, height: 960,
             trailerMuted: $trailerMuted) {
            VStack(alignment: .leading, spacing: 18) {
                FactsRow(facts: [movie.year.map(String.init), Clock.runtime(movie.runtimeMinutes), movie.contentRating,
                                 (movie.genres ?? []).prefix(3).joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty },
                         badges: movie.watched == true ? [Badge(text: "Watched", tone: .success, systemImage: "checkmark")] : [])
                if let progress = movie.progress, progress > 0 { ProgressBar(value: progress, height: 8).frame(width: 440).clipShape(Capsule()) }
                if let tagline = movie.tagline { Text(tagline).font(.system(size: 32, weight: .regular).italic()).foregroundStyle(Palette.foreground.opacity(0.9)) }
                if let overview = movie.overview {
                    Text(overview).textStyle(.body, color: Palette.foreground.opacity(0.9)).lineLimit(4).frame(maxWidth: 1150, alignment: .leading)
                }
                if !movie.directors.isEmpty { Text("Directed by \(movie.directors.joined(separator: ", "))").textStyle(.callout, color: Palette.muted) }
            }
            HStack(spacing: 28) {
                if movie.playable {
                    PlayButtons(resumeAt: movie.resumeAt) { fromStart in playback.play(kind: "movie", id: movie.id, fromStart: fromStart) }
                } else {
                    Label(movie.versions?.first?.unplayableReason ?? "No readable file", systemImage: "exclamationmark.circle")
                        .textStyle(.body, color: Palette.warning)
                }
                if movie.trailer != nil {
                    IconButton(label: trailerMuted ? "Hear the trailer" : "Mute the trailer",
                               systemImage: trailerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") { trailerMuted.toggle() }
                }
                Button { Task { await toggleWatched(movie) } } label: {
                    Label(movie.watched == true ? "Mark unwatched" : "Mark watched", systemImage: movie.watched == true ? "eye.slash" : "eye")
                }
                .buttonStyle(.ghost)
                Button { Task { await toggleLater(movie) } } label: {
                    Label(watchLater.contains(movie.id) ? "In Watch later" : "Watch later",
                          systemImage: watchLater.contains(movie.id) ? "clock.badge.checkmark" : "clock")
                }
                .buttonStyle(.ghost)
            }
            .focusSection()
            HStack(spacing: 40) {
                StarRating(kind: "movie", id: movie.id, value: movie.myRating)
                CollectionChips(collections: movie.collections ?? [])
            }
            .focusSection()
        }
    }

    private func toggleWatched(_ movie: MovieDetail) async {
        do {
            let _: Empty = try await state.api.post("api/v1/watch_states", body: WatchState(playableType: "movie", playableId: movie.id, watched: movie.watched != true))
            toasts.show("\(movie.title): marked \(movie.watched == true ? "unwatched" : "watched")")
            await load()
        } catch {
            toasts.show("That didn't go through.", failed: true)
        }
    }

    private func toggleLater(_ movie: MovieDetail) async {
        if let saved = try? await watchLater.toggle(kind: "movie", id: movie.id, api: state.api) {
            toasts.show(saved ? "\(movie.title): saved to Watch later" : "\(movie.title): taken out of Watch later")
        }
    }

    private func load() async {
        do {
            movie = try await state.api.get("api/v1/movies/\(id)")
            error = nil
        } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }

    private struct WatchState: Encodable {
        let playableType: String
        let playableId: String
        let watched: Bool
    }
}
