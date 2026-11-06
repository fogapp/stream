import SwiftUI

/// The guide's grid (PROPOSAL §7.7, the web's GuideGrid): channels down a
/// column that stays put, half hours across a header that stays put,
/// programs as wide as they are long, and a line at now. It shows a window
/// of time; reaching its edge slides it along half an hour.
struct GuideGrid: View {
    struct Sizes {
        var channelWidth: CGFloat = 230
        var rowHeight: CGFloat = 104
        var headerHeight: CGFloat = 56
        /// How much time the window shows.
        var span: TimeInterval = 2 * 3600
    }

    /// Something a long press offers on a program.
    struct Action: Identifiable {
        let title: String
        let systemImage: String
        var destructive = false
        let perform: () -> Void
        var id: String { title }
    }

    let stations: [GuideStation]
    let timeZone: String
    let now: Date
    @Binding var start: Date
    /// Where the listings loaded reach: the window never slides past them.
    let reach: ClosedRange<Date>
    var sizes = Sizes()
    let focus: FocusState<String?>.Binding
    let choose: (GuideStation, Airing) -> Void
    var actions: (GuideStation, Airing) -> [Action] = { _, _ in [] }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let timeline = proxy.size.width - sizes.channelWidth
            VStack(spacing: 0) {
                header(timeline)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(stations) { station in row(station, timeline) }
                    }
                }
                .scrollClipDisabled(false)
            }
            .overlay(alignment: .topLeading) { nowLine(timeline, height: proxy.size.height) }
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.border, lineWidth: 1.5))
        }
    }

    private var end: Date { start.addingTimeInterval(sizes.span) }

    private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / sizes.span) * width
    }

    // MARK: The header and the line at now

    private func header(_ width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(start.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: timeZone) ?? .current).weekday(.wide)))
                .textStyle(.caption, color: Palette.muted)
                .padding(.leading, 24)
                .frame(width: sizes.channelWidth, alignment: .leading)
            ZStack(alignment: .leading) {
                ForEach(halfHours, id: \.self) { tick in
                    HStack(spacing: 0) {
                        Rectangle().fill(Palette.border).frame(width: 1.5)
                        Text(LiveTime.clock(tick, timeZone: timeZone)).font(TextStyle.caption.font.monospacedDigit())
                            .foregroundStyle(Palette.muted).padding(.leading, 12)
                    }
                    .padding(.leading, x(tick, width))
                }
            }
            .frame(width: width, height: sizes.headerHeight, alignment: .leading)
            .clipped()
        }
        .frame(height: sizes.headerHeight)
        .background(Palette.surfaceRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1.5) }
    }

    private var halfHours: [Date] {
        var ticks: [Date] = []
        var tick = start
        while tick < end {
            ticks.append(tick)
            tick = tick.addingTimeInterval(1800)
        }
        return ticks
    }

    @ViewBuilder private func nowLine(_ width: CGFloat, height: CGFloat) -> some View {
        if now >= start, now < end {
            let at = sizes.channelWidth + x(now, width)
            ZStack(alignment: .top) {
                Rectangle().fill(Palette.negative).frame(width: 3, height: height - sizes.headerHeight)
                    .padding(.top, sizes.headerHeight)
                Rectangle().fill(Palette.negative).frame(width: 14, height: 14).rotationEffect(.degrees(45))
                    .padding(.top, sizes.headerHeight - 7)
            }
            .offset(x: at - 7)
            .frame(width: 14, alignment: .center)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: A channel's row

    private func row(_ station: GuideStation, _ width: CGFloat) -> some View {
        let programs = LiveTime.programs(station.airings).filter { $0.ends > start && $0.airing.starts < end }
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(station.number).font(.system(size: 34, weight: .semibold, design: .monospaced))
                    if station.favorite == true {
                        Image(systemName: "star.fill").font(.system(size: 18)).foregroundStyle(Palette.warning).accessibilityLabel("Favourite")
                    }
                }
                Text(station.callSign ?? station.name).textStyle(.caption, color: Palette.muted).lineLimit(1)
            }
            .foregroundStyle(Palette.foreground)
            .padding(.horizontal, 24)
            .frame(width: sizes.channelWidth, height: sizes.rowHeight, alignment: .leading)
            .background(Palette.surface)
            .overlay(alignment: .trailing) { Rectangle().fill(Palette.border).frame(width: 1.5) }
            ZStack(alignment: .leading) {
                ForEach(programs, id: \.airing.id) { program in
                    cell(station, program.airing, ends: program.ends, width)
                }
            }
            .frame(width: width, height: sizes.rowHeight, alignment: .leading)
            .clipped()
            .focusSection()
            .onMoveCommand { direction in slide(direction, in: station) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1.5) }
    }

    private func cell(_ station: GuideStation, _ airing: Airing, ends: Date, _ width: CGFloat) -> some View {
        let left = max(x(airing.starts, width), 0)
        let right = min(x(ends, width), width)
        let onNow = airing.starts <= now && ends > now
        let cut = airing.starts < start
        return Button { choose(station, airing) } label: {
            Focused { focused in
                VStack(alignment: .leading, spacing: 4) {
                    // A sliver at the window's edge is just a cell.
                    if right - left > 70 {
                        HStack(spacing: 8) {
                            if cut { Image(systemName: "chevron.left").font(.system(size: 18, weight: .bold)).foregroundStyle(Palette.muted) }
                            Text(airing.title).font(TextStyle.callout.font.weight(.semibold)).lineLimit(1)
                            if airing.reminded == true {
                                Image(systemName: "bell.fill").font(.system(size: 16)).foregroundStyle(Palette.primary).accessibilityLabel("Reminder set")
                            }
                        }
                        if let subtitle = airing.subtitle, right - left > 200 {
                            Text(subtitle).textStyle(.caption, color: focused ? Palette.foreground.opacity(0.8) : Palette.muted).lineLimit(1)
                        }
                    }
                }
                .foregroundStyle(Palette.foreground)
                .padding(.horizontal, 16)
                .frame(width: max(right - left - 6, 4), height: sizes.rowHeight - 12, alignment: .leading)
                .background(background(focused: focused, onNow: onNow), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(focused ? Palette.primary : onNow ? Palette.primary.opacity(0.4) : Palette.border, lineWidth: focused ? 4 : 1.5))
                .opacity(ends <= now && !focused ? 0.5 : 1)
                .shadow(color: Palette.scrim.opacity(focused ? 0.5 : 0), radius: 14, y: 6)
            }
        }
        .buttonStyle(.streamCard)
        .focused(focus, equals: airing.id)
        .padding(.leading, left + 3)
        .contextMenu {
            ForEach(actions(station, airing)) { action in
                Button(role: action.destructive ? .destructive : nil, action: action.perform) {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        }
        .accessibilityLabel("\(station.number) \(station.name): \(airing.title), \(LiveTime.clock(airing.starts, timeZone: timeZone)) to \(LiveTime.clock(ends, timeZone: timeZone))\(onNow ? ", on now" : "")")
    }

    private func background(focused: Bool, onNow: Bool) -> Color {
        if focused { return Palette.primary.opacity(0.28) }
        return onNow ? Palette.primary.opacity(0.10) : Palette.surfaceRaised
    }

    // MARK: Sliding the window

    /// At the window's edge, a press along it slides the window half an
    /// hour that way (focus stays on the program, now further in).
    private func slide(_ direction: MoveCommandDirection, in station: GuideStation) {
        guard let id = focus.wrappedValue,
              let program = LiveTime.programs(station.airings).first(where: { $0.airing.id == id }) else { return }
        switch direction {
        case .right where program.ends >= end && end < reach.upperBound:
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { start = start.addingTimeInterval(1800) }
        case .left where program.airing.starts <= start && start > reach.lowerBound:
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { start = start.addingTimeInterval(-1800) }
        default:
            break
        }
    }
}

extension GuideGrid {
    /// The half hour a moment falls in: where a window starts.
    static func halfHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 1800).rounded(.down) * 1800)
    }
}
