import SwiftUI

/// The web's buttons (components/ui/Button.tsx) for a remote: primary is the
/// cyan pill, secondary a raised surface, ghost only text. Focused, any of
/// them becomes the bright cyan one, a little larger — what's focused is
/// never in doubt from the sofa.
struct StreamButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    let kind: Kind
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, kind: kind, compact: compact)
    }

    private struct Label: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(compact ? TextStyle.callout.font.weight(.semibold) : TextStyle.headline.font)
                .labelStyle(StreamLabelStyle())
                .foregroundStyle(foreground)
                .padding(.horizontal, compact ? 24 : 36)
                .frame(height: compact ? 58 : 72)
                .background(background, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(kind == .secondary && !focused ? Palette.border : .clear, lineWidth: 1.5)
                )
                .scaleEffect(focused && !reduceMotion ? 1.08 : 1)
                .shadow(color: Palette.scrim.opacity(focused ? 0.5 : 0), radius: 18, y: 10)
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72), value: focused)
        }

        private var foreground: Color {
            if focused { return Palette.primaryForeground }
            switch kind {
            case .primary: return Palette.primaryForeground
            case .secondary: return Palette.foreground
            case .ghost: return Palette.muted
            }
        }

        private var background: Color {
            if focused { return Palette.primaryHover }
            switch kind {
            case .primary: return Palette.primary
            case .secondary: return Palette.surfaceRaised
            case .ghost: return .clear
            }
        }
    }
}

/// Icon and title with the web's spacing.
struct StreamLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon
            configuration.title
        }
    }
}

extension ButtonStyle where Self == StreamButtonStyle {
    static var primary: StreamButtonStyle { StreamButtonStyle(kind: .primary) }
    static var secondary: StreamButtonStyle { StreamButtonStyle(kind: .secondary) }
    static var ghost: StreamButtonStyle { StreamButtonStyle(kind: .ghost) }
    static func stream(_ kind: StreamButtonStyle.Kind, compact: Bool = false) -> StreamButtonStyle {
        StreamButtonStyle(kind: kind, compact: compact)
    }
}

/// A round icon-only button (the web's IconButton): its label is required,
/// so VoiceOver always has a name for it.
struct IconButton: View {
    let label: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Focused { focused in
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(focused ? Palette.primaryForeground : Palette.foreground)
                    .frame(width: 76, height: 76)
                    .background(focused ? Palette.primaryHover : Palette.surfaceRaised.opacity(0.9), in: Circle())
                    .focusGrow(focused, 1.1)
                    .focusMotion(focused)
            }
        }
        .buttonStyle(.streamCard)
        .accessibilityLabel(label)
    }
}
