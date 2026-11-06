import SwiftUI

/// A profile's face (the web's ProfileAvatar): its emoji or initial on its
/// own colour — the one colour that's the profile's data, not the theme's.
struct ProfileAvatar: View {
    let profile: Profile
    var size: CGFloat = 64

    var body: some View {
        Text(profile.avatar ?? String(profile.name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Palette.background)
            .frame(width: size, height: size)
            .background(Palette.from(hex: profile.color) ?? Palette.muted, in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }
}
