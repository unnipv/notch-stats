import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats above the menu bar.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that only claims hit-tests inside the visible island, so clicks
/// anywhere else fall through to the desktop / menu bar underneath.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var islandSize: () -> CGSize = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let size = islandSize()
        guard size.width > 0, size.height > 0 else { return nil }

        let local = convert(point, from: superview)
        let rect: CGRect
        if isFlipped {
            rect = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        } else {
            rect = CGRect(x: (bounds.width - size.width) / 2,
                          y: bounds.height - size.height, width: size.width, height: size.height)
        }
        let padded = rect.insetBy(dx: -10, dy: -10)
        guard padded.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }
}

/// One island window on one display.
@MainActor
private final class ScreenIsland {
    private let panel: IslandPanel
    private let hosting: IslandHostingView<IslandRootView>
    var geometry: IslandGeometry

    /// The window is always this big; the island is drawn inside and
    /// hit-tested against its current size.
    private static let maxSize = CGSize(width: 680, height: 460)

    init(store: AppStore, geometry: IslandGeometry) {
        self.geometry = geometry

        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: Self.maxSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        hosting = IslandHostingView(rootView: IslandRootView(store: store, geometry: geometry))
        hosting.islandSize = { [weak store, weak self] in
            guard let store, let self else { return .zero }
            return store.islandSize(for: self.geometry)
        }
        panel.contentView = hosting
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: Self.maxSize)

        reposition()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
    }

    func reposition() {
        let size = Self.maxSize
        let frame = geometry.screen.frame

        let topGap: CGFloat = geometry.hasNotch ? 0 : 6
        let origin = CGPoint(x: frame.midX - size.width / 2,
                             y: frame.maxY - size.height - topGap)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// Owns one island window per connected display and keeps them in sync with the
/// display configuration.
@MainActor
final class IslandWindowController {
    private let store: AppStore
    private var islands: [ScreenIsland] = []

    init(store: AppStore) {
        self.store = store
        rebuild()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    func show() {
        islands.forEach { $0.show() }
    }

    @objc private func screenParametersChanged() {
        rebuild()
    }

    private func rebuild() {
        let geometries = IslandGeometry.all()
        store.updateGeometries(geometries)

        // Tear down and rebuild: display configuration changes are rare, and
        // this keeps geometry simple and correct.
        islands.forEach { $0.close() }
        islands = geometries.map { ScreenIsland(store: store, geometry: $0) }
        islands.forEach { $0.show() }
    }
}
