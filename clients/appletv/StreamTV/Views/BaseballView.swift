import SwiftUI

/// The web's lib/baseball.ts: how a game's day, inning, start and ending
/// read, and what of it can be watched.
enum Baseball {
    static let labels: [BaseballGame.State: String] = [.live: "Live", .upcoming: "Upcoming", .final: "Final", .off: "Not played"]

    private static let schedule: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter
    }()

    /// Today, Yesterday, Tomorrow, or "Sat, Oct 18" — against MLB's today, not this Apple TV's.
    static func dayLabel(_ date: String, today: String) -> String {
        guard let day = schedule.date(from: date), let now = schedule.date(from: today) else { return date }
        switch Calendar(identifier: .gregorian).dateComponents([.day], from: now, to: day).day {
        case 0: return "Today"
        case -1: return "Yesterday"
        case 1: return "Tomorrow"
        default: return weekday.string(from: day)
        }
    }

    private static let halves = ["top": "Top", "bottom": "Bot", "middle": "Mid", "end": "End"]

    /// "Top 7th", "Mid 7th".
    static func inningLabel(_ inning: BaseballGame.Inning) -> String {
        "\(halves[inning.half] ?? "") \(inning.ordinal)".trimmingCharacters(in: .whitespaces)
    }

    /// When it starts, here: "7:08 PM", or TBD.
    static func startTime(_ game: BaseballGame) -> String {
        game.startTimeTbd ? "TBD" : game.starts.formatted(date: .omitted, time: .shortened)
    }

    /// "Final", or "Final/10" for extra innings.
    static func finalLabel(_ game: BaseballGame) -> String {
        game.innings.count > game.scheduledInnings ? "Final/\(game.innings.count)" : "Final"
    }

    struct Choice: Equatable {
        let side: BaseballSide.Which
        /// The team whose broadcast it is; nil when one broadcast serves both.
        let team: String?
        let channel: String?

        var label: String {
            let name = team.map { "\($0) broadcast" } ?? "Watch"
            return [name, channel].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Each team's own broadcast, away first — or, when there's only a
    /// national one (the postseason), that one, once.
    static func choices(_ game: BaseballGame) -> [Choice] {
        let sides = BaseballSide.Which.allCases.compactMap { side -> Choice? in
            guard let broadcast = game.broadcasts.first(where: { $0.side == side.rawValue }) else { return nil }
            return Choice(side: side, team: game.side(side).team.club, channel: broadcast.name)
        }
        return sides.isEmpty ? [Choice(side: .home, team: nil, channel: game.broadcasts.first?.name)] : sides
    }

    /// A day's games as Baseball shows them: live, upcoming, final, not played.
    static func groups(_ games: [BaseballGame]) -> [(state: BaseballGame.State, games: [BaseballGame])] {
        BaseballGame.State.allCases.map { state in (state, games.filter { $0.state == state }) }.filter { !$0.games.isEmpty }
    }

    /// How often to ask again: while a game is on, every few seconds; today, now and then; a settled day, never.
    static func refresh(_ day: BaseballDay) -> Duration? {
        if day.games.contains(where: { $0.state == .live || $0.watchable }) { return .seconds(15) }
        return day.date == day.today ? .seconds(60) : nil
    }

    /// Why a game can't be played now (the server's words for it).
    static func unwatchable(_ game: BaseballGame) -> String {
        game.state == .upcoming ? "MLB.tv starts this game's broadcast shortly before first pitch" : "This game isn't on MLB.tv now"
    }
}

/// Baseball (PROPOSAL §7.8, the web's pages/Baseball.tsx): a day of MLB
/// games from MLB's schedule as a scoreboard — live first, then what's
/// coming, then how the rest ended — asked again every few seconds while a
/// game is on. Choosing a game that's on plays it from MLB.tv as a team's
/// stream, in the same player as any camera or web stream; a long press
/// picks the other team's broadcast.
struct BaseballView: View {
    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(Toasts.self) private var toasts
    /// The day asked for; nil is MLB's today (or the next day with games).
    @State private var asked: String?
    @State private var day: BaseballDay?
    @State private var error: String?
    @State private var starting: Int?

    static let cardWidth: CGFloat = 794
    private let columns = Array(repeating: GridItem(.fixed(BaseballView.cardWidth), spacing: Space.cardGap, alignment: .top), count: 2)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                LibraryHeader(title: "Baseball", detail: day.map { Baseball.dayLabel($0.date, today: $0.today) }) {
                    if let day {
                        IconButton(label: "Day before", systemImage: "chevron.left") { asked = day.previousDate }
                            .disabled(day.previousDate == nil)
                        IconButton(label: "Day after", systemImage: "chevron.right") { asked = day.nextDate }
                            .disabled(day.nextDate == nil)
                        if day.date != day.today {
                            Button("Today") { asked = nil }.buttonStyle(.secondary)
                        }
                    }
                }
                if let day {
                    if day.games.isEmpty {
                        EmptyState(title: "No games",
                                   detail: day.nextDate == nil ? "MLB has nothing scheduled yet." : "Nothing's scheduled this day. The arrows go to the days with games.",
                                   systemImage: "baseball")
                    }
                    ForEach(Baseball.groups(day.games), id: \.state) { group in
                        VStack(alignment: .leading, spacing: 28) {
                            Text(Baseball.labels[group.state] ?? "").textStyle(.eyebrow, color: Palette.muted)
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: Space.cardGap) {
                                ForEach(group.games) { game in
                                    GameCard(game: game, starting: starting == game.id, watch: { watch(game, $0) })
                                }
                            }
                            .focusSection()
                        }
                    }
                } else if let error {
                    ErrorState(message: error) { Task { await load() } }
                } else {
                    LoadingState()
                }
            }
            .padding(Space.margin)
        }
        .onChange(of: asked) {
            day = nil
            error = nil
        }
        .task(id: asked) {
            while !Task.isCancelled {
                await load()
                guard let every = day.flatMap(Baseball.refresh) else { return }
                try? await Task.sleep(for: every)
            }
        }
    }

    private func load() async {
        do {
            let answer: BaseballDay = try await state.api.get("api/v1/baseball/games", query: asked.map { ["date": $0] } ?? [:])
            day = answer
            error = nil
        } catch {
            state.handle(error)
            // A refresh that fails keeps the day on screen.
            if day == nil { self.error = (error as? APIError)?.messages.first ?? "Could not load MLB's schedule." }
        }
    }

    /// The team's stream that plays it, then the stream player.
    private func watch(_ game: BaseballGame, _ side: BaseballSide.Which) {
        guard game.watchable else { return toasts.show(Baseball.unwatchable(game), failed: true) }
        guard starting == nil else { return }
        starting = game.id
        Task {
            defer { starting = nil }
            do {
                let answer: BaseballWatch = try await state.api.post("api/v1/baseball/games/\(game.id)/watch", body: WatchBody(side: side))
                playback.watchStream(id: answer.liveStreamId, name: answer.name)
            } catch {
                state.handle(error)
                toasts.show((error as? APIError)?.messages.first ?? "This game couldn't be played", failed: true)
            }
        }
    }
}

