import SwiftUI

/// The web's cards (components/viewing/cards.tsx), a remote's width apart.
enum CardSize {
    static let poster = CGSize(width: 260, height: 390)
    static let wide = CGSize(width: 460, height: 259)
}

/// A film or show: its poster with the watched tick or the unwatched count,
/// how far in, and its name and year under it.
struct PosterCard: View {
    let card: Card
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                ArtworkImage(artwork: card.image, width: CardSize.poster.width, fallback: card.heading)
                if let progress = card.progress, progress > 0 { ProgressBar(value: progress) }
            }
            .frame(width: CardSize.poster.width, height: CardSize.poster.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(alignment: .topTrailing) { corner.padding(12) }
            .focusLift(focused)
            caption
        }
        .frame(width: CardSize.poster.width, alignment: .leading)
    }

    @ViewBuilder private var corner: some View {
        if card.kind == "movie", card.watched == true {
            CornerMark(kind: .watched)
        } else if card.kind == "show", let count = card.unwatchedCount, count > 0 {
            CornerMark(kind: .count(count))
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.heading).textStyle(.headline, color: focused ? Palette.foreground : Palette.foreground.opacity(0.85)).lineLimit(1)
            Text(card.detail ?? " ").textStyle(.caption, color: Palette.muted).lineLimit(1)
        }
        .focusRise(focused, 12)
        .focusMotion(focused)
    }
}

/// A 16:9 card that plays when pressed: Continue watching and Next up. An
/// episode shows its still, a film its backdrop; focused, a play glyph.
struct WideCard: View {
    let card: Card
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                ArtworkImage(artwork: card.wideImage, width: CardSize.wide.width, fallback: card.heading)
                if focused {
                    Image(systemName: "play.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Palette.foreground)
                        .frame(width: 84, height: 84)
                        .background(Palette.background.opacity(0.8), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
                if let progress = card.progress, progress > 0 { ProgressBar(value: progress) }
            }
            .frame(width: CardSize.wide.width, height: CardSize.wide.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if card.watched == true { CornerMark(kind: .watched).padding(12) }
            }
            .focusLift(focused, scale: 1.05)
            .focusMotion(focused)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.heading).textStyle(.headline, color: focused ? Palette.foreground : Palette.foreground.opacity(0.85)).lineLimit(1)
                if let detail = card.detail, !detail.isEmpty { Text(detail).textStyle(.caption, color: Palette.muted).lineLimit(1) }
            }
            .focusRise(focused, 12)
            .focusMotion(focused)
        }
        .frame(width: CardSize.wide.width, alignment: .leading)
    }
}

/// A channel video, YouTube-style: the thumbnail with its length and
/// progress, the title, and whose it is.
struct VideoTile: View {
    let card: Card
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkImage(artwork: card.wideImage, width: CardSize.wide.width, fallback: card.heading)
                if let duration = card.durationSeconds {
                    Text(Clock.format(duration)).font(TextStyle.caption.font.monospacedDigit()).foregroundStyle(Palette.foreground)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Palette.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                        .padding(12)
                }
                if let progress = card.progress, progress > 0 { ProgressBar(value: progress) }
            }
            .frame(width: CardSize.wide.width, height: CardSize.wide.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .focusLift(focused, scale: 1.05)
            HStack(alignment: .top, spacing: 16) {
                if let channel = card.channel {
                    ArtworkImage(artwork: channel.avatar, width: 56, fallback: String(channel.title.prefix(1)))
                        .frame(width: 56, height: 56).clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.heading).textStyle(.headline, color: focused ? Palette.foreground : Palette.foreground.opacity(0.85)).lineLimit(2)
                    if let channel = card.channel { Text(channel.title).textStyle(.caption, color: Palette.muted).lineLimit(1) }
                }
            }
            .focusRise(focused, 12)
            .focusMotion(focused)
        }
        .frame(width: CardSize.wide.width, alignment: .leading)
    }
}

