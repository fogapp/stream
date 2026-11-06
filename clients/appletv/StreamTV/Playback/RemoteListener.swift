import AVFoundation
import Foundation

/// Being played to (PROPOSAL §11 Phase 6): this Apple TV names itself after
/// what the household called it ("Living Room") and asks every couple of
/// seconds whether another screen, or an assistant over MCP, wants it to
/// play, pause, seek or stop something.
@MainActor
struct RemoteListener {
    let state: AppState
    let playback: PlaybackCoordinator

    func run() async {
        do {
            let _: RemoteDevice = try await state.api.patch("api/v1/remote/this_device", body: ThisDevice(label: state.screenName, remoteControl: true))
        } catch {
            state.handle(error)
        }
        var handled = Set<String>()
        while !Task.isCancelled {
            if let commands: [RemoteCommand] = try? await state.api.get("api/v1/remote/commands") {
                for command in commands where !handled.contains(command.id) {
                    handled.insert(command.id)
                    await perform(command)
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func perform(_ command: RemoteCommand) async {
        let player = playback.player
        switch command.kind {
        case "play":
            guard let kind = command.payload.kind, let id = command.payload.id else { return }
            // Sent as someone else: watch as them (the server only sends a
            // PIN profile's token when an admin asked).
            if let token = command.payload.profileToken, command.payload.profileId != state.profile?.id {
                var api = state.api
                api.profileToken = token
                if let current: CurrentProfile = try? await api.get("api/v1/profiles/current") {
                    state.chose(ProfileSelection(token: token, profile: current.profile))
                }
            }
            // A camera or web stream (PROPOSAL §7.8) has its own player.
            if kind == "live_stream" {
                playback.watchStream(id: id, name: command.payload.title ?? "Live")
            } else {
                playback.play(kind: kind, id: id, start: command.payload.start)
            }
        case "tune":
            guard let number = command.payload.number else { return }
            if let token = command.payload.profileToken, command.payload.profileId != state.profile?.id {
                var api = state.api
                api.profileToken = token
                if let current: CurrentProfile = try? await api.get("api/v1/profiles/current") {
                    state.chose(ProfileSelection(token: token, profile: current.profile))
                }
            }
            playback.watchLive(number: number)
        case "pause":
            player?.pause()
        case "resume":
            player?.play()
        case "seek":
            guard let player else { return }
            let target = command.payload.seconds ?? (player.currentTime().seconds + (command.payload.by ?? 0))
            await player.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600))
        case "stop":
            playback.stop()
        default:
            break
        }
    }
}

private struct ThisDevice: Encodable {
    let label: String
    let remoteControl: Bool
}
