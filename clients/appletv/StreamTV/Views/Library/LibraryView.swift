import SwiftUI

/// A library (PROPOSAL §7.2), drawn as the web draws its kind: films and
/// shows as a poster wall, YouTube as channels, home videos through time,
/// cameras and web streams as their latest pictures.
struct LibraryView: View {
    let library: Library

    var body: some View {
        switch library.kind {
        case "channels": ChannelWall(library: library)
        case "home_videos": HomeVideosView(library: library)
        case "live": LiveStreamWall(library: library)
        default: PosterWall(library: library)
        }
    }
}

/// The page's name over its controls, as the web's library header.
struct LibraryHeader<Controls: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text(title).textStyle(.title)
                if let detail { Text(detail).textStyle(.callout, color: Palette.muted) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            HStack(spacing: 24) { controls() }
                .focusSection()
        }
    }
}

// MARK: - Films and shows

/// Every film or show in a library, sorted and filtered as on the web, a
/// page at a time as the wall scrolls.
struct PosterWall: View {
    enum Sort: String, CaseIterable {
        case title, added, year, rating

        var label: String {
            switch self {
            case .title: return "A–Z"
            case .added: return "Recently added"
            case .year: return "Year"
            case .rating: return "Rating"
            }
        }
    }

    @Environment(AppState.self) private var state
    let library: Library
    @State private var sort = Sort.title
    @State private var unwatched = false
    @State private var cards: [Card]?
    @State private var page = 1
    @State private var more = false
    @State private var loadingMore = false
    @State private var error: String?
    /// Focus starts on the first poster, not the sort control above it:
    /// placed there once, when the first page arrives.
    @FocusState private var focusedCard: String?
    @State private var placedFocus = false

    static let per = 120
    private let columns = Array(repeating: GridItem(.fixed(CardSize.poster.width), spacing: Space.cardGap), count: 5)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                LibraryHeader(title: library.name, detail: count) {
                    Segmented(options: Sort.allCases.map { ($0, $0.label) }, selection: $sort)
                    Chip(label: "Unwatched", on: unwatched) { unwatched.toggle() }
                }
                content
            }
            .padding(Space.margin)
        }
        .task(id: "\(sort.rawValue)-\(unwatched)") { await load() }
        .environment(\.reload, Reload { await load() })
    }

    private var count: String? {
        guard let cards, !more else { return nil }
        return "\(cards.count) \(library.kind == "movies" ? (cards.count == 1 ? "film" : "films") : (cards.count == 1 ? "show" : "shows"))"
    }

    @ViewBuilder private var content: some View {
        if let cards {
            if cards.isEmpty {
                EmptyState(title: unwatched ? "Nothing matches" : "Nothing here yet",
                           detail: unwatched ? "Everything here has been watched. Show everything instead." : "Titles appear as soon as the library is read.",
                           systemImage: library.systemImage)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 64) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        CardLink(card: card)
                            .focused($focusedCard, equals: card.id)
                            .onAppear { if index >= cards.count - 10 { Task { await loadMore() } } }
                    }
                }
                .focusSection()
                if loadingMore { LoadingState(label: "Loading more…") }
            }
        } else if let error {
            ErrorState(message: error) { Task { await load() } }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 64) {
                ForEach(0..<10, id: \.self) { _ in Shimmer(width: CardSize.poster.width, height: CardSize.poster.height) }
            }
        }
    }

    private func fetch(page: Int) async throws -> [Card] {
        var query = ["library_id": library.id, "sort": sort.rawValue, "page": String(page), "per": String(Self.per)]
        if unwatched { query["unwatched"] = "true" }
        return try await state.api.get(library.kind == "movies" ? "api/v1/movies" : "api/v1/shows", query: query)
    }

    /// The first page again; what's on screen stays until it arrives.
    private func load() async {
        do {
            let first = try await fetch(page: 1)
            cards = first
            page = 1
            more = first.count == Self.per
            error = nil
            if !placedFocus {
                placedFocus = true
                focusedCard = first.first?.id
            }
        } catch is CancellationError {
        } catch {
            state.handle(error)
            if cards == nil { self.error = error.localizedDescription }
        }
    }

    private func loadMore() async {
        guard more, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let next = try await fetch(page: page + 1)
            let seen = Set((cards ?? []).map(\.id))
            cards = (cards ?? []) + next.filter { !seen.contains($0.id) }
            page += 1
            more = next.count == Self.per
        } catch {
            state.handle(error)
        }
    }
}

// MARK: - YouTube

/// A channels library: every channel, round, with what's unwatched on it.
struct ChannelWall: View {
    @Environment(AppState.self) private var state
    let library: Library
    @State private var channels: [ChannelCard]?
    @State private var error: String?

