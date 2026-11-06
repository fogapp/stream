import SwiftUI

/// The web's design tokens (frontend/src/index.css), for the ten-foot screen.
/// The cardinal rule holds here too: every colour in the app comes from
/// `Palette` — `make lint` fails on a raw colour anywhere outside this file.
/// Dark only: Stream is watched in the dark. The values are the web's oklch
/// tokens converted to sRGB exactly (Scripts/showcase.py has the maths' twin).
enum Palette {
    static let background = Color(rgb: 0x090B10)
    static let surface = Color(rgb: 0x11141A)
    static let surfaceRaised = Color(rgb: 0x1A1E26)
    static let foreground = Color(rgb: 0xF0F2F5)
    static let muted = Color(rgb: 0x9398A4)
    static let border = Color(rgb: 0x272B35)

    /// The logo's cyan water.
    static let primary = Color(rgb: 0x2FD4EC)
    static let primaryHover = Color(rgb: 0x59E4F3)
    static let primaryForeground = Color(rgb: 0x02121A)

    static let positive = Color(rgb: 0x4DBF74)
    static let negative = Color(rgb: 0xF05F5A)
    static let warning = Color(rgb: 0xE7B643)

    /// Over pictures: scrims, captions and the QR code's quiet zone.
    static let scrim = Color(rgb: 0x000000)
    static let paper = Color(rgb: 0xFFFFFF)

    /// A colour the server sends (a profile's, an artwork's average).
    static func from(hex: String?) -> Color? {
        guard let hex else { return nil }
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(rgb: value)
    }
}

extension Color {
    fileprivate init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

/// The web's radii (0.5rem controls, 0.75rem cards) at television distance.
enum Radius {
    static let control: CGFloat = 12
    static let card: CGFloat = 18
}

/// Spacing on a 1920×1080 point screen: the title-safe margin, rows, gaps.
enum Space {
    static let margin: CGFloat = 80
    static let rowGap: CGFloat = 56
    static let cardGap: CGFloat = 40
    static let stack: CGFloat = 24
}

/// The type scale. Sizes are points on the 1080p canvas — larger than the
/// web's, read from across a room — and all in the system face.
enum TextStyle {
    case display, title, title2, headline, body, callout, caption, eyebrow, number

    var font: Font {
        switch self {
        case .display: return .system(size: 76, weight: .bold)
        case .title: return .system(size: 52, weight: .bold)
        case .title2: return .system(size: 38, weight: .semibold)
        case .headline: return .system(size: 29, weight: .semibold)
        case .body: return .system(size: 29, weight: .regular)
        case .callout: return .system(size: 25, weight: .regular)
        case .caption: return .system(size: 22, weight: .medium)
        case .eyebrow: return .system(size: 21, weight: .bold)
        case .number: return .system(size: 34, weight: .semibold, design: .monospaced)
        }
    }
}

extension View {
    /// Text in one of the scale's styles; the eyebrow is uppercase and spaced.
    func textStyle(_ style: TextStyle, color: Color = Palette.foreground) -> some View {
        font(style.font)
            .foregroundStyle(color)
            .tracking(style == .eyebrow ? 2.5 : 0)
            .textCase(style == .eyebrow ? .uppercase : nil)
    }
}
