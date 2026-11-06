import SwiftUI

/// The web's "…" menu on a card (components/viewing/ItemActions.tsx), as a
/// long press of the remote's select: what can be done to this item, scoped
/// to it — Mark watched on a show marks every episode, on an episode just
/// that one.
struct ItemActions: ViewModifier {
    @Environment(AppState.self) private var state
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(Toasts.self) private var toasts
    @Environment(WatchLater.self) private var watchLater
    @Environment(\.navigate) private var navigate
    @Environment(\.reload) private var reload
    let card: Card
    /// In Continue watching: it can be taken out.
    var dismissible = false
    @State private var choosingPlaylist = false

    private var name: String {
        card.kind == "episode" ? [card.show?.title, card.code].compactMap { $0 }.joined(separator: " ") : (card.title ?? "This")
    }

    private var queueable: Bool { ["movie", "episode", "video"].contains(card.kind) }

    private var watched: Bool { card.kind == "show" ? card.unwatchedCount == 0 : card.watched == true }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if card.kind != "show" {
                    Button { playback.play(kind: card.kind, id: card.id) } label: { Label("Play", systemImage: "play.fill") }
                }
                if queueable, playback.request != nil {
                    Button {
                        playback.enqueue(kind: card.kind, id: card.id)
                        toasts.show("\(name) plays next")
                    } label: { Label("Play next", systemImage: "text.line.last.and.arrowtriangle.forward") }
                }
                Button { Task { await setWatched(!watched) } } label: {
                    Label(watched ? "Mark as unwatched" : "Mark as watched", systemImage: watched ? "eye.slash" : "eye")
                }
                if queueable {
                    Button { Task { await toggleWatchLater() } } label: {
                        Label(watchLater.contains(card.id) ? "Remove from Watch later" : "Watch later",
                              systemImage: watchLater.contains(card.id) ? "clock.badge.checkmark" : "clock")
                    }
                    Button { choosingPlaylist = true } label: { Label("Add to playlist…", systemImage: "text.badge.plus") }
                }
                if dismissible {
                    Button(role: .destructive) { Task { await dismiss() } } label: {
                        Label("Remove from Continue watching", systemImage: "xmark")
                    }
                }
                if card.kind == "episode", let show = card.show, !show.id.isEmpty {
                    Button { navigate(.show(show.id)) } label: { Label("Go to show", systemImage: "tv") }
                }
                if card.kind == "video", let channel = card.channel {
                    Button { navigate(.channel(channel.id)) } label: { Label("Go to channel", systemImage: "person.crop.square") }
                }
            }
            .sheet(isPresented: $choosingPlaylist) {
                PlaylistChoices(kind: card.kind, id: card.id, name: name) { choosingPlaylist = false }
            }
    }

    private func run(_ done: String, _ work: () async throws -> Void) async {
        do {
            try await work()
            toasts.show(done)
            await reload()
        } catch {
            state.handle(error)
            toasts.show((error as? LocalizedError)?.errorDescription ?? "That didn't go through.", failed: true)
        }
    }

    private func setWatched(_ value: Bool) async {
        await run("\(name): marked \(value ? "watched" : "unwatched")") {
            if card.kind == "show" {
                let _: Empty = try await state.api.post("api/v1/shows/\(card.id)/watched", body: Watched(watched: value))
            } else {
                let _: Empty = try await state.api.post("api/v1/watch_states", body: WatchState(playableType: card.kind, playableId: card.id, watched: value))
            }
        }
    }

    private func toggleWatchLater() async {
        do {
            let saved = try await watchLater.toggle(kind: card.kind, id: card.id, api: state.api)
            toasts.show(saved ? "\(name): saved to Watch later" : "\(name): taken out of Watch later")
        } catch {
            toasts.show("That didn't go through.", failed: true)
        }
    }

    private func dismiss() async {
        await run("\(name): taken out of Continue watching") {
            let _: Empty = try await state.api.post("api/v1/watch_states/hide", body: Hide(playableType: card.kind, playableId: card.id))
        }
    }

    private struct Watched: Encodable { let watched: Bool }
    private struct WatchState: Encodable {
        let playableType: String
        let playableId: String
        let watched: Bool
    }
    private struct Hide: Encodable {
        let playableType: String
        let playableId: String
    }
}

extension View {
    func itemActions(_ card: Card, dismissible: Bool = false) -> some View {
        modifier(ItemActions(card: card, dismissible: dismissible))
    }
}

/// Which playlist to add it to.
struct PlaylistChoices: View {
    @Environment(AppState.self) private var state
    @Environment(Toasts.self) private var toasts
    let kind: String
    let id: String
    let name: String
    let done: () -> Void
    @State private var playlists: [PlaylistCard]?

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("Add \(name) to").textStyle(.title2)
            if let playlists {
                if playlists.isEmpty { Text("No playlists yet — make one on the web.").textStyle(.body, color: Palette.muted) }
                ForEach(playlists) { playlist in
                    Button {
                        Task { await add(playlist) }
                    } label: {
                        Label(playlist.title, systemImage: playlist.watchLater ? "clock" : "list.bullet.rectangle").frame(width: 700, alignment: .leading)
                    }
                    .buttonStyle(.secondary)
                }
            } else {
                LoadingState()
            }
        }
        .padding(80)
        .task { playlists = try? await state.api.get("api/v1/playlists") }
    }

    private func add(_ playlist: PlaylistCard) async {
        do {
            let _: Empty = try await state.api.post("api/v1/playlists/\(playlist.id)/items", body: Item(itemType: kind, itemId: id))
            toasts.show("\(name): added to \(playlist.title)")
        } catch {
            toasts.show("That didn't go through.", failed: true)
        }
        done()
    }

    private struct Item: Encodable {
        let itemType: String
        let itemId: String
    }
}
