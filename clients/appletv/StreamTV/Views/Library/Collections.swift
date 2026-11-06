import SwiftUI

/// Every collection (PROPOSAL §4.2).
struct CollectionsView: View {
    @Environment(AppState.self) private var state
    @State private var collections: [CollectionCard]?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text("Collections").textStyle(.title)
                if let collections {
                    if collections.isEmpty { EmptyState(title: "No collections yet", detail: "Collections are made on the web.") }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(260), spacing: Space.cardGap), count: 5), alignment: .leading, spacing: 60) {
                        ForEach(collections) { collection in
                            RouteLink(Route.collection(collection.id)) {
                                Focused { focused in
                                    PosterCard(card: Card(kind: "collection", id: collection.id, title: collection.title, code: nil, year: nil,
                                                          images: collection.images, progress: nil, watched: nil, show: nil, seasonNumber: nil,
                                                          episodeNumber: nil, unwatchedCount: nil, arrival: "\(collection.itemCount ?? 0) titles"),
                                               focused: focused)
                                }
                            }
                            .buttonStyle(.streamCard)
                        }
                    }
                } else if let error {
                    ErrorState(message: error) { Task { await load() } }
                } else {
                    LoadingState()
                }
            }
            .padding(Space.margin)
        }
        .task { await load() }
    }

    private func load() async {
        do {
            collections = try await state.api.get("api/v1/collections")
            error = nil
        } catch {
            state.handle(error)
            self.error = error.localizedDescription
        }
    }
}
