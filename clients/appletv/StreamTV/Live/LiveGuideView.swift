import SwiftUI

/// The Grid's guide on the Apple TV (PROPOSAL §7.7, the web's Live page):
/// the focused program above — its channel live and muted beside what it
/// is — and the grid below. Choosing what's on tunes in; anything later
/// offers a reminder or watching it now from the start. A long press
/// favourites or hides a channel.
struct LiveGuideView: View {
    enum Filter: Hashable { case all, favorites }

    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(Toasts.self) private var toasts
    @State private var guide: Guide?
    @State private var error: String?
    @State private var start = GuideGrid.halfHour(Date())
    @State private var filter = Filter.all
    @State private var chosen: (station: GuideStation, airing: Airing)?
    @State private var managing = false
    @State private var now = Date()
    @FocusState private var focusedId: String?
    @State private var placedFocus = false

    /// The listings loaded: half an hour back to a day and a bit ahead.
    @State private var reach = GuideGrid.halfHour(Date()).addingTimeInterval(-1800)...GuideGrid.halfHour(Date()).addingTimeInterval(26 * 3600)

    private var stations: [GuideStation] {
        let all = guide?.stations ?? []
        return filter == .favorites ? all.filter { $0.favorite == true } : all
    }

    private var focused: (station: GuideStation, airing: Airing)? {
        guard let focusedId else { return nil }
        for station in stations {
            if let airing = station.airings.first(where: { $0.id == focusedId }) { return (station, airing) }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            if let guide {
                if guide.stations.isEmpty {
                    EmptyState(title: "No channels yet", detail: "An admin makes channels in Grid › Channels on the web.",
                               systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    details
                    if stations.isEmpty {
                        EmptyState(title: "No favourite channels yet", detail: "Long-press a program to add its channel to your favourites.",
                                   systemImage: "star")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        GuideGrid(stations: stations, timeZone: guide.timeZone, now: now, start: $start, reach: reach,
                                  focus: $focusedId, choose: choose, actions: actions)
                    }
                }
            } else if let error {
                ErrorState(message: error) { Task { await load() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LoadingState(label: "Loading the guide…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, 50)
        .padding(.bottom, 40)
        .task { await load() }
        .task(id: "clock") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
        .confirmationDialog(chosen?.airing.title ?? "", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } })) {
            if let chosen {
                if chosen.airing.reminded == true {
                    Button("Don't remind me") { Task { await remind(chosen.airing, on: false) } }
                } else {
                    Button("Remind me") { Task { await remind(chosen.airing, on: true) } }
                }
                if chosen.airing.kind != "live_stream" {
                    Button("Watch now from the start") { playback.play(kind: chosen.airing.kind, id: chosen.airing.playableId, fromStart: true) }
                }
            }
        } message: {
            if let chosen { Text(timeRange(chosen.airing)) }
        }
        .sheet(isPresented: $managing) { HiddenChannels { Task { await load() } } }
    }

    // MARK: The header

    private var header: some View {
        HStack(spacing: 24) {
            Text("Grid").textStyle(.title)
            Spacer()
            Button("Now") { jump(to: Date()) }.buttonStyle(.stream(.secondary, compact: true))
            Button("Tonight") { jump(to: tonight) }.buttonStyle(.stream(.ghost, compact: true))
            Button("Tomorrow") { jump(to: Date().addingTimeInterval(24 * 3600)) }.buttonStyle(.stream(.ghost, compact: true))
            Segmented(options: [(Filter.all, "All"), (Filter.favorites, "Favourites")], selection: $filter)
            Button { managing = true } label: { Label("Hidden", systemImage: "eye.slash") }
                .buttonStyle(.stream(.ghost, compact: true))
        }
        .focusSection()
    }

    /// Eight in the evening in the guide's zone (tomorrow's, once it's past).
    private var tonight: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: guide?.timeZone ?? "") ?? .current
        let eight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date()
        return eight < Date() ? Date() : eight
    }

    private func jump(to moment: Date) {
        let target = min(max(GuideGrid.halfHour(moment), reach.lowerBound), reach.upperBound.addingTimeInterval(-2 * 3600))
        withAnimation(.easeInOut(duration: 0.3)) { start = target }
        // Focus follows, on the same channel if there is one.
        let row = focused?.station ?? stations.first
        if let airing = row.flatMap({ LiveTime.onAt($0.airings, max(target, Date())).current }) { focusedId = airing.id }
    }

    // MARK: The focused program

    @ViewBuilder private var details: some View {
        HStack(alignment: .top, spacing: 36) {
            GuidePreview(stationId: focused?.station.id, airing: focused?.airing)
            if let (station, airing) = focused {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(station.number) · \(station.name)").textStyle(.eyebrow, color: Palette.muted)
                    Text(airing.title).textStyle(.title2).lineLimit(1)
                    if let subtitle = airing.subtitle { Text(subtitle).textStyle(.body).lineLimit(1) }
                    Text(facts(airing)).textStyle(.callout, color: Palette.muted).lineLimit(1)
                    if let overview = airing.overview {
                        Text(overview).textStyle(.callout, color: Palette.muted).lineLimit(2).frame(maxWidth: 1100, alignment: .leading)
                    }
                }
                .animation(nil, value: airing.id)
            } else {
                Text("Move through the guide to see what's on.").textStyle(.body, color: Palette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(height: 273, alignment: .topLeading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.border, lineWidth: 1.5))
    }

    private func facts(_ airing: Airing) -> String {
        let zone = TimeZone(identifier: guide?.timeZone ?? "") ?? .current
        let day = airing.starts.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated))
        let minutes = Int(airing.ends.timeIntervalSince(airing.starts) / 60)
        return ["\(day) \(timeRange(airing))", "\(minutes) min", airing.contentRating].compactMap { $0 }.joined(separator: " · ")
    }

