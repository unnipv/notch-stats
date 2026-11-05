import SwiftUI

struct IslandRootView: View {
    let store: AppStore
    let geometry: IslandGeometry

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = store.islandSize(for: geometry)
        return ZStack(alignment: .top) {
            IslandBackground(geometry: geometry, size: size, expanded: store.state == .expanded)
            content
                .id(store.state)
                .transition(.opacity)
                .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onHover { store.setHover($0) }
        .onTapGesture { store.toggleExpanded() }
        // One short, non-bouncy spring for every state change; a plain fade
        // under Reduce Motion.
        .animation(reduceMotion ? .easeOut(duration: 0.12)
                                : .spring(response: 0.32, dampingFraction: 0.9),
                   value: store.state)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The island is anchored to a black camera housing: always dark.
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchStats")
        .accessibilityHint(store.state == .expanded ? "Click to collapse" : "Click to expand")
    }

    @ViewBuilder private var content: some View {
        switch store.state {
        case .collapsed: BarView(store: store, geometry: geometry, detailed: false)
        case .peek: BarView(store: store, geometry: geometry, detailed: true)
        case .expanded: ExpandedView(store: store, geometry: geometry)
        }
    }
}

struct IslandBackground: View {
    let geometry: IslandGeometry
    let size: CGSize
    var expanded: Bool = false

    private static let debugFill: Color? =
        ProcessInfo.processInfo.environment["NOTCHSTATS_DEBUG_BG"].map { _ in Color(hex: "#243244") }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: geometry.topRadius,
                               bottomLeadingRadius: expanded ? 24 : geometry.bottomRadius,
                               bottomTrailingRadius: expanded ? 24 : geometry.bottomRadius,
                               topTrailingRadius: geometry.topRadius,
                               style: .continuous)
    }

    private var hairline: some View {
        shape.strokeBorder(Theme.hairline(expanded: expanded), lineWidth: 0.5)
    }

    var body: some View {
        if let debugFill = Self.debugFill {
            // Test hook: flat, screenshot-friendly fill.
            shape.fill(debugFill).overlay(hairline)
        } else if expanded {
            let band = min(0.5, Double(geometry.barHeight / max(size.height, 1)))
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(Theme.glassWash(bandFraction: band)))
                .overlay(hairline)
        } else {
            // Collapsed/peek: pure black so the ear merges with the housing.
            shape.fill(Color.black).overlay(hairline)
        }
    }
}
