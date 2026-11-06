import SwiftUI

/// The web's Badge tones.
enum BadgeTone { case neutral, info, success, warning, danger }

struct Badge: View {
    let text: String
    var tone: BadgeTone = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(TextStyle.caption.font.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 1.5))
    }

    private var color: Color {
        switch tone {
        case .neutral: return Palette.muted
        case .info: return Palette.primary
        case .success: return Palette.positive
        case .warning: return Palette.warning
        case .danger: return Palette.negative
        }
    }
}

/// How far in: a cyan bar on a faint track.
struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.foreground.opacity(0.22))
                Rectangle().fill(Palette.primary).frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(Int((value * 100).rounded())) percent watched")
    }
}

/// A row's heading.
struct SectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).textStyle(.title2)
            if let detail { Text(detail).textStyle(.callout, color: Palette.muted) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A round number or tick over a card's corner (unwatched episodes, watched).
struct CornerMark: View {
    enum Kind { case count(Int), watched }
    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .count(let count):
                Text("\(count)").font(TextStyle.caption.font.weight(.bold)).monospacedDigit()
                    .padding(.horizontal, 12).frame(minWidth: 40, minHeight: 40)
            case .watched:
                Image(systemName: "checkmark").font(.system(size: 18, weight: .heavy)).frame(width: 40, height: 40)
            }
        }
        .foregroundStyle(Palette.primaryForeground)
        .background(Palette.primary, in: Capsule())
        .accessibilityLabel({
            switch kind {
            case .count(let count): return "\(count) unwatched"
            case .watched: return "Watched"
            }
        }())
    }
}

/// Tabs along a line (seasons, filters): the chosen one bright and
/// underlined in cyan, focus lifting it.
/// Tabs that switch as focus lands on them, the way the TV app's do: a
/// click would be one press more than the web's hover-free click needs.
struct PillTabs<Key: Hashable>: View {
    let tabs: [(key: Key, label: String)]
    @Binding var selection: Key
    @FocusState private var focusedTab: Key?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(tabs, id: \.key) { tab in
                    Button { selection = tab.key } label: {
                        Focused { focused in
                            VStack(spacing: 10) {
                                Text(tab.label)
                                    .font(TextStyle.headline.font)
                                    .foregroundStyle(focused ? Palette.primaryForeground : selection == tab.key ? Palette.foreground : Palette.muted)
                                    .padding(.horizontal, 28)
                                    .frame(height: 64)
                                    .background(focused ? Palette.primaryHover : .clear, in: Capsule())
                                Rectangle().fill(selection == tab.key ? Palette.primary : .clear).frame(height: 4)
                                    .padding(.horizontal, 28)
                            }
                            .focusGrow(focused, 1.06)
                            .focusMotion(focused)
                        }
                    }
                    .buttonStyle(.streamCard)
                    .focused($focusedTab, equals: tab.key)
                    .accessibilityAddTraits(selection == tab.key ? .isSelected : [])
                }
            }
            .padding(.vertical, 16)
        }
        .scrollClipDisabled()
        .focusSection()
        .defaultFocus($focusedTab, selection)
        .onChange(of: focusedTab) { _, key in
            if let key { selection = key }
        }
    }
}

/// One of a few choices, chosen with a click (sort orders): the web's
/// Segmented, a capsule track with the chosen one raised in it.
struct Segmented<Key: Hashable>: View {
    let options: [(key: Key, label: String)]
    @Binding var selection: Key

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.key) { option in
                Button { selection = option.key } label: {
                    Focused { focused in
                        Text(option.label)
                            .font(TextStyle.callout.font.weight(.semibold))
                            .foregroundStyle(focused ? Palette.primaryForeground : selection == option.key ? Palette.foreground : Palette.muted)
                            .padding(.horizontal, 26)
                            .frame(height: 56)
                            .background(focused ? Palette.primaryHover : selection == option.key ? Palette.surfaceRaised : .clear, in: Capsule())
                            .focusGrow(focused, 1.06)
                            .focusMotion(focused)
                    }
                }
                .buttonStyle(.streamCard)
                .accessibilityAddTraits(selection == option.key ? .isSelected : [])
            }
        }
        .padding(6)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1.5))
        .focusSection()
    }
}

/// A chip that's on or off (filters).
struct Chip: View {
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Focused { focused in
                HStack(spacing: 10) {
                    if on { Image(systemName: "checkmark") }
                    Text(label)
                }
                .font(TextStyle.callout.font.weight(.semibold))
                .foregroundStyle(focused ? Palette.primaryForeground : on ? Palette.primaryForeground : Palette.foreground)
                .padding(.horizontal, 26)
                .frame(height: 56)
                .background(focused ? Palette.primaryHover : on ? Palette.primary : Palette.surfaceRaised, in: Capsule())
                .focusGrow(focused, 1.06)
                .focusMotion(focused)
            }
        }
        .buttonStyle(.streamCard)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