private struct WatchBody: Encodable {
    let side: BaseballSide.Which
}

/// One game, as a scoreboard shows it (the web's GameCard): both teams with
/// their logos and records, the score, and — while it's on — the inning,
/// count, outs and who's on base; before it, the start and the probable
/// pitchers; after it, the line score and the decisions.
struct GameCard: View {
    let game: BaseballGame
    let starting: Bool
    let watch: (BaseballSide.Which) -> Void

    private var choices: [Baseball.Choice] { game.watchable ? Baseball.choices(game) : [] }

    var body: some View {
        Button { watch(choices.first?.side ?? .home) } label: {
            Focused { focused in card(focused) }
        }
        .buttonStyle(.streamCard)
        .contextMenu {
            ForEach(choices, id: \.side) { choice in
                Button { watch(choice.side) } label: { Label(choice.label, systemImage: "play.fill") }
            }
        }
        .accessibilityLabel(spoken)
    }

    private func card(_ focused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text(heading).textStyle(.caption, color: Palette.muted).lineLimit(1)
                Spacer(minLength: 0)
                if game.state == .live { LivePill(compact: true) }
            }
            .frame(height: 34)
            .padding(.horizontal, 32).padding(.top, 22)
            HStack(spacing: 0) {
                VStack(spacing: 20) {
                    TeamRow(side: game.away, game: game)
                    TeamRow(side: game.home, game: game)
                }
                .padding(.vertical, 22)
                .padding(.trailing, 28)
                Rectangle().fill(Palette.border).frame(width: 1.5).padding(.vertical, 18)
                Situation(game: game).frame(width: 190)
            }
            .padding(.horizontal, 32)
            if !game.innings.isEmpty {
                LineScore(game: game).padding(.horizontal, 32).padding(.bottom, 22)
            }
            Rectangle().fill(Palette.border).frame(height: 1.5)
            footer(focused)
                .frame(minHeight: 74)
                .padding(.horizontal, 32)
        }
        .frame(width: BaseballView.cardWidth, alignment: .leading)
        .background(focused ? Palette.surfaceRaised : Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .focusLift(focused, scale: 1.03)
    }

    private var heading: String {
        let place = game.series.map { [$0.name, $0.status].compactMap { $0 }.joined(separator: " · ") } ?? game.venue ?? ""
        return [place, game.doubleHeader.map { "Game \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private func footer(_ focused: Bool) -> some View {
        HStack(spacing: 18) {
            if let first = choices.first {
                Image(systemName: "play.fill").foregroundStyle(focused ? Palette.primary : Palette.muted)
                Text(starting ? "Starting…" : first.label).textStyle(.callout, color: focused ? Palette.foreground : Palette.muted).lineLimit(1)
                Spacer(minLength: 0)
                if let other = choices.dropFirst().first, let team = other.team {
                    Text("Hold for the \(team)'").textStyle(.caption, color: Palette.muted).lineLimit(1)
                }
            } else if game.state == .final, let decisions = game.decisions {
                Text([decisions.winner.map { "W: \($0)" }, decisions.loser.map { "L: \($0)" }, decisions.save.map { "S: \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .textStyle(.caption, color: Palette.muted).lineLimit(1)
            } else if !game.broadcasts.isEmpty {
                Image(systemName: "tv").foregroundStyle(Palette.muted)
                Text(game.broadcasts.map(\.name).joined(separator: " · ")).textStyle(.caption, color: Palette.muted).lineLimit(1)
            } else {
                Text(game.venue ?? "").textStyle(.caption, color: Palette.muted).lineLimit(1)
            }
        }
        .font(TextStyle.callout.font)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Cleveland Guardians 2, Tampa Bay Rays 1, Top 7th."
    private var spoken: String {
        let scored = game.state == .live || game.state == .final
        let teams = [game.away, game.home].map { side in
            [side.team.name, scored ? side.score.map(String.init) : nil].compactMap { $0 }.joined(separator: " ")
        }
        let now: String
        switch game.state {
        case .live: now = game.inning.map(Baseball.inningLabel) ?? game.status
        case .upcoming: now = Baseball.startTime(game)
        case .final: now = Baseball.finalLabel(game)
        case .off: now = game.status
        }
        return ([scored ? teams.joined(separator: ", ") : teams.joined(separator: " at "), now]
            + (choices.first.map { [$0.label] } ?? [])).joined(separator: ", ")
    }
}

private struct TeamRow: View {
    let side: BaseballSide
    let game: BaseballGame

    var body: some View {
        let lost = game.state == .final && !side.winner
        HStack(spacing: 22) {
            TeamLogo(team: side.team, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(side.team.club).textStyle(.title2, color: lost ? Palette.muted : Palette.foreground).lineLimit(1)
                    if let record = side.record { Text(record).textStyle(.caption, color: Palette.muted) }
                }
                if game.state == .upcoming, let pitcher = side.probablePitcher {
                    Text(pitcher).textStyle(.caption, color: Palette.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let score = side.score, game.state == .live || game.state == .final {
                Text("\(score)").font(TextStyle.title.font.monospacedDigit()).foregroundStyle(lost ? Palette.muted : Palette.foreground)
            }
        }
    }
}

/// MLB's logo for a club (PNG: tvOS draws no SVG), with a faint outline so
/// a navy one still reads on the dark surface.
struct TeamLogo: View {
    let team: BaseballSide.Team
    let size: CGFloat

    var body: some View {
        ArtworkImage(artwork: Artwork(src: team.logoPngUrl, color: nil), width: size, contentMode: .fit, logo: true)
            .frame(width: size, height: size)
            .shadow(color: Palette.foreground.opacity(0.55), radius: 1)
            .accessibilityHidden(true)
    }
}

/// What's happening now: the inning, bases, outs and count; the start; or how it ended.
private struct Situation: View {
    let game: BaseballGame

    var body: some View {
        VStack(spacing: 12) {
            switch game.state {
            case .live:
                if let inning = game.inning {
                    Text(Baseball.inningLabel(inning)).textStyle(.headline)
                    Bases(bases: inning.bases)
                    if inning.half == "top" || inning.half == "bottom" {
                        HStack(spacing: 12) {
                            Outs(outs: inning.outs)
                            Text("\(inning.balls)-\(inning.strikes)").font(TextStyle.caption.font.monospacedDigit()).foregroundStyle(Palette.muted)
                        }
                    }
                } else {
                    Text(game.status).textStyle(.headline).multilineTextAlignment(.center)
                }
            case .upcoming:
                Text(Baseball.startTime(game)).textStyle(.headline)
                if game.watchable { Text(game.status).textStyle(.caption, color: Palette.positive) }
            case .final:
                Text(Baseball.finalLabel(game)).textStyle(.headline)
            case .off:
                Text(game.status).textStyle(.caption, color: Palette.warning).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, 20)
    }
}

/// The diamond: second at the top, first on the right.
private struct Bases: View {
    let bases: BaseballGame.Inning.Bases

    var body: some View {
        ZStack {
            base(bases.second).offset(y: -12)
            base(bases.third).offset(x: -20, y: 8)
            base(bases.first).offset(x: 20, y: 8)
        }
        .frame(width: 72, height: 52)
        .accessibilityElement()
        .accessibilityLabel(runners)
    }

    private func base(_ on: Bool) -> some View {
        Rectangle().fill(on ? Palette.warning : .clear)
            .overlay(Rectangle().strokeBorder(on ? Palette.warning : Palette.muted, lineWidth: 2.5))
            .frame(width: 18, height: 18)
            .rotationEffect(.degrees(45))
    }

    private var runners: String {
        let on = [bases.first ? "first" : nil, bases.second ? "second" : nil, bases.third ? "third" : nil].compactMap { $0 }
        return on.isEmpty ? "Bases empty" : "On \(on.joined(separator: ", "))"
    }
}

private struct Outs: View {
    let outs: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(index < outs ? Palette.foreground : .clear)
                    .overlay(Circle().strokeBorder(index < outs ? Palette.foreground : Palette.muted, lineWidth: 2))
                    .frame(width: 13, height: 13)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(outs) \(outs == 1 ? "out" : "outs")")
    }
}

/// Runs by inning, then R, H and E.
private struct LineScore: View {
    let game: BaseballGame

    var body: some View {
        let count = max(game.scheduledInnings, game.innings.count)
        Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 6) {
            GridRow {
                Rectangle().fill(.clear).frame(width: 76, height: 1)
                ForEach(1...count, id: \.self) { number in cell("\(number)") }
                cell("R", color: Palette.foreground, bold: true)
                cell("H")
                cell("E")
            }
            ForEach(BaseballSide.Which.allCases, id: \.self) { which in
                let side = game.side(which)
                GridRow {
                    Text(side.team.abbreviation).textStyle(.caption, color: Palette.muted).gridColumnAlignment(.leading)
                    ForEach(1...count, id: \.self) { number in
                        let runs = game.innings.first { $0.number == number }
                        cell((which == .away ? runs?.away : runs?.home).map(String.init) ?? "")
                    }
                    cell(side.score.map(String.init) ?? "", color: Palette.foreground, bold: true)
                    cell(side.hits.map(String.init) ?? "")
                    cell(side.errors.map(String.init) ?? "")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func cell(_ text: String, color: Color = Palette.muted, bold: Bool = false) -> some View {
        Text(text).font(TextStyle.caption.font.monospacedDigit().weight(bold ? .bold : .medium)).foregroundStyle(color)
            .frame(width: game.innings.count > 12 ? 34 : 44)
    }
}
