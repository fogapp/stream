import SwiftUI

struct ArtworkView: View {
    @Environment(AppState.self) private var state
    let artwork: Artwork?

    var body: some View {
        if let artwork, let url = state.api.absolute(artwork.src) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                (Palette.from(hex: artwork.color) ?? Palette.surfaceRaised)
            }
        } else {
            ZStack {
                Palette.surfaceRaised
                Image(systemName: "film").font(.largeTitle).foregroundStyle(Palette.muted)
            }
        }
    }
}
