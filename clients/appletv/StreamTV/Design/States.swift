import SwiftUI

/// The web's LoadingState / ErrorState / EmptyState: a failed load never
/// looks like an empty screen.
struct LoadingState: View {
    var label = "Loading…"

    var body: some View {
        VStack(spacing: 24) {
            ProgressView().tint(Palette.primary).scaleEffect(1.4)
            Text(label).textStyle(.callout, color: Palette.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

struct ErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 54)).foregroundStyle(Palette.warning)
            Text(message).textStyle(.body, color: Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 900)
            Button(action: retry) { Label("Try again", systemImage: "arrow.clockwise") }.buttonStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

struct EmptyState: View {
    let title: String
    var detail: String?
    var systemImage = "sparkles.tv"

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage).font(.system(size: 60)).foregroundStyle(Palette.muted)
            Text(title).textStyle(.title2)
            if let detail { Text(detail).textStyle(.body, color: Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 1000) }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

/// A placeholder that shimmers while a row loads.
struct Shimmer: View {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat = Radius.card
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Palette.surfaceRaised)
            .overlay(
                LinearGradient(colors: [.clear, Palette.foreground.opacity(0.06), .clear], startPoint: .leading, endPoint: .trailing)
                    .offset(x: phase * width)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            )
            .frame(width: width, height: height)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
            }
            .accessibilityHidden(true)
    }
}
