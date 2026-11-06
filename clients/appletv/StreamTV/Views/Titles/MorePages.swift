import SwiftUI

/// A page with a heading and a wall of cards: a person's films and shows, a
/// collection, a playlist.
struct CardWall: View {
    let cards: [Card]
    var style: CardStyle = .poster

    var body: some View {
        let width = style == .poster ? CardSize.poster.width : CardSize.wide.width
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: Space.cardGap), count: style == .poster ? 5 : 3),
                  alignment: .leading, spacing: 64) {
            ForEach(cards) { CardLink(card: $0, style: style) }
        }
    }
}

/// Someone's page (the web's PersonDetail): their portrait and name, and
/// what of theirs is in the library.
struct PersonView: View {
    @Environment(AppState.self) private var state
    let id: String
    @State private var person: PersonDetail?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let person {
                VStack(alignment: .leading, spacing: Space.rowGap) {
                    HStack(spacing: 50) {
                        ArtworkImage(artwork: person.image, width: 260, fallback: person.name).frame(width: 260, height: 260).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 12) {
                            Text(person.name).textStyle(.display)
                            Text("\(person.movies.count) films · \(person.shows.count) shows in the library").textStyle(.body, color: Palette.muted)
                        }
                    }
                    if !person.movies.isEmpty { section("Films", person.movies) }
                    if !person.shows.isEmpty { section("Shows", person.shows) }
                }
                .padding(Space.margin)
            } else if let error {
                ErrorState(message: error) { Task { await load() } }
            } else {
                LoadingState()
            }
        }
        .task { await load() }
    }

    private func section(_ title: String, _ cards: [Card]) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            SectionHeader(title: title, detail: "\(cards.count)")
            CardWall(cards: cards)
        }
        .focusSection()
    }

    private func load() async {
        do { person = try await state.api.get("api/v1/people/\(id)") } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }
}

/// A collection (PROPOSAL §4.2): its backdrop and overview, then its titles.
struct CollectionView: View {
    @Environment(AppState.self) private var state
    let id: String
    @State private var collection: CollectionDetail?
    @State private var error: String?
    @State private var muted = true

    var body: some View {
        ScrollView {
            if let collection {
                VStack(alignment: .leading, spacing: Space.rowGap) {
                    Hero(images: collection.images, title: collection.title, height: 620, trailerMuted: $muted) {
                        if let overview = collection.overview {
                            Text(overview).textStyle(.body, color: Palette.foreground.opacity(0.9)).lineLimit(3).frame(maxWidth: 1100, alignment: .leading)
                        }
                        Text("\(collection.items.count) titles").textStyle(.callout, color: Palette.muted)
                    }
                    CardWall(cards: collection.items).padding(.horizontal, Space.margin)
                }
                .padding(.bottom, 80)
            } else if let error {
                ErrorState(message: error) { Task { await load() } }.padding(.top, 200)
            } else {
                LoadingState().padding(.top, 200)
            }
        }
        .ignoresSafeArea()
        .task { await load() }
    }

    private func load() async {
        do { collection = try await state.api.get("api/v1/collections/\(id)") } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }
}

/// A YouTube channel (PROPOSAL §5.4): its banner and description,
/// Subscribe, and its videos newest first.
struct ChannelView: View {
    @Environment(AppState.self) private var state
    @Environment(Toasts.self) private var toasts
    let id: String
    @State private var channel: ChannelDetail?
    @State private var error: String?
    @State private var muted = true

    var body: some View {
        ScrollView {
            if let channel {
                VStack(alignment: .leading, spacing: Space.rowGap) {
                    Hero(images: channel.images, title: channel.title, height: 560, trailerMuted: $muted) {
                        if let description = channel.description {
                            Text(description).textStyle(.callout, color: Palette.foreground.opacity(0.85)).lineLimit(3).frame(maxWidth: 1100, alignment: .leading)
                        }
                        Button { Task { await toggle(channel) } } label: {
                            Label(channel.subscribed == true ? "Subscribed" : "Subscribe",
                                  systemImage: channel.subscribed == true ? "checkmark" : "plus")
                        }
                        .buttonStyle(channel.subscribed == true ? .secondary : .primary)
                    }
                    CardWall(cards: channel.videos, style: .video).padding(.horizontal, Space.margin)
                }
                .padding(.bottom, 80)
            } else if let error {
                ErrorState(message: error) { Task { await load() } }.padding(.top, 200)
            } else {
                LoadingState().padding(.top, 200)
            }
        }
        .ignoresSafeArea()
        .task { await load() }
    }