    private let columns = Array(repeating: GridItem(.fixed(240), spacing: 30), count: 6)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                LibraryHeader(title: library.name, detail: channels.map { "\($0.count) \($0.count == 1 ? "channel" : "channels")" }) {}
                if let channels {
                    if channels.isEmpty {
                        EmptyState(title: "No channels yet", detail: "Channels are added on the web, and their videos appear here as they're fetched.",
                                   systemImage: library.systemImage)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 64) {
                            ForEach(channels) { channel in
                                RouteLink(Route.channel(channel.id)) {
                                    Focused { focused in
                                        ChannelCircle(title: channel.title,
                                                      detail: "\(channel.videoCount) \(channel.videoCount == 1 ? "video" : "videos")",
                                                      avatar: channel.avatar, unwatched: channel.unwatchedCount, focused: focused)
                                    }
                                }
                                .buttonStyle(.streamCard)
                                .accessibilityLabel("\(channel.title), \(channel.videoCount) videos, \(channel.unwatchedCount) unwatched")
                            }
                        }
                        .focusSection()
                    }
                } else if let error {
                    ErrorState(message: error) { Task { await load() } }
                } else {
                    LoadingState()
                }
            }
            .padding(Space.margin)
        }
        .task(id: library.id) { await load() }
    }

    private func load() async {
        do {
            channels = try await state.api.get("api/v1/channels", query: ["library_id": library.id])
            error = nil
        } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Home videos

/// A home-videos library through time (the web's timeline): months under
/// the years, newest first, narrowed by album, person or favourites, with
/// the years along the top to jump back through them.
struct HomeVideosView: View {
    @Environment(AppState.self) private var state
    let library: Library
    @State private var filters: ClipFilters?
    @State private var album: String?
    @State private var person: String?
    @State private var favorites = false
    /// The year jumped to; nil is the newest.
    @State private var from: Int? = nil
    @State private var years: [ClipsPage.Year] = []
    @State private var clips: [Card]?
    @State private var more = false
    @State private var loadingMore = false
    @State private var error: String?

    private let columns = Array(repeating: GridItem(.fixed(CardSize.wide.width), spacing: Space.cardGap), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                LibraryHeader(title: library.name) {
                    if years.count > 1 {
                        Segmented(options: [(Int?.none, "Newest")] + years.map { (Int?.some($0.year), String($0.year)) }, selection: $from)
                    }
                    if let filters, filters.favorites > 0 {
                        Chip(label: "Favourites", on: favorites) { favorites.toggle() }
                    }
                    ForEach(filters?.albums ?? []) { item in
                        Chip(label: item.title, on: album == item.id) { album = album == item.id ? nil : item.id }
                    }
                }
                if let people = filters?.people, !people.isEmpty {
                    PeopleFilter(people: people, selection: $person)
                }
                timeline
            }
            .padding(Space.margin)
        }
        .task(id: library.id) { filters = try? await state.api.get("api/v1/clips/filters", query: ["library_id": library.id]) }
        .task(id: "\(album ?? "")-\(person ?? "")-\(favorites)-\(from.map(String.init) ?? "")") { await load() }
    }

    @ViewBuilder private var timeline: some View {
        if let clips {
            if clips.isEmpty {
                EmptyState(title: from == nil && album == nil && person == nil && !favorites ? "No home videos yet" : "Nothing matches",
                           detail: "Clips appear as soon as they're read, placed by when they were taken.", systemImage: library.systemImage)
            } else {
                LazyVStack(alignment: .leading, spacing: 44) {
                    ForEach(months, id: \.key) { month in
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: month.label, detail: "\(month.clips.count) \(month.clips.count == 1 ? "clip" : "clips")")
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                                ForEach(month.clips) { clip in
                                    CardLink(card: clip, style: .clip)
                                        .onAppear { if clip.id == clips.last?.id { Task { await loadMore() } } }
                                }
                            }
                            .padding(.vertical, 20)
                        }
                        .focusSection()
                    }
                }
                if loadingMore { LoadingState(label: "Loading earlier…") }
            }
        } else if let error {
            ErrorState(message: error) { Task { await load() } }
        } else {
            LoadingState()
        }
    }

    private var months: [(key: String, label: String, clips: [Card])] {
        var groups: [(key: String, label: String, clips: [Card])] = []
        for clip in clips ?? [] {
            let month = Captured.month(clip.capturedAt ?? "")
            if groups.last?.key == month.key {
                groups[groups.count - 1].clips.append(clip)
            } else {
                groups.append((month.key, month.label, [clip]))
            }
        }
        return groups
    }

    private func fetch(before: String?) async throws -> ClipsPage {
        var query = ["library_id": library.id]
        if let album { query["album_id"] = album }
        if let person { query["person_id"] = person }
        if favorites { query["favorites"] = "true" }
        if let before { query["before"] = before }
        return try await state.api.get("api/v1/clips", query: query)
    }

    private func load() async {
        do {
            let page = try await fetch(before: from.map { "\($0 + 1)-01-01T00:00:00" })
            clips = page.clips
            more = page.more
            if from == nil || years.isEmpty { years = page.years }
            error = nil
        } catch is CancellationError {
        } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard more, !loadingMore, let last = clips?.last?.capturedAt else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await fetch(before: last)
            let seen = Set((clips ?? []).map(\.id))
            clips = (clips ?? []) + page.clips.filter { !seen.contains($0.id) }
            more = page.more
        } catch {
            state.handle(error)
        }
    }
}

