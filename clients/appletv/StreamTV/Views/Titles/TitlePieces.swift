import SwiftUI

/// Resume / Start over, or Play (the web's PlayButtons).
struct PlayButtons: View {
    let resumeAt: Double?
    var playLabel = "Play"
    let play: (_ fromStart: Bool) -> Void

    var body: some View {
        HStack(spacing: 28) {
            if let resumeAt, resumeAt > 0 {
                Button { play(false) } label: { Label("Resume from \(Clock.format(resumeAt))", systemImage: "play.fill") }
                    .buttonStyle(.primary)
                Button { play(true) } label: { Label("Start over", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.secondary)
            } else {
                Button { play(false) } label: { Label(playLabel, systemImage: "play.fill") }
                    .buttonStyle(.primary)
            }
        }
    }
}

enum Clock {
    /// 5423 → "1:30:23".
    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// 118 → "1h 58m".
    static func runtime(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// Year · runtime · rating · genres, as the web's hero lists them.
struct FactsRow: View {
    let facts: [String]
    var badges: [Badge] = []

    var body: some View {
        HStack(spacing: 22) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 { Circle().fill(Palette.muted).frame(width: 6, height: 6) }
                Text(fact).textStyle(.callout, color: Palette.muted)
            }
            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in badge }
        }
    }
}

/// This profile's stars (the web's StarRating): five stars, each a button —
/// choose one to rate, choose it again to clear. Out of ten in steps of two.
struct StarRating: View {
    @Environment(AppState.self) private var state
    @Environment(Toasts.self) private var toasts
    let kind: String
    let id: String
    let value: Double?
    @State private var shown: Int = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { star in
                Button { Task { await rate(star == shown ? 0 : star) } } label: {
                    Focused { focused in
                        Image(systemName: star <= shown ? "star.fill" : "star")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(focused ? Palette.primaryForeground : star <= shown ? Palette.primary : Palette.muted)
                            .frame(width: 64, height: 64)
                            .background(focused ? Palette.primaryHover : .clear, in: Circle())
                            .focusGrow(focused, 1.12)
                            .focusMotion(focused)
                    }
                }
                .buttonStyle(.streamCard)
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                .accessibilityAddTraits(star == shown ? .isSelected : [])
            }
        }
        .onAppear { shown = Int(((value ?? 0) / 2).rounded()) }
    }

    private func rate(_ stars: Int) async {
        let before = shown
        shown = stars
        do {
            let _: Empty = try await state.api.put("api/v1/rating", body: Rating(rateableType: kind, rateableId: id, value: stars == 0 ? nil : stars * 2))
            toasts.show(stars == 0 ? "Rating cleared" : "Rated \(stars) of 5")
        } catch {
            shown = before
            toasts.show("The rating didn't save.", failed: true)
        }
    }

    private struct Rating: Encodable {
        let rateableType: String
        let rateableId: String
        let value: Int?
    }
}

/// "Part of" the collections a title is in.
struct CollectionChips: View {
    @Environment(\.navigate) private var navigate
    let collections: [CollectionRef]

    var body: some View {
        if !collections.isEmpty {
            HStack(spacing: 16) {
                Text("Part of").textStyle(.callout, color: Palette.muted)
                ForEach(collections) { collection in
                    Chip(label: collection.title, on: false) { navigate(.collection(collection.id)) }
                }
            }
        }
    }
}

/// Trailers, featurettes and the rest, playable.
struct ExtrasRow: View {
    @Environment(PlaybackCoordinator.self) private var playback
    let extras: [ExtraCard]

    var body: some View {
        if !extras.isEmpty {
            CardRow(title: "Extras") {
                ForEach(extras) { extra in
                    let card = Card(kind: "extra", id: extra.id, title: extra.title, code: nil, year: nil, images: extra.images, progress: nil,
                                    watched: nil, show: nil, seasonNumber: nil, episodeNumber: nil, unwatchedCount: nil, arrival: nil,
                                    durationSeconds: extra.durationSeconds)
                    Button { playback.play(kind: "extra", id: extra.id) } label: {
                        Focused { focused in
                            VStack(alignment: .leading, spacing: 8) {
                                VideoTile(card: card, focused: focused)
                                if let label = extra.kindLabel { Text(label).textStyle(.caption, color: Palette.primary).focusRise(focused, 12) }
                            }
                        }
                    }
                    .buttonStyle(.streamCard)
                    .accessibilityLabel([extra.title, extra.kindLabel].compactMap { $0 }.joined(separator: ", "))
                }
            }
        }
    }
}

/// The cast, round portraits that go to each person's page.
struct CastRow: View {
    let cast: [CastMember]

    var body: some View {
        let people = cast.filter { $0.role == "cast" }
        if !people.isEmpty {
            CardRow(title: "Cast") {
                ForEach(people.prefix(20)) { member in
                    RouteLink(Route.person(member.personId)) {
                        Focused { PersonCard(name: member.name, role: member.character, portrait: member.image, focused: $0) }
                    }
                    .buttonStyle(.streamCard)
                    .accessibilityLabel([member.name, member.character.map { "as \($0)" }].compactMap { $0 }.joined(separator: " "))
                }
            }
        }
    }
}

/// More like this (the web's MoreLikeThis), from the title's neighbours.
struct SimilarRow: View {
    @Environment(AppState.self) private var state
    let kind: String
    let id: String
    @State private var cards: [Card] = []

    var body: some View {
        Group {
            if !cards.isEmpty {
                CardRow(title: "More like this") { ForEach(cards) { CardLink(card: $0) } }
            }
        }
        .task(id: id) { cards = (try? await state.api.get("api/v1/\(kind == "movie" ? "movies" : "shows")/\(id)/similar")) ?? [] }
    }
}