    private func toggle(_ channel: ChannelDetail) async {
        do {
            if channel.subscribed == true {
                try await state.api.delete("api/v1/channels/\(channel.id)/subscription")
            } else {
                let _: Empty = try await state.api.post("api/v1/channels/\(channel.id)/subscription", body: Empty())
            }
            toasts.show(channel.subscribed == true ? "Unsubscribed from \(channel.title)" : "Subscribed to \(channel.title)")
            await load()
        } catch {
            toasts.show("That didn't go through.", failed: true)
        }
    }

    private func load() async {
        do { channel = try await state.api.get("api/v1/channels/\(id)", query: ["per": "200"]) } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }
}

/// A channel video's page: play it, what it's about, more from the channel.
struct VideoView: View {
    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    let id: String
    @State private var video: VideoDetail?
    @State private var error: String?
    @State private var muted = true

    var body: some View {
        ScrollView {
            if let video {
                VStack(alignment: .leading, spacing: Space.rowGap) {
                    Hero(images: video.images.map { ["backdrop": $0["thumb"] ?? $0["backdrop"]].compactMapValues { $0 } }, title: video.title,
                         height: 760, trailerMuted: $muted) {
                        FactsRow(facts: [video.channel?.title, video.uploadDate.map { String($0.prefix(10)) }, video.durationSeconds.map(Clock.format)]
                            .compactMap { $0 })
                        if let description = video.description {
                            Text(description).textStyle(.callout, color: Palette.foreground.opacity(0.85)).lineLimit(4).frame(maxWidth: 1100, alignment: .leading)
                        }
                        HStack(spacing: 28) {
                            PlayButtons(resumeAt: video.resumeAt) { fromStart in playback.play(kind: "video", id: video.id, fromStart: fromStart) }
                            if let channel = video.channel {
                                RouteLink(Route.channel(channel.id)) { Label(channel.title, systemImage: "person.crop.square") }
                                    .buttonStyle(.ghost)
                            }
                        }
                    }
                    if let more = video.moreFromChannel, !more.isEmpty {
                        CardRow(title: "More from \(video.channel?.title ?? "the channel")") { ForEach(more) { CardLink(card: $0, style: .video) } }
                    }
                }
                .padding(.bottom, 80)
            } else if let error {
                ErrorState(message: error) { Task { await load() } }.padding(.top, 200)
            } else {
                LoadingState().padding(.top, 200)
            }
        }
        .ignoresSafeArea()
        .task { await load() }
    }

    private func load() async {
        do { video = try await state.api.get("api/v1/videos/\(id)") } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }
}

/// A playlist: Play all, then its items in order.
struct PlaylistView: View {
    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    let id: String
    @State private var playlist: PlaylistDetail?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let playlist {
                VStack(alignment: .leading, spacing: 40) {
                    Text(playlist.title).textStyle(.title)
                    if let first = playlist.items.first {
                        Button { playback.play(kind: first.kind, id: first.id, playlistId: playlist.id) } label: {
                            Label("Play all", systemImage: "play.fill")
                        }
                        .buttonStyle(.primary)
                    }
                    if playlist.items.isEmpty { EmptyState(title: "Nothing in it yet", detail: "Add things from a card's menu (hold select).") }
                    CardWall(cards: playlist.items, style: .wide)
                }
                .padding(Space.margin)
            } else if let error {
                ErrorState(message: error) { Task { await load() } }
            } else {
                LoadingState()
            }
        }
        .environment(\.reload, Reload { await load() })
        .task { await load() }
    }

    private func load() async {
        do { playlist = try await state.api.get("api/v1/playlists/\(id)") } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }
}
