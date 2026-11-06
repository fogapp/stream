import SwiftUI
import UIKit

/// Fetches, decodes and keeps pictures (PROPOSAL §6.4: "blurred
/// placeholders, no layout shift"): decoded images in memory, responses on
/// disk, decoding off the main thread, and rows fetched ahead of scrolling.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSURL, UIImage>()
    private let placeholders = NSCache<NSString, UIImage>()
    private let session: URLSession

    init() {
        memory.totalCostLimit = 256 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = try? await session.data(from: url).0
        }
        guard let data, let image = UIImage(data: data) else { return nil }
        // The simulator can't predecode WebP (it logs -17102, "possibly
        // corrupt"); the image itself is fine, so show it undecoded.
        let decoded = await image.byPreparingForDisplay() ?? image
        memory.setObject(decoded, forKey: url as NSURL, cost: Int(decoded.size.width * decoded.size.height * 4))
        return decoded
    }

    func prefetch(_ urls: [URL]) {
        for url in urls where cached(url) == nil {
            Task.detached(priority: .utility) { _ = await self.image(url) }
        }
    }

    /// The tiny blurred copy the server inlines, decoded once.
    func placeholder(_ dataURI: String) -> UIImage? {
        if let hit = placeholders.object(forKey: dataURI as NSString) { return hit }
        guard let comma = dataURI.firstIndex(of: ","), let data = Data(base64Encoded: String(dataURI[dataURI.index(after: comma)...])),
              let image = UIImage(data: data) else { return nil }
        placeholders.setObject(image, forKey: dataURI as NSString)
        return image
    }
}

extension Artwork {
    /// The rendition closest above `points` wide on this screen, from the srcset.
    func source(forWidth points: CGFloat, scale: CGFloat) -> String {
        guard let srcset, !srcset.isEmpty else { return src }
        let wanted = points * scale
        let candidates: [(String, CGFloat)] = srcset.split(separator: ",").compactMap { entry in
            let parts = entry.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard parts.count == 2, let width = Double(parts[1].dropLast()) else { return nil }
            return (String(parts[0]), CGFloat(width))
        }.sorted { $0.1 < $1.1 }
        return candidates.first { $0.1 >= wanted }?.0 ?? candidates.last?.0 ?? src
    }
}

/// A picture as the web draws one (components/viewing/ArtworkImage.tsx):
/// its average colour at once, the blurred placeholder over it, then the
/// picture fading in. Without artwork, the title on a raised surface.
struct ArtworkImage: View {
    @Environment(AppState.self) private var state
    @Environment(\.displayScale) private var scale
    let artwork: Artwork?
    /// How wide it's drawn, in points, to choose a rendition.
    var width: CGFloat = 400
    var contentMode: ContentMode = .fill
    /// A logo: transparent, fitted, nothing behind it.
    var logo = false
    var fallback: String?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if !logo {
                Rectangle().fill(Palette.from(hex: artwork?.color) ?? Palette.surfaceRaised)
                if image == nil, let placeholder = artwork?.placeholder.flatMap(ImagePipeline.shared.placeholder) {
                    Image(uiImage: placeholder).resizable().aspectRatio(contentMode: .fill).blur(radius: 18).scaleEffect(1.1)
                }
            }
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: logo ? .leading : .center)
                    .transition(.opacity)
            } else if artwork == nil, let fallback, !logo {
                Text(fallback).textStyle(.headline, color: Palette.muted).multilineTextAlignment(.center).padding(24)
            }
        }
        .clipped()
        .task(id: url) { await load() }
        .accessibilityHidden(true)
    }

    private var url: URL? {
        guard let artwork else { return nil }
        return state.api.absolute(artwork.source(forWidth: width, scale: scale))
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        if let hit = ImagePipeline.shared.cached(url) {
            image = hit
            return
        }
        let loaded = await ImagePipeline.shared.image(url)
        withAnimation(.easeOut(duration: 0.3)) { image = loaded }
    }
}