/// A home video: the moment, where it was, and whether it's a favourite.
struct ClipTile: View {
    let card: Card
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                ArtworkImage(artwork: card.wideImage, width: CardSize.wide.width, fallback: card.heading)
                if let progress = card.progress, progress > 0 { ProgressBar(value: progress) }
            }
            .frame(width: CardSize.wide.width, height: CardSize.wide.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let duration = card.durationSeconds {
                    Text(Clock.format(duration)).font(TextStyle.caption.font.monospacedDigit()).foregroundStyle(Palette.foreground)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Palette.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 12).padding(.bottom, card.progress ?? 0 > 0 ? 18 : 12)
                }
            }
            .overlay(alignment: .topLeading) {
                if card.favorite == true {
                    Image(systemName: "heart.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(Palette.primary)
                        .padding(10).background(Palette.background.opacity(0.75), in: Circle()).padding(12)
                        .accessibilityLabel("Favourite")
                }
            }
            .overlay(alignment: .topTrailing) {
                if card.watched == true { CornerMark(kind: .watched).padding(12) }
            }
            .focusLift(focused, scale: 1.05)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.city ?? card.heading).textStyle(.headline).lineLimit(1)
                if let captured = card.capturedAt { Text(Captured.moment(captured)).textStyle(.caption, color: Palette.muted).lineLimit(1) }
            }
            .focusRise(focused, 12)
            .focusMotion(focused)
        }
        .frame(width: CardSize.wide.width, alignment: .leading)
    }
}

/// When a home video was taken. A camera's wall clock (no offset in the
/// string) is shown as written; an instant is shown in this TV's zone.
enum Captured {
    private static func parse(_ value: String) -> (Date, TimeZone)? {
        if value.count > 19, let date = ISO8601DateFormatter().date(from: value) { return (date, .current) }
        let floating = DateFormatter()
        floating.locale = Locale(identifier: "en_US_POSIX")
        floating.timeZone = TimeZone(identifier: "UTC")
        floating.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return floating.date(from: String(value.prefix(19))).map { ($0, TimeZone(identifier: "UTC")!) }
    }

    private static func format(_ value: String, _ template: String) -> String? {
        guard let (date, zone) = parse(value) else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// "14 Aug 2026"
    static func day(_ value: String) -> String { format(value, "dMMMyyyy") ?? String(value.prefix(10)) }
    /// "14 Aug 2026, 10:12"
    static func moment(_ value: String) -> String { format(value, "dMMMyyyyjjmm") ?? String(value.prefix(10)) }
    /// "August 2026", and a key to group by.
    static func month(_ value: String) -> (key: String, label: String) {
        (String(value.prefix(7)), format(value, "MMMMyyyy") ?? String(value.prefix(7)))
    }
}

/// A YouTube channel: its round avatar, what's unwatched on it, its name.
struct ChannelCircle: View {
    let title: String
    let detail: String?
    let avatar: Artwork?
    var unwatched = 0
    let focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            ArtworkImage(artwork: avatar, width: 200, fallback: String(title.prefix(1)))
                .frame(width: 200, height: 200)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(focused ? Palette.primary : Palette.border, lineWidth: focused ? 5 : 1.5))
                .overlay(alignment: .topTrailing) {
                    if unwatched > 0 { CornerMark(kind: .count(unwatched)).accessibilityLabel("\(unwatched) unwatched") }
                }
                .focusGrow(focused, 1.08)
                .shadow(color: Palette.scrim.opacity(focused ? 0.5 : 0), radius: 20, y: 10)
                .focusMotion(focused)
            VStack(spacing: 4) {
                Text(title).textStyle(.headline).lineLimit(1)
                if let detail { Text(detail).textStyle(.caption, color: Palette.muted).lineLimit(1) }
            }
            .focusRise(focused, 10)
        }
        .frame(width: 240)
    }
}

/// Someone in the cast: a round portrait, their name and who they played.
struct PersonCard: View {
    let name: String
    let role: String?
    let portrait: Artwork?
    let focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            ArtworkImage(artwork: portrait, width: 200, fallback: initials)
                .frame(width: 200, height: 200)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(focused ? Palette.primary : Palette.border, lineWidth: focused ? 5 : 1.5))
                .focusGrow(focused, 1.08)
                .shadow(color: Palette.scrim.opacity(focused ? 0.5 : 0), radius: 20, y: 10)
                .focusMotion(focused)
            VStack(spacing: 4) {
                Text(name).textStyle(.headline).lineLimit(1)
                if let role { Text(role).textStyle(.caption, color: Palette.muted).lineLimit(1) }
            }
            .focusRise(focused, 10)
        }
        .frame(width: 220)
    }

    private var initials: String { name.split(separator: " ").compactMap(\.first).prefix(2).map(String.init).joined() }
}

