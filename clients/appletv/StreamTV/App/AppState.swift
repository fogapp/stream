import Foundation
import Observation
import UIKit

/// Where this Apple TV is in signing in, and the API client that goes with
/// it: which server, the session a phone approved, the profile chosen.
@MainActor
@Observable
final class AppState {
    enum Stage: Equatable {
        case needsServer
        case pairing
        case choosingProfile
        case ready
    }

    private(set) var server: URL?
    private(set) var sessionToken: String?
    private(set) var profileToken: String?
    private(set) var profile: Profile?
    /// A stream:// link to follow once a profile is watching (the Top Shelf's).
    var pendingLink: StreamLink?
    let deviceKey: String

    private let defaults: UserDefaults

    /// Made-up titles from the app bundle, no server (Showcase.swift):
    /// `-StreamShowcase YES` on launch, as the UI tests do.
    let showcase: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showcase = defaults.bool(forKey: "StreamShowcase")
        let showcaseStage = defaults.string(forKey: "StreamShowcaseStage")
        server = showcase ? (showcaseStage == "server" ? nil : Showcase.server) : defaults.string(forKey: "server").flatMap(URL.init(string:))
        sessionToken = showcase ? (showcaseStage == "pairing" ? nil : "showcase") : Keychain.read("session")
        profileToken = showcase ? "showcase" : Keychain.read("profile")
        if let existing = defaults.string(forKey: "deviceKey") {
            deviceKey = existing
        } else {
            let minted = "appletv-" + UUID().uuidString.lowercased()
            defaults.set(minted, forKey: "deviceKey")
            deviceKey = minted
        }
    }

    var stage: Stage {
        if server == nil { return .needsServer }
        if sessionToken == nil { return .pairing }
        if profile == nil { return .choosingProfile }
        return .ready
    }

    var api: StreamAPI {
        StreamAPI(server: server ?? URL(string: "http://localhost")!, sessionToken: sessionToken, profileToken: profileToken, deviceKey: deviceKey,
                  showcase: showcase)
    }

    /// "stream.lan", "192.168.1.200:3000" or a full URL: http unless it says otherwise.
    static func normalize(_ typed: String) -> URL? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return URL(string: withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    func useServer(_ url: URL) {
        server = url
        defaults.set(url.absoluteString, forKey: "server")
    }

    func signedIn(token: String) {
        sessionToken = token
        Keychain.write("session", token)
    }

    func chose(_ selection: ProfileSelection) {
        profileToken = selection.token
        profile = selection.profile
        Keychain.write("profile", selection.token)
    }

    /// The profile the server says this device watches as, when no picker is needed.
    func adopt(current: CurrentProfile) {
        profile = current.profile
    }

    /// "Who's watching?" again.
    func switchProfile() {
        profile = nil
        profileToken = nil
        Keychain.write("profile", nil)
    }

    func signOut() {
        switchProfile()
        sessionToken = nil
        Keychain.write("session", nil)
    }

    func forgetServer() {
        signOut()
        server = nil
        defaults.removeObject(forKey: "server")
    }

    /// Stream signed this device out (a revoked session): start again.
    func handle(_ error: Error) {
        if let error = error as? APIError, error.status == 401 { signOut() }
    }

    /// What the household calls this Apple TV ("Living Room"), for playing to it.
    var screenName: String { UIDevice.current.name }
}
