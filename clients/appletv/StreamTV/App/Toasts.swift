import Observation
import SwiftUI

/// The web's toasts: a short word that something happened ("Northbound:
/// marked watched"), in the corner, gone by itself.
@MainActor
@Observable
final class Toasts {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let failed: Bool
    }

    private(set) var current: Toast?

    func show(_ message: String, failed: Bool = false) {
        let toast = Toast(message: message, failed: failed)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { current = toast }
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if current == toast { withAnimation(.easeOut(duration: 0.3)) { current = nil } }
        }
    }
}

struct ToastOverlay: View {
    let toasts: Toasts

    var body: some View {
        VStack {
            if let toast = toasts.current {
                HStack(spacing: 18) {
                    Image(systemName: toast.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.failed ? Palette.negative : Palette.positive)
                    Text(toast.message).textStyle(.callout)
                }
                .font(.system(size: 28))
                .padding(.horizontal, 30)
                .padding(.vertical, 20)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.border, lineWidth: 1.5))
                .shadow(color: Palette.scrim.opacity(0.5), radius: 30, y: 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 50)
        .padding(.trailing, Space.margin)
        .allowsHitTesting(false)
    }
}

/// Which movies, episodes and videos are in the profile's Watch later.
@MainActor
@Observable
final class WatchLater {
    private(set) var ids: Set<String> = []

    func load(_ api: StreamAPI) async {
        if let list: WatchLaterList = try? await api.get("api/v1/watch_later") { ids = Set(list.items) }
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func toggle(kind: String, id: String, api: StreamAPI) async throws -> Bool {
        if ids.contains(id) {
            try await api.delete("api/v1/watch_later", query: ["item_type": kind, "item_id": id])
            ids.remove(id)
            return false
        }
        let _: Empty = try await api.post("api/v1/watch_later", body: WatchLaterItem(itemType: kind, itemId: id))
        ids.insert(id)
        return true
    }

    private struct WatchLaterList: Decodable { let items: [String] }
    private struct WatchLaterItem: Encodable {
        let itemType: String
        let itemId: String
    }
}
