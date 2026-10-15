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
        let s = islandSize()
        guard s.width > 0, s.height > 0 else { return nil }

        let local = convert(point, from: superview)
        let rect: CGRect
        if isFlipped {
            rect = CGRect(x: (bounds.width - s.width) / 2, y: 0, width: s.width, height: s.height)
        } else {
            rect = CGRect(x: (bounds.width - s.width) / 2,
                          y: bounds.height - s.height, width: s.width, height: s.height)
        }
        let padded = rect.insetBy(dx: -10, dy: -10)
        guard padded.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }
}

@MainActor
final class IslandWindowController {
    private let store: AppStore
    private let panel: IslandPanel
    private let hosting: IslandHostingView<IslandRootView>

    /// The window itself is always this big; the island is drawn inside and
    /// hit-tested against its current size.
    private static let maxSize = CGSize(width: 680, height: 420)

    init(store: AppStore) {
        self.store = store

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

        let root = IslandRootView(store: store)
        hosting = IslandHostingView(rootView: root)
        hosting.islandSize = { [weak store] in store?.islandSize ?? .zero }
        panel.contentView = hosting

        reposition()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    @objc private func screenParametersChanged() {
        store.updateGeometry(.current())
        reposition()
    }

    private func reposition() {
        let geo = store.geo
        let size = Self.maxSize
        let origin = CGPoint(x: geo.screen.frame.midX - size.width / 2,
                             y: geo.screen.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
