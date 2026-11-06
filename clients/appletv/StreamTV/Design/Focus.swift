import SwiftUI

/// How a focused thing looks (PROPOSAL §7.4 on the TV): tvOS's lift — a
/// little larger, a soft shadow — and the web's cyan ring. Reduce Motion
/// keeps the ring and drops the growth.
struct FocusLift: ViewModifier {
    let focused: Bool
    var radius: CGFloat = Radius.card
    var scale: CGFloat = 1.06
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(focused ? Palette.primary : Palette.border, lineWidth: focused ? 5 : 1.5)
            )
            .scaleEffect(focused && !reduceMotion ? scale : 1)
            .shadow(color: Palette.scrim.opacity(focused ? 0.55 : 0), radius: focused ? 24 : 0, y: focused ? 16 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: focused)
    }
}

extension View {
    func focusLift(_ focused: Bool, radius: CGFloat = Radius.card, scale: CGFloat = 1.06) -> some View {
        modifier(FocusLift(focused: focused, radius: radius, scale: scale))
    }
}

/// A button whose label draws its own focus (cards, rows, cells): no system
/// highlight, just the label, told whether it's focused.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension ButtonStyle where Self == CardButtonStyle {
    static var streamCard: CardButtonStyle { CardButtonStyle() }
}

/// Reads whether the enclosing button is focused, for a label to draw from.
struct Focused<Content: View>: View {
    @Environment(\.isFocused) private var focused
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(focused) }
}

/// The app's one focus spring, and the growth and rise that go with it —
/// none of it under Reduce Motion, where focus shows by ring and colour.
struct FocusMotion: ViewModifier {
    let focused: Bool
    var scale: CGFloat = 1
    var rise: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(focused && !reduceMotion ? scale : 1)
            .offset(y: focused && !reduceMotion ? rise : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: focused)
    }
}

extension View {
    /// A little larger while focused.
    func focusGrow(_ focused: Bool, _ scale: CGFloat = 1.06) -> some View {
        modifier(FocusMotion(focused: focused, scale: scale))
    }

    /// Moved down while focused, out from under a lifted card.
    func focusRise(_ focused: Bool, _ by: CGFloat) -> some View {
        modifier(FocusMotion(focused: focused, rise: by))
    }

    /// Changes that follow focus, sprung (or not, under Reduce Motion).
    func focusMotion(_ focused: Bool) -> some View {
        modifier(FocusMotion(focused: focused))
    }
}
