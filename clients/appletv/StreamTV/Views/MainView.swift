import SwiftUI

/// Signed in, as a profile (PROPOSAL §7): the sidebar down the left, the
/// chosen place filling the rest, the players over the top, and an ear open
/// for "play this in the living room". Menu at the top of a place moves to
/// the sidebar; Menu there leaves the app, as every tvOS app does.
struct MainView: View {
    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(Toasts.self) private var toasts
    @Environment(WatchLater.self) private var watchLater
    @State private var selection: Destination = .home
    @State private var path = NavigationPath()
    @State private var libraries: [Library] = []
    /// The household has an MLB.tv account (PROPOSAL §7.8).
    @State private var baseball = false
    @FocusState private var sidebarFocus: Destination?
    /// The sidebar holds back while focus settles in the place — at launch
    /// and after choosing somewhere — so focus lands in the content, not
    /// on the sidebar's first item.
    @State private var sidebarReady = false
    /// Pages zoom out of the cards that open them.
    @Namespace private var zoom

    private var items: [Destination] {
        [.home, .live] + (baseball ? [.baseball] : []) + [.search] + libraries.map { .library($0) } + [.collections, .playlists]
    }

    /// Search takes the whole width, as the system keyboard is laid out
    /// for it; the rail comes back as soon as focus goes to it.
    private var fullBleed: Bool { selection == .search }

    var body: some View {
        @Bindable var playback = playback
        ZStack(alignment: .leading) {
            NavigationStack(path: $path) {
                content(selection)
                    // Only at the top of the place: deeper, Menu goes back.
                    .onExitCommand(perform: path.isEmpty ? { sidebarFocus = selection } : nil)
                    .routes()
            }
            .environment(\.navigate, Navigate { path.append($0) })
            .environment(\.zoomNamespace, zoom)
            .id(selection)
            .padding(.leading, fullBleed ? 0 : Sidebar.collapsed)
            // The rail is the left margin: pages start right after it, not
            // after tvOS's 80pt safe area as well. Search keeps the safe
            // area, which the system keyboard is laid out for.
            .ignoresSafeArea(fullBleed ? [] : .container, edges: .leading)
            .focusSection()

            Sidebar(items: items, selection: selection, profile: state.profile, focus: $sidebarFocus,
                    choose: { destination in
                        selection = destination
                        path = NavigationPath()
                        settle()
                    },
                    switchProfile: { state.switchProfile() })
                .disabled(!sidebarReady)
                .ignoresSafeArea(.container, edges: .leading)
                .opacity(fullBleed && sidebarFocus == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: sidebarFocus == nil)
                .focusSection()

            ToastOverlay(toasts: toasts)
        }
        .background(Palette.background.ignoresSafeArea())
        .fullScreenCover(item: $playback.request) { request in
            PlayerView(request: request)
        }
        .fullScreenCover(item: $playback.live) { live in
            LivePlayerView(startNumber: live.number)
        }
        .fullScreenCover(item: $playback.stream) { stream in
            StreamPlayerView(request: stream)
        }
        .alert("Still watching?", isPresented: Binding(get: { playback.askingStillWatching != nil },
                                                      set: { if !$0 { playback.askingStillWatching = nil } })) {
            Button("Keep watching") { playback.keepWatching() }
            Button("Stop", role: .cancel) { playback.askingStillWatching = nil }
        } message: {
            Text("A few in a row now. Carry on?")
        }
        .task(id: state.profile?.id) { await RemoteListener(state: state, playback: playback).run() }
        .task { await loadLibraries() }
        .task(id: state.profile?.id) { await loadBaseball() }
        .task(id: state.profile?.id) { await watchLater.load(state.api) }
        .onAppear {
            settle()
            follow()
        }
        .onChange(of: state.pendingLink) { follow() }
    }

    /// A stream:// link (the Top Shelf's): a page on Home's stack, the
    /// player, or a Grid channel.
    private func follow() {
        guard let link = state.pendingLink else { return }
        state.pendingLink = nil
        switch link {
        case .play(let kind, let id):
            playback.play(kind: kind, id: id)
        case .live(let number):
            playback.watchLive(number: number)
        case .page(let kind, let id):
            guard let route = Route(kind: kind, id: id) else { return }
            selection = .home
            path = NavigationPath()
            path.append(route)
        }
    }

    /// Let focus go to the content, then open the sidebar to it again.
    private func settle() {
        sidebarReady = false
        sidebarFocus = nil
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            sidebarReady = true
        }
    }

    @ViewBuilder private func content(_ destination: Destination) -> some View {
        switch destination {
        case .home: HomeView()
        case .live: LiveGuideView()
        case .baseball: BaseballView()
        case .search: SearchView()
        case .library(let library): LibraryView(library: library)
        case .collections: CollectionsView()
        case .playlists: PlaylistsView()
        case .settings: SettingsView()
        }
    }

    /// Whether Baseball is in the sidebar; a failed answer leaves it out.
    private func loadBaseball() async {
        let answer: BaseballAvailability? = try? await state.api.get("api/v1/baseball")
        baseball = answer?.available ?? false
    }

    private func loadLibraries() async {
        do {
            libraries = try await state.api.get("api/v1/libraries")
        } catch {
            state.handle(error)
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.rowGap) {
                Text("Settings").textStyle(.title)
                section("Watching as") {
                    HStack(spacing: 24) {
                        if let profile = state.profile { ProfileAvatar(profile: profile, size: 72) }
                        Text(state.profile?.name ?? "—").textStyle(.title2)
                        Spacer()
                        Button("Switch profile") { state.switchProfile() }.buttonStyle(.secondary)
                    }
                }
                section("This Apple TV") {
                    Text("Other screens and assistants can play things here as “\(state.screenName)”.").textStyle(.body, color: Palette.muted)
                }
                section("Server") {
                    Text(state.server?.absoluteString ?? "—").textStyle(.body, color: Palette.muted)
                    HStack(spacing: 30) {
                        Button("Sign out") { state.signOut() }.buttonStyle(.secondary)
                        Button("Use a different server") { state.forgetServer() }.buttonStyle(.ghost)
                    }
                }
            }
            .frame(maxWidth: 1300, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.margin)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).textStyle(.eyebrow, color: Palette.primary)
            content()
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.border, lineWidth: 1.5))
    }
}
