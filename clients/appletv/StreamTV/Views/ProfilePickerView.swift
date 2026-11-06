import SwiftUI

/// "Who's watching?" (PROPOSAL §7.4), with a PIN pad for a profile that has one.
struct ProfilePickerView: View {
    @Environment(AppState.self) private var state
    @State private var profiles: [Profile] = []
    @State private var locked: Profile?
    @State private var pin = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            if let locked {
                pinPad(locked)
            } else {
                VStack(spacing: 80) {
                    Text("Who's watching?").textStyle(.display)
                    HStack(spacing: 70) {
                        ForEach(profiles) { profile in
                            Button {
                                if profile.hasPin { locked = profile } else { Task { await choose(profile) } }
                            } label: {
                                Focused { focused in
                                    VStack(spacing: 26) {
                                        ProfileAvatar(profile: profile, size: 230)
                                            .overlay(RoundedRectangle(cornerRadius: 230 * 0.22, style: .continuous)
                                                .strokeBorder(focused ? Palette.primary : .clear, lineWidth: 6).padding(-10))
                                            .focusGrow(focused, 1.08)
                                            .shadow(color: Palette.scrim.opacity(focused ? 0.6 : 0), radius: 30, y: 16)
                                        HStack(spacing: 12) {
                                            Text(profile.name).textStyle(.title2, color: focused ? Palette.foreground : Palette.muted)
                                            if profile.hasPin { Image(systemName: "lock.fill").foregroundStyle(Palette.muted).accessibilityLabel("PIN") }
                                        }
                                    }
                                    .focusMotion(focused)
                                }
                            }
                            .buttonStyle(.streamCard)
                            .accessibilityLabel(profile.name)
                        }
                    }
                    if let error { Text(error).textStyle(.body, color: Palette.negative) }
                }
            }
        }
        .task { await load() }
    }

    /// The web's PIN pad: dots for the digits typed, a keypad, OK.
    private func pinPad(_ profile: Profile) -> some View {
        VStack(spacing: 40) {
            ProfileAvatar(profile: profile, size: 160)
            Text("Enter \(profile.name)'s PIN").textStyle(.title2)
            HStack(spacing: 20) {
                ForEach(0..<max(4, pin.count), id: \.self) { index in
                    Circle().fill(index < pin.count ? Palette.foreground : Palette.foreground.opacity(0.25)).frame(width: 22, height: 22)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(pin.count) digits entered")
            VStack(spacing: 18) {
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                    HStack(spacing: 18) { ForEach(row, id: \.self) { digit in key(digit) } }
                }
                HStack(spacing: 18) {
                    Button {
                        locked = nil
                        pin = ""
                    } label: { Text("Back").frame(width: 84) }
                    .buttonStyle(.ghost)
                    key("0")
                    Button { pin = String(pin.dropLast()) } label: { Image(systemName: "delete.left").frame(width: 84) }
                        .buttonStyle(.secondary)
                        .accessibilityLabel("Delete a digit")
                }
            }
            Button { Task { await choose(profile) } } label: { Text(busy ? "Checking…" : "OK").frame(width: 320) }
                .buttonStyle(.primary)
                .disabled(pin.count < 4 || busy)
            if let error { Text(error).textStyle(.body, color: Palette.negative) }
        }
    }

    private func key(_ digit: String) -> some View {
        Button { pin = String((pin + digit).prefix(8)) } label: {
            Text(digit).font(.system(size: 36, weight: .semibold)).monospacedDigit().frame(width: 84)
        }
        .buttonStyle(.secondary)
    }

    private func load() async {
        do {
            let current: CurrentProfile = try await state.api.get("api/v1/profiles/current")
            if !current.needsPicker {
                state.adopt(current: current)
                return
            }
            profiles = try await state.api.get("api/v1/profiles")
        } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }

    private func choose(_ profile: Profile) async {
        busy = true
        defer { busy = false }
        do {
            let selection: ProfileSelection = try await state.api.post("api/v1/profiles/\(profile.id)/select", body: PinBody(pin: pin))
            state.chose(selection)
        } catch {
            self.error = error.localizedDescription
            pin = ""
        }
    }
}

private struct PinBody: Encodable {
    let pin: String
}
