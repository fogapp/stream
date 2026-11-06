import SwiftUI

/// Which Stream to use: its address on the network (Settings › About shows it).
struct ServerView: View {
    @Environment(AppState.self) private var state
    @State private var address = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            RadialGradient(colors: [Palette.primary.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 1400).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 40) {
                Text("Stream").font(.system(size: 60, weight: .heavy)).foregroundStyle(Palette.primary)
                Text("Where is your Stream?").textStyle(.display)
                Text("Its address on your network, like stream.lan or 192.168.1.200:3000.").textStyle(.title2, color: Palette.muted)
                TextField("Address", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .frame(maxWidth: 1000)
                    .onSubmit { Task { await check() } }
                if let error { Text(error).textStyle(.body, color: Palette.negative) }
                Button { Task { await check() } } label: {
                    Label(checking ? "Checking…" : "Continue", systemImage: "arrow.right")
                }
                .buttonStyle(.primary)
                .disabled(checking || address.isEmpty)
            }
            .padding(Space.margin * 1.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func check() async {
        guard let url = AppState.normalize(address) else {
            error = "That doesn't look like an address."
            return
        }
        checking = true
        defer { checking = false }
        // /up answers without signing in: is this a Stream at all?
        var request = URLRequest(url: url.appendingPathComponent("up"), timeoutInterval: 10)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                error = "Something answered at \(url.host ?? address), but it isn't Stream."
                return
            }
            state.useServer(url)
        } catch {
            self.error = "Nothing answered at \(url.absoluteString)."
        }
    }
}
