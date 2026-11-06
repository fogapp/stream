import CoreImage.CIFilterBuiltins
import SwiftUI

/// Signing in without typing a password on the TV (PROPOSAL §7.4): show a
/// code, someone enters it on their phone, and this device's session comes
/// back on the next poll. The QR code opens /pair with the code filled in.
struct PairView: View {
    @Environment(AppState.self) private var state
    @State private var pairing: Pairing?
    @State private var error: String?

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            RadialGradient(colors: [Palette.primary.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 1400).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 56) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Stream").font(.system(size: 60, weight: .heavy)).foregroundStyle(Palette.primary)
                    Text("Sign in this Apple TV").textStyle(.display)
                }
                if let pairing {
                    HStack(alignment: .center, spacing: 120) {
                        VStack(alignment: .leading, spacing: 28) {
                            step(1, "On your phone or computer, open")
                            Text(pairURL).font(.system(size: 36, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.foreground)
                                .padding(.leading, 76)
                            step(2, "and enter this code")
                            Text(pairing.code)
                                .font(.system(size: 120, weight: .bold, design: .monospaced))
                                .foregroundStyle(Palette.primary)
                                .tracking(8)
                                .padding(.leading, 76)
                                .accessibilityLabel("Code \(pairing.code)")
                        }
                        if let qr = QRCode.image(for: codeURL(pairing)) {
                            VStack(spacing: 24) {
                                Image(decorative: qr, scale: 1)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 340, height: 340)
                                    .padding(28)
                                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                                Text("Or scan with your phone").textStyle(.callout, color: Palette.muted)
                            }
                        }
                    }
                } else if error == nil {
                    LoadingState(label: "Asking Stream for a code…")
                }
                if let error {
                    Text(error).textStyle(.body, color: Palette.negative)
                    Button { Task { await start() } } label: { Label("Try again", systemImage: "arrow.clockwise") }.buttonStyle(.secondary)
                }
                Button("Use a different server") { state.forgetServer() }.buttonStyle(.ghost)
            }
            .padding(Space.margin * 1.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .task { await start() }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 24) {
            Text("\(number)").font(.system(size: 28, weight: .bold)).foregroundStyle(Palette.primaryForeground)
                .frame(width: 52, height: 52).background(Palette.primary, in: Circle())
            Text(text).textStyle(.title2, color: Palette.muted)
        }
    }

    private var pairURL: String {
        (state.server?.absoluteString ?? "") + "/pair"
    }

    private func codeURL(_ pairing: Pairing) -> String {
        var components = URLComponents(string: pairURL)
        components?.queryItems = [URLQueryItem(name: "code", value: pairing.code)]
        return components?.string ?? pairURL
    }

    private func start() async {
        error = nil
        do {
            let started: Pairing = try await state.api.post("api/v1/pairings", body: DeviceLabel(deviceLabel: "Apple TV (\(state.screenName))"))
            pairing = started
            await poll(started)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func poll(_ pairing: Pairing) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            do {
                let result: PairingPoll = try await state.api.get("api/v1/pairings/\(pairing.pollToken)")
                if result.state == "approved", let token = result.token {
                    state.signedIn(token: token)
                    return
                }
            } catch {
                self.error = error.localizedDescription
                self.pairing = nil
                return
            }
        }
    }
}

/// A QR code drawn on the device: black modules on transparent, one pixel
/// per module, scaled up without smoothing by the view.
enum QRCode {
    static func image(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

private struct DeviceLabel: Encodable {
    let deviceLabel: String
}
