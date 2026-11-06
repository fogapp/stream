import SwiftUI

/// A page opening out of the card that opened it (tvOS 18's zoom), the
/// way the web's detail pages rise out of their posters. The stack's
/// namespace comes from MainView; without it, or on tvOS 17, or under
/// Reduce Motion, pages push as usual.
private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

private struct ZoomSource: ViewModifier {
    let route: Route
    @Environment(\.zoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if #available(tvOS 18.0, *), let namespace {
            content.matchedTransitionSource(id: route, in: namespace)
        } else {
            content
        }
    }
}

private struct ZoomDestination: ViewModifier {
    let route: Route
    @Environment(\.zoomNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(tvOS 18.0, *), let namespace, !reduceMotion {
            content.navigationTransition(.zoom(sourceID: route, in: namespace))
        } else {
            content
        }
    }
}

extension View {
    /// This card opens `route`: the page zooms out of it.
    func zoomSource(_ route: Route) -> some View { modifier(ZoomSource(route: route)) }

    /// This page zooms out of the card that opened it.
    func zoomDestination(_ route: Route) -> some View { modifier(ZoomDestination(route: route)) }
}

/// A slide in from an edge — or, under Reduce Motion, a fade.
extension AnyTransition {
    static func slide(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}

/// A link to a page, which that page zooms out of.
struct RouteLink<Label: View>: View {
    let route: Route
    @ViewBuilder let label: () -> Label

    init(_ route: Route, @ViewBuilder label: @escaping () -> Label) {
        self.route = route
        self.label = label
    }

    var body: some View {
        NavigationLink(value: route, label: label).zoomSource(route)
    }
}