    private func timeRange(_ airing: Airing) -> String {
        let zone = guide?.timeZone ?? "UTC"
        return "\(LiveTime.clock(airing.starts, timeZone: zone)) – \(LiveTime.clock(airing.ends, timeZone: zone))"
    }

    // MARK: Choosing, and the long press

    private func choose(_ station: GuideStation, _ airing: Airing) {
        let now = Date()
        if airing.starts <= now && airing.ends > now { playback.watchLive(number: station.number) } else { chosen = (station, airing) }
    }

    private func actions(_ station: GuideStation, _ airing: Airing) -> [GuideGrid.Action] {
        var list: [GuideGrid.Action] = []
        let now = Date()
        if airing.starts <= now && airing.ends > now {
            list.append(.init(title: "Watch channel \(station.number)", systemImage: "play.fill") { playback.watchLive(number: station.number) })
        }
        // A game (a stream) has no start to go back to.
        if airing.kind != "live_stream" {
            list.append(.init(title: "Watch from the start", systemImage: "backward.end.fill") {
                playback.play(kind: airing.kind, id: airing.playableId, fromStart: true)
            })
        }
        if airing.starts > now {
            list.append(airing.reminded == true
                ? .init(title: "Don't remind me", systemImage: "bell.slash") { Task { await remind(airing, on: false) } }
                : .init(title: "Remind me", systemImage: "bell") { Task { await remind(airing, on: true) } })
        }
        list.append(station.favorite == true
            ? .init(title: "Remove from favourites", systemImage: "star.slash") { Task { await favorite(station, on: false) } }
            : .init(title: "Add to favourites", systemImage: "star") { Task { await favorite(station, on: true) } })
        list.append(.init(title: "Hide from my guide", systemImage: "eye.slash", destructive: true) { Task { await hide(station) } })
        return list
    }

    // MARK: Loading and changing

    private func load() async {
        do {
            let from = GuideGrid.halfHour(Date()).addingTimeInterval(-1800)
            let to = from.addingTimeInterval(26 * 3600)
            let loaded: Guide = try await state.api.get("api/v1/guide", query: ["from": from.ISO8601Format(), "to": to.ISO8601Format()])
            guide = loaded
            reach = from...to
            error = nil
            if !placedFocus, let first = loaded.stations.first, let airing = LiveTime.onAt(first.airings, Date()).current {
                placedFocus = true
                focusedId = airing.id
            }
        } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }

    private func remind(_ airing: Airing, on: Bool) async {
        do {
            if on {
                let _: Empty = try await state.api.put("api/v1/airings/\(airing.id)/reminder")
                toasts.show("We'll remind you when \(airing.title) starts")
            } else {
                try await state.api.delete("api/v1/airings/\(airing.id)/reminder")
                toasts.show("Reminder removed")
            }
            await load()
        } catch {
            state.handle(error)
            toasts.show("That didn't save.", failed: true)
        }
    }

    private func favorite(_ station: GuideStation, on: Bool) async {
        do {
            if on {
                let _: Empty = try await state.api.put("api/v1/stations/\(station.id)/favorite")
            } else {
                try await state.api.delete("api/v1/stations/\(station.id)/favorite")
            }
            toasts.show(on ? "Channel \(station.number) is a favourite" : "Channel \(station.number) removed from favourites")
            await load()
        } catch {
            state.handle(error)
            toasts.show("That didn't save.", failed: true)
        }
    }

    private func hide(_ station: GuideStation) async {
        do {
            let _: Empty = try await state.api.put("api/v1/stations/\(station.id)/hide")
            toasts.show("Channel \(station.number) hidden. Bring it back from Hidden.")
            await load()
        } catch {
            state.handle(error)
            toasts.show("That didn't save.", failed: true)
        }
    }
}

/// The channels this profile hid from its guide, each to bring back.
private struct HiddenChannels: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let changed: () -> Void
    @State private var stations: [Station]?
    @State private var error: String?

    struct Station: Decodable, Identifiable {
        let id: String
        let number: String
        let name: String
        let hidden: Bool?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("Hidden channels").textStyle(.title)
            if let stations {
                let hidden = stations.filter { $0.hidden == true }
                if hidden.isEmpty {
                    EmptyState(title: "None", detail: "Hide a channel from its program's long press in the guide.", systemImage: "eye")
                }
                ForEach(hidden) { station in
                    HStack(spacing: 30) {
                        Text(station.number).font(.system(size: 34, weight: .semibold, design: .monospaced)).frame(width: 120, alignment: .leading)
                        Text(station.name).textStyle(.headline)
                        Spacer()
                        Button { Task { await show(station) } } label: { Label("Show in my guide", systemImage: "eye") }
                            .buttonStyle(.stream(.secondary, compact: true))
                    }
                    .padding(.vertical, 8)
                }
            } else if let error {
                ErrorState(message: error) { Task { await load() } }
            } else {
                LoadingState()
            }
            Spacer()
        }
        .padding(Space.margin * 1.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.background.ignoresSafeArea())
        .task { await load() }
    }

    private func load() async {
        do {
            stations = try await state.api.get("api/v1/stations", query: ["hidden": "1"])
            error = nil
        } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }

    private func show(_ station: Station) async {
        do {
            try await state.api.delete("api/v1/stations/\(station.id)/hide")
            changed()
            await load()
        } catch {
            state.handle(error)
        }
    }
}
