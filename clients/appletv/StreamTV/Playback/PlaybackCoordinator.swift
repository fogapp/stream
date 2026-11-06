import AVFoundation
import Observation

/// What's asked to play (from a card, a button, or another screen), and the
/// player playing it, so a remote command can reach it.
@MainActor
@Observable
final class PlaybackCoordinator {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let kind: String
        let playableId: String
        /// 0 starts over; nil resumes where the profile left off.
        let start: Double?
        /// A picture subtitle to burn in, by stream index.
        var burnSubtitle: Int? = nil
        /// An audio stream other than the one Stream would choose.
        var audioIndex: Int? = nil
        /// Playing through a playlist: Up next is its next item.
        var playlistId: String? = nil
        /// Started by playing on from the one before, not by someone choosing it.
        var automatic = false
    }

    /// Episodes played on in a row without anyone touching the remote.
    private(set) var runOfAutomatic = 0

    /// "Still watching?" is up: the next one waits for an answer.
    var askingStillWatching: Request?

    var request: Request?

    /// Play next (the web's queue): what plays after this, ahead of Up next.
    private(set) var queue: [Request] = []

    func enqueue(kind: String, id: String) {
        queue.removeAll { $0.playableId == id }
        queue.append(Request(kind: kind, playableId: id, start: nil))
    }

    /// Something finished: what was queued, else what the session offered.
    /// True when something plays next.
    @discardableResult
    func advance(kind: String?, id: String?, playlistId: String?, limit: Int) -> Bool {
        if !queue.isEmpty {
            request = queue.removeFirst()
            return true
        }
        guard let kind, let id else { return false }
        playOn(kind: kind, id: id, playlistId: playlistId, limit: limit)
        return true
    }

    /// A Grid channel on screen, by number (PROPOSAL §7.7).
    struct LiveRequest: Identifiable, Equatable {
        let id = UUID()
        let number: String
    }

    var live: LiveRequest?

    func watchLive(number: String) {
        request = nil
        live = LiveRequest(number: number)
    }

    func stopLive() {
        live = nil
    }

    /// A camera or web stream on screen (PROPOSAL §7.8).
    struct StreamRequest: Identifiable, Equatable {
        let id = UUID()
        let streamId: String
        let name: String
    }

    var stream: StreamRequest?

    func watchStream(id: String, name: String) {
        request = nil
        live = nil
        stream = StreamRequest(streamId: id, name: name)
    }

    func stopStream() {
        stream = nil
    }
    /// The player on screen, while there is one.
    var player: AVPlayer?

    func play(kind: String, id: String, fromStart: Bool = false, playlistId: String? = nil) {
        runOfAutomatic = 0
        request = Request(kind: kind, playableId: id, start: fromStart ? 0 : nil, playlistId: playlistId)
    }

    func play(kind: String, id: String, start: Double?) {
        runOfAutomatic = 0
        request = Request(kind: kind, playableId: id, start: start)
    }

    /// Playing on to what's next; after `limit` in a row, asks first.
    func playOn(kind: String, id: String, playlistId: String?, limit: Int) {
        let next = Request(kind: kind, playableId: id, start: nil, playlistId: playlistId, automatic: true)
        if limit > 0 && runOfAutomatic + 1 >= limit {
            request = nil
            askingStillWatching = next
            return
        }
        runOfAutomatic += 1
        request = next
    }

    /// "Still watching?" answered yes: carry on, counting afresh.
    func keepWatching() {
        guard let next = askingStillWatching else { return }
        askingStillWatching = nil
        runOfAutomatic = 0
        request = next
    }

    /// The same title again from here, with a picture subtitle burned in
    /// (or not), or another audio track.
    func restart(burning streamIndex: Int?, audio: Int? = nil, at position: Double) {
        guard let current = request else { return }
        request = Request(kind: current.kind, playableId: current.playableId, start: position, burnSubtitle: streamIndex,
                          audioIndex: audio, playlistId: current.playlistId, automatic: current.automatic)
    }

    /// Someone touched the remote: the run of episodes played on starts over.
    func touched() {
        runOfAutomatic = 0
    }

    func stop() {
        request = nil
    }
}
