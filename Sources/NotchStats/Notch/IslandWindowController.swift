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
final class ScreenIsland {
    private let panel: IslandPanel
    private let hosting: IslandHostingView<IslandRootView>
    var geometry: IslandGeometry

    /// The window is always this big; the island is drawn inside and
    /// hit-tested against its current size.
    private static let maxSize = CGSize(width: 680, height: 620)

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

    /// Renders the island over a stand-in wallpaper and writes a PNG. Debug
    /// aid for `NOTCHSTATS_SNAPSHOT`; used because screen capture needs a
    /// permission this process shouldn't ask for.
    func snapshot(to url: URL, islandSize: CGSize) {
        hosting.layoutSubtreeIfNeeded()
        let bounds = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        hosting.cacheDisplay(in: bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / bounds.width
        let crop = CGSize(width: min(bounds.width, islandSize.width + 40), height: islandSize.height + 24)
        let pixels = NSSize(width: crop.width * scale, height: crop.height * scale)
        let output = NSImage(size: pixels)
        output.lockFocus()
        // Menu-bar-ish wallpaper so translucency has something to show.
        NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.30, blue: 0.55, alpha: 1),
                            NSColor(calibratedRed: 0.62, green: 0.38, blue: 0.50, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: pixels), angle: -30)
        let source = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        source.addRepresentation(rep)
        // The island hugs the top edge of the (flipped-free) bitmap.
        let x = (bounds.width - crop.width) / 2 * scale
        source.draw(in: NSRect(x: -x, y: pixels.height - CGFloat(rep.pixelsHigh),
                               width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)),
                    from: .zero, operation: .sourceOver, fraction: 1)
        output.unlockFocus()

        if let tiff = output.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?
            .representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
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

    func snapshot(to url: URL) {
        guard let first = islands.first else { return }
        first.snapshot(to: url, islandSize: store.islandSize(for: first.geometry))
    }

    /// Re-reads the display configuration. Call after changing display
    /// preferences.
    func refreshDisplays() {
        rebuild()
    }

    @objc private func screenParametersChanged() {
        rebuild()
    }

    private func rebuild() {
        let all = IslandGeometry.all()
        let notched = all.filter(\.hasNotch)

        // Prefer notched displays only. External pill windows float above the
        // menu bar and can sit over other apps, so they are opt-in — but if no
        // display has a notch we still show something rather than nothing.
        let geometries = (store.showOnExternalDisplays || notched.isEmpty) ? all : notched

        store.updateGeometries(geometries)

        // Tear down and rebuild: display configuration changes are rare, and
        // this keeps geometry simple and correct.
        islands.forEach { $0.close() }
        islands = geometries.map { ScreenIsland(store: store, geometry: $0) }
        islands.forEach { $0.show() }
    }
}
