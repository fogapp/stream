import SwiftUI

/// Every page a card or button can open (the web's routes), pushed onto
/// the place's navigation stack by value, so a menu or a remote command
/// can open them as well as a link.
enum Route: Hashable {
    case movie(String)
    case show(String)
    case season(show: String, number: Int)
    case person(String)
    case collection(String)
    case channel(String)
    case video(String)
    case playlist(String)
}

extension View {
    /// The pages any place can push.
    func routes() -> some View {
        navigationDestination(for: Route.self) { route in
            Group {
                switch route {
                case .movie(let id): MovieView(id: id)
                case .show(let id): ShowView(id: id)
                case .season(let show, let number): SeasonView(showId: show, number: number)
                case .person(let id): PersonView(id: id)
                case .collection(let id): CollectionView(id: id)
                case .channel(let id): ChannelView(id: id)
                case .video(let id): VideoView(id: id)
                case .playlist(let id): PlaylistView(id: id)
                }
            }
            .zoomDestination(route)
        }
    }
}

/// Opens a route on the place's stack (set by MainView).
struct Navigate {
    let action: (Route) -> Void
    func callAsFunction(_ route: Route) { action(route) }
}

private struct NavigateKey: EnvironmentKey {
    static let defaultValue = Navigate { _ in }
}

/// Asks the page on screen to load again (after a watched change, say).
struct Reload {
    let action: () async -> Void
    func callAsFunction() async { await action() }
}

private struct ReloadKey: EnvironmentKey {
    static let defaultValue = Reload {}
}

extension EnvironmentValues {
    var navigate: Navigate {
        get { self[NavigateKey.self] }
        set { self[NavigateKey.self] = newValue }
    }

    var reload: Reload {
        get { self[ReloadKey.self] }
        set { self[ReloadKey.self] = newValue }
    }
}
