import SwiftUI

/// This profile's playlists, Watch later first (PROPOSAL §7.4): each opens
/// to play all or pick from it.
struct PlaylistsView: View {
    @Environment(AppState.self) private var state
    @State private var playlists: [PlaylistCard]?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text("Playlists").textStyle(.title)
                if let playlists {
                    if playlists.isEmpty { EmptyState(title: "No playlists yet", detail: "Make them on the web, or add to one from a card's menu.") }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(460), spacing: Space.cardGap), count: 3), alignment: .leading, spacing: 50) {
                        ForEach(playlists) { playlist in
                            RouteLink(Route.playlist(playlist.id)) {
                                Focused { focused in tile(playlist, focused: focused) }
                            }
                            .buttonStyle(.streamCard)
                            .accessibilityLabel("\(playlist.title), \(playlist.itemCount) items")
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
        .task { await load() }
    }

    private func tile(_ playlist: PlaylistCard, focused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: playlist.watchLater ? "clock.fill" : "list.bullet.rectangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(focused ? Palette.primaryForeground : Palette.primary)
            Spacer()
            Text(playlist.title).textStyle(.title2, color: focused ? Palette.primaryForeground : Palette.foreground).lineLimit(1)
            Text("\(playlist.itemCount) items").textStyle(.callout, color: focused ? Palette.primaryForeground.opacity(0.8) : Palette.muted)
        }
        .padding(36)
        .frame(width: 460, height: 260, alignment: .leading)
        .background(focused ? Palette.primaryHover : Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .focusLift(focused)
    }

    private func load() async {
        do {
            playlists = try await state.api.get("api/v1/playlists")
            error = nil
        } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }
}
