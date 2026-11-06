import TVServices

/// The Top Shelf (PROPOSAL §7.4 on the TV): Continue watching and what's
/// on the Grid now, from the snapshot the app keeps — selecting one opens
/// its page, Play/Pause plays it.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let snapshot = TopShelfSnapshot.read() else { return completionHandler(nil) }
        let sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = snapshot.sections.compactMap { section in
            let items = section.items.map(Self.item)
            guard !items.isEmpty else { return nil }
            let collection = TVTopShelfItemCollection(items: items)
            collection.title = section.title
            return collection
        }
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }

    private static func item(_ item: TopShelfSnapshot.Item) -> TVTopShelfSectionedItem {
        let shelf = TVTopShelfSectionedItem(identifier: item.id)
        shelf.title = item.title
        shelf.imageShape = .hdtv
        if let name = item.image, let url = TopShelfSnapshot.directory?.appendingPathComponent(name) {
            shelf.setImageURL(url, for: .screenScale1x)
            shelf.setImageURL(url, for: .screenScale2x)
        }
        if let progress = item.progress, progress > 0 { shelf.playbackProgress = progress }
        if let url = URL(string: item.display) { shelf.displayAction = TVTopShelfAction(url: url) }
        if let url = URL(string: item.play) { shelf.playAction = TVTopShelfAction(url: url) }
        return shelf
    }
}
