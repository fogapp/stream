import SwiftUI

/// Where the sidebar goes (the web's AppShell navigation).
enum Destination: Hashable {
    case home, live, baseball, search, library(Library), collections, playlists, settings

    var title: String {
        switch self {
        case .home: return "Home"
        case .live: return "Grid"
        case .baseball: return "Baseball"
        case .search: return "Search"
        case .library(let library): return library.name
        case .collections: return "Collections"
        case .playlists: return "Playlists"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .live: return "dot.radiowaves.left.and.right"
        case .baseball: return "baseball"
        case .search: return "magnifyingglass"
        case .library(let library): return library.systemImage
        case .collections: return "square.stack"
        case .playlists: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

/// The desktop web's sidebar, for a remote (PROPOSAL §7 on the TV): the
/// wordmark, Home, Grid, Baseball (with an MLB.tv account), Search, each library, Collections, Playlists;
/// the profile and Settings at the foot. Narrow — icons only — while you
/// watch; wide, with names, when focus comes into it.
struct Sidebar: View {
    let items: [Destination]
    let selection: Destination
    let profile: Profile?
    let focus: FocusState<Destination?>.Binding
    let choose: (Destination) -> Void
    let switchProfile: () -> Void

    static let collapsed: CGFloat = 132
    static let expanded: CGFloat = 430

    private var open: Bool { focus.wrappedValue != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Text(open ? "Stream" : "S").font(.system(size: 44, weight: .heavy)).foregroundStyle(Palette.primary)
                    .accessibilityLabel("Stream")
            }
            .frame(height: 90)
            .padding(.leading, 34)
            ForEach(items, id: \.self) { item in row(item) }
            Spacer()
            if let profile {
                Button(action: switchProfile) {
                    Focused { focused in
                        HStack(spacing: 20) {
                            ProfileAvatar(profile: profile, size: 56)
                            if open {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).textStyle(.headline, color: focused ? Palette.primaryForeground : Palette.foreground)
                                    Text("Switch profile").textStyle(.caption, color: focused ? Palette.primaryForeground.opacity(0.8) : Palette.muted)
                                }
                            }
                        }
                        .padding(.horizontal, 22)
                        .frame(height: 84)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(focused ? Palette.primaryHover : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                }
                .buttonStyle(.streamCard)
                .accessibilityLabel("\(profile.name), switch profile")
            }
            row(.settings)
        }
        .padding(.vertical, 40)
        .padding(.horizontal, 16)
        .frame(width: open ? Self.expanded : Self.collapsed, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            Rectangle().fill(Palette.surface.opacity(open ? 0.98 : 0.72))
                .overlay(alignment: .trailing) { Rectangle().fill(Palette.border).frame(width: 1.5) }
                .shadow(color: Palette.scrim.opacity(open ? 0.6 : 0), radius: 40, x: 20)
                .ignoresSafeArea()
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: open)
    }

    private func row(_ item: Destination) -> some View {
        Button { choose(item) } label: {
            Focused { focused in
                HStack(spacing: 24) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 30, weight: .semibold))
                        .frame(width: 44)
                        .foregroundStyle(focused ? Palette.primaryForeground : selection == item ? Palette.primary : Palette.muted)
                    if open {
                        Text(item.title).textStyle(.headline, color: focused ? Palette.primaryForeground : selection == item ? Palette.foreground : Palette.muted)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 28)
                .frame(height: 76)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(focused ? Palette.primaryHover : selection == item ? Palette.surfaceRaised : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .focusGrow(focused, 1.03)
            }
        }
        .buttonStyle(.streamCard)
        .focused(focus, equals: item)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selection == item ? .isSelected : [])
    }
}