/// A Grid channel: what's on it over the program's picture, its
/// number and name, how far through, and LIVE.
struct LiveCard: View {
    let station: GuideStation
    let airing: Airing?
    let now: Date
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                ArtworkImage(artwork: airing?.still, width: CardSize.wide.width, fallback: station.name)
                LinearGradient(colors: [.clear, Palette.background.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    Text(station.number).font(TextStyle.number.font).foregroundStyle(Palette.foreground)
                    Spacer()
                    Text("LIVE").font(TextStyle.eyebrow.font).foregroundStyle(Palette.foreground)
                        .padding(.horizontal, 12).padding(.vertical, 4).background(Palette.negative, in: Capsule())
                }
                .padding(18)
                if let airing {
                    ProgressBar(value: LiveTime.offset(starts: airing.starts, ends: airing.ends, at: now) / max(airing.ends.timeIntervalSince(airing.starts), 1))
                }
            }
            .frame(width: CardSize.wide.width, height: CardSize.wide.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .focusLift(focused, scale: 1.05)
            VStack(alignment: .leading, spacing: 4) {
                Text(airing?.title ?? "Between programs").textStyle(.headline).lineLimit(1)
                Text([station.name, airing?.subtitle].compactMap { $0 }.joined(separator: " · ")).textStyle(.caption, color: Palette.muted).lineLimit(1)
            }
            .focusRise(focused, 12)
            .focusMotion(focused)
        }
        .frame(width: CardSize.wide.width, alignment: .leading)
    }
}

/// How a card looks in a row of a given kind (Viewing::Home's hub kinds).
enum CardStyle { case poster, wide, video, clip }

/// Where a card goes: a page for films and shows, the player for the rest;
/// a long press for what else can be done to it.
struct CardLink: View {
    @Environment(PlaybackCoordinator.self) private var playback
    let card: Card
    var style: CardStyle = .poster
    /// In Continue watching: it can be taken out.
    var dismissible = false

    var body: some View {
        Group {
            if style == .poster, card.kind == "movie" || card.kind == "show" {
                RouteLink(card.kind == "movie" ? Route.movie(card.id) : Route.show(card.id)) {
                    Focused { PosterCard(card: card, focused: $0) }
                }
            } else if card.kind == "show" {
                // A batch of a show's episodes in Recently added: opens the show.
                RouteLink(Route.show(card.id)) {
                    Focused { WideCard(card: card, focused: $0) }
                }
            } else {
                Button { playback.play(kind: card.kind, id: card.id) } label: {
                    Focused { focused in
                        switch style {
                        case .video: VideoTile(card: card, focused: focused)
                        case .clip: ClipTile(card: card, focused: focused)
                        default: WideCard(card: card, focused: focused)
                        }
                    }
                }
            }
        }
        .buttonStyle(.streamCard)
        .itemActions(card, dismissible: dismissible)
        .accessibilityLabel(label)
        .accessibilityHint("Press and hold for more")
    }

    /// What the card shows, read out: the corner marks too.
    private var label: String {
        let progress = card.progress.flatMap { $0 > 0 ? "\(Int(($0 * 100).rounded())) percent watched" : nil }
        let unwatched = card.unwatchedCount.flatMap { $0 > 0 ? "\($0) unwatched" : nil }
        return [card.heading, card.detail, card.watched == true ? "watched" : progress, unwatched, card.favorite == true ? "favourite" : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A row of cards with its heading (the web's Row): scrolls sideways, and
/// lets focused cards grow past its edges.
struct CardRow<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: title, detail: detail).padding(.horizontal, Space.margin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Space.cardGap) { content() }
                    .padding(.horizontal, Space.margin)
                    .padding(.vertical, 28)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}