/// The people Immich recognised, as small round faces: one at a time
/// narrows the timeline to them.
private struct PeopleFilter: View {
    let people: [ClipFilters.Person]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 28) {
                ForEach(people) { person in
                    let on = selection == person.id
                    Button { selection = on ? nil : person.id } label: {
                        Focused { focused in
                            VStack(spacing: 10) {
                                ArtworkImage(artwork: person.image, width: 110, fallback: String(person.name.prefix(1)))
                                    .frame(width: 110, height: 110)
                                    .clipShape(Circle())
                                    .overlay(Circle().strokeBorder(focused || on ? Palette.primary : Palette.border, lineWidth: focused || on ? 5 : 1.5))
                                    .focusGrow(focused, 1.1)
                                    .focusMotion(focused)
                                Text(person.name).textStyle(.caption, color: on ? Palette.primary : Palette.foreground).lineLimit(1)
                            }
                            .frame(width: 130)
                        }
                    }
                    .buttonStyle(.streamCard)
                    .accessibilityLabel(person.name)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 12)
        }
        .scrollClipDisabled()
        .focusSection()
    }
}

// MARK: - Live streams

/// A live library (PROPOSAL §7.8): each camera and web stream, its picture
/// from a few minutes ago, played full screen when chosen.
struct LiveStreamWall: View {
    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    let library: Library
    @State private var streams: [LiveStreamCard]?
    @State private var error: String?

    private let columns = Array(repeating: GridItem(.fixed(CardSize.wide.width), spacing: Space.cardGap), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                LibraryHeader(title: library.name, detail: streams.map { "\($0.count) \($0.count == 1 ? "stream" : "streams")" }) {}
                if let error {
                    ErrorState(message: error) { Task { await load() } }
                } else if let streams {
                    if streams.isEmpty {
                        EmptyState(title: "No streams yet", detail: "An admin adds cameras and web streams in Settings on the web.",
                                   systemImage: library.systemImage)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                            ForEach(streams) { stream in
                                Button { playback.watchStream(id: stream.id, name: stream.name) } label: {
                                    Focused { LiveStreamTile(stream: stream, focused: $0) }
                                }
                                .buttonStyle(.streamCard)
                                .accessibilityLabel([stream.name, stream.online ? "live" : "offline"].joined(separator: ", "))
                            }
                        }
                        .padding(.vertical, 20)
                        .focusSection()
                    }
                } else {
                    LoadingState()
                }
            }
            .padding(Space.margin)
        }
        .task(id: library.id) {
            // The pictures are retaken every few minutes, and whether each answers.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func load() async {
        do {
            streams = try await state.api.get("api/v1/live_streams", query: ["library_id": library.id])
            error = nil
        } catch {
            state.handle(error)
            if streams == nil { self.error = (error as? APIError)?.messages.first ?? error.localizedDescription }
        }
    }
}

/// A stream's card: its latest picture, whether it's answering, its name.
struct LiveStreamTile: View {
    let stream: LiveStreamCard
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ArtworkImage(artwork: stream.still, width: CardSize.wide.width, fallback: stream.name)
                .opacity(stream.online ? 1 : 0.4)
                .frame(width: CardSize.wide.width, height: CardSize.wide.height)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if stream.online {
                        LivePill(compact: true).padding(12)
                    } else {
                        Text("Offline").textStyle(.caption, color: Palette.negative)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .padding(12)
                    }
                }
                .focusLift(focused, scale: 1.05)
                .focusMotion(focused)
            VStack(alignment: .leading, spacing: 4) {
                Text(stream.name).textStyle(.headline, color: focused ? Palette.foreground : Palette.foreground.opacity(0.85)).lineLimit(1)
                Text(stream.description ?? (stream.kind == "camera" ? "Camera" : stream.kind == "youtube" ? "YouTube" : stream.kind == "mlb" ? "MLB.tv" : "Web stream")).textStyle(.caption, color: Palette.muted).lineLimit(1)
            }
            .focusRise(focused, 12)
            .focusMotion(focused)
        }
        .frame(width: CardSize.wide.width, alignment: .leading)
    }
}
