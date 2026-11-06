import SwiftUI

/// Search (PROPOSAL §7.2): the TV's own keyboard, then everything that
/// matched in the web's groups, each a row a remote moves along — films,
/// shows, episodes, people, collections, channels, videos, where it was
/// said, and home videos.
struct SearchView: View {
    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var query = ""
    @State private var results: SearchResults?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.rowGap) {
                if let results {
                    if results.isEmpty {
                        EmptyState(title: "Nothing matches “\(term)”", detail: "Try fewer words, or another spelling.", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    } else {
                        groups(results)
                    }
                } else if failed {
                    ErrorState(message: "Search didn't answer.") { Task { await search() } }
                        .frame(maxWidth: .infinity)
                } else if term.count < 2 {
                    EmptyState(title: "Search everything",
                               detail: "Films, shows, episodes, people and channels — and what was said in them.",
                               systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 40)
        }
        .searchable(text: $query, prompt: "Films, shows, people, channels")
        .task(id: term) { await search() }
    }

    private var term: String { query.trimmingCharacters(in: .whitespaces) }

    private func search() async {
        guard term.count >= 2 else {
            results = nil
            failed = false
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            results = try await state.api.get("api/v1/search", query: ["q": term])
            failed = false
        } catch is CancellationError {
        } catch {
            state.handle(error)
            results = nil
            failed = true
        }
    }

    @ViewBuilder
    private func groups(_ found: SearchResults) -> some View {
        if !found.movies.isEmpty {
            CardRow(title: "Films") { ForEach(found.movies) { CardLink(card: $0) } }
        }
        if !found.shows.isEmpty {
            CardRow(title: "Shows") { ForEach(found.shows) { CardLink(card: $0) } }
        }
        if !found.episodes.isEmpty {
            CardRow(title: "Episodes") { ForEach(found.episodes) { CardLink(card: $0, style: .wide) } }
        }
        if let people = found.people, !people.isEmpty {
            CardRow(title: "People") {
                ForEach(people) { person in
                    RouteLink(Route.person(person.id)) {
                        Focused { PersonCard(name: person.name, role: nil, portrait: person.image, focused: $0) }
                    }
                    .buttonStyle(.streamCard)
                    .accessibilityLabel(person.name)
                }
            }
        }
        if let collections = found.collections, !collections.isEmpty {
            CardRow(title: "Collections") {
                ForEach(collections) { collection in
                    RouteLink(Route.collection(collection.id)) {
                        Focused { focused in
                            PosterCard(card: Card(kind: "collection", id: collection.id, title: collection.title, code: nil, year: nil,
                                                  images: collection.image.map { ["poster": $0] }, progress: nil, watched: nil, show: nil,
                                                  seasonNumber: nil, episodeNumber: nil, unwatchedCount: nil, arrival: "Collection"),
                                       focused: focused)
                        }
                    }
                    .buttonStyle(.streamCard)
                }
            }
        }
        if let channels = found.channels, !channels.isEmpty {
            CardRow(title: "Channels") {
                ForEach(channels) { channel in
                    RouteLink(Route.channel(channel.id)) {
                        Focused { ChannelCircle(title: channel.title, detail: nil, avatar: channel.image, focused: $0) }
                    }
                    .buttonStyle(.streamCard)
                    .accessibilityLabel(channel.title)
                }
            }
        }
        if let videos = found.videos, !videos.isEmpty {
            CardRow(title: "Videos") { ForEach(videos) { CardLink(card: $0, style: .video) } }
        }
        if let said = found.said, !said.isEmpty {
            CardRow(title: "Said in", detail: "From transcripts") {
                ForEach(said, id: \.key) { hit in
                    Button { playback.play(kind: hit.kind, id: hit.id, start: hit.start) } label: {
                        Focused { SaidCard(hit: hit, focused: $0) }
                    }
                    .buttonStyle(.streamCard)
                    .accessibilityLabel("\(hit.title), at \(Clock.format(hit.start)): \(hit.snippet.replacingOccurrences(of: "<<", with: "").replacingOccurrences(of: ">>", with: ""))")
                }
            }
        }
        if let clips = found.clips, !clips.isEmpty {
            CardRow(title: "Home videos") { ForEach(clips) { CardLink(card: $0, style: .clip) } }
        }
    }
}

/// A transcript hit: the words around the match, the match in cyan, and
/// where it is — pressing plays from there.
struct SaidCard: View {
    let hit: SearchResults.Said
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "quote.opening").foregroundStyle(Palette.primary)
                Text(hit.title).textStyle(.headline).lineLimit(1)
                Spacer(minLength: 0)
                Text(Clock.format(hit.start)).font(TextStyle.caption.font.monospacedDigit()).foregroundStyle(Palette.muted)
            }
            Text(highlighted).font(TextStyle.callout.font).foregroundStyle(Palette.foreground.opacity(0.85))
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Label("Play from here", systemImage: "play.fill").font(TextStyle.caption.font.weight(.semibold))
                .foregroundStyle(focused ? Palette.primary : Palette.muted)
        }
        .padding(28)
        .frame(width: 620, height: 259, alignment: .topLeading)
        .background(focused ? Palette.surfaceRaised : Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .focusLift(focused, scale: 1.04)
    }

    /// The snippet with the << >> marks turned into cyan.
    private var highlighted: AttributedString {
        var out = AttributedString()
        var rest = Substring(hit.snippet)
        while let open = rest.range(of: "<<"), let close = rest.range(of: ">>", range: open.upperBound..<rest.endIndex) {
            out += AttributedString(String(rest[..<open.lowerBound]))
            var match = AttributedString(String(rest[open.upperBound..<close.lowerBound]))
            match.foregroundColor = Palette.primary
            match.font = TextStyle.callout.font.weight(.bold)
            out += match
            rest = rest[close.upperBound...]
        }
        out += AttributedString(String(rest))
        return out
    }
}
