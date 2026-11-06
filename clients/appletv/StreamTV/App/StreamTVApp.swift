import SwiftUI

/// Stream on the Apple TV (PROPOSAL §11 Phase 6): the same household, the
/// same decision engine, AVPlayer instead of a browser.
@main
struct StreamTVApp: App {
    @State private var state = AppState()
    @State private var playback = PlaybackCoordinator()
    @State private var toasts = Toasts()
    @State private var watchLater = WatchLater()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .environment(playback)
                .environment(toasts)
                .environment(watchLater)
                .onOpenURL { state.pendingLink = StreamLink($0) }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if UserDefaults.standard.bool(forKey: "StreamGallery") {
            DesignGallery()
        } else {
            stages
        }
    }

    @ViewBuilder private var stages: some View {
        switch state.stage {
        case .needsServer: ServerView()
        case .pairing: PairView()
        case .choosingProfile: ProfilePickerView()
        case .ready: MainView()
        }
    }
}
