import AppKit

/// How the island is drawn on a given screen.
enum IslandStyle {
    /// The display has a physical camera housing; the island hugs it.
    case notch
    /// No notch — draw a free-floating pill near the top of the display.
    case pill
}

/// Geometry of the island on one display.
struct IslandGeometry {
    var screen: NSScreen
    var style: IslandStyle
    /// Width of the physical notch. Zero for a floating pill.
    var notchWidth: CGFloat
    /// Collapsed height — never taller than the camera housing.
    var barHeight: CGFloat
    var menuBarHeight: CGFloat
    /// Width of the black "ear" on each side of the notch.
    var earWidth: CGFloat

    var hasNotch: Bool { style == .notch }

    var collapsedWidth: CGFloat { notchWidth + earWidth * 2 }

    /// Corner radii. Notched displays keep square top corners so the island
    /// merges with the housing; a floating pill is rounded all round.
    var topRadius: CGFloat { style == .notch ? 0 : barHeight / 2 }
    var bottomRadius: CGFloat { style == .notch ? 9 : barHeight / 2 }

    static func forScreen(_ screen: NSScreen) -> IslandGeometry {
        let safeTop = screen.safeAreaInsets.top

        // Distance between the top of the screen and the top of the content
        // area: the visual menu bar height. Falls back to the physical notch
        // height when the menu bar is auto-hidden.
        var menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        if menuBar <= 0 { menuBar = safeTop > 0 ? safeTop : NSStatusBar.system.thickness }
        if menuBar <= 0 { menuBar = 24 }

        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea

        if safeTop > 0, let left, let right, left.width > 0, right.width > 0 {
            let notchHeight = left.height > 0 ? left.height : safeTop
            return IslandGeometry(screen: screen,
                                  style: .notch,
                                  notchWidth: screen.frame.width - left.width - right.width,
                                  barHeight: notchHeight,
                                  menuBarHeight: menuBar,
                                  earWidth: 70)
        }

        return IslandGeometry(screen: screen,
                              style: .pill,
                              notchWidth: 0,
                              barHeight: 28,
                              menuBarHeight: menuBar,
                              earWidth: 126)
    }

    /// Gap between the top of a non-notched display and the floating pill.
    static let pillTopGap: CGFloat = 6

    /// Extra slop around the visible island that still counts as "on" it —
    /// shared by the hosting view's hit test and the outside-click test.
    static let hitPadding: CGFloat = 10

    /// The visible island in screen coordinates (origin bottom-left), given the
    /// size the island currently occupies. Shared by window placement and the
    /// outside-click test so the two can never drift.
    static func islandFrame(in screenFrame: CGRect, hasNotch: Bool, size: CGSize) -> CGRect {
        let topGap: CGFloat = hasNotch ? 0 : pillTopGap
        return CGRect(x: screenFrame.midX - size.width / 2,
                      y: screenFrame.maxY - size.height - topGap,
                      width: size.width,
                      height: size.height)
    }

    func islandFrame(size: CGSize) -> CGRect {
        Self.islandFrame(in: screen.frame, hasNotch: style == .notch, size: size)
    }

    /// True when `point` lies on any island, counting `hitPadding` of slop.
    /// An outside click collapses the expanded island only when this is false.
    static func isOnAnyIsland(_ point: CGPoint, islandFrames: [CGRect]) -> Bool {
        islandFrames.contains { frame in
            frame.width > 0 && frame.height > 0
                && frame.insetBy(dx: -hitPadding, dy: -hitPadding).contains(point)
        }
    }

    /// All currently connected displays, notched ones first.
    static func all() -> [IslandGeometry] {
        NSScreen.screens
            .map(forScreen)
            .sorted { lhs, rhs in
                if lhs.hasNotch != rhs.hasNotch { return lhs.hasNotch }
                return lhs.screen.frame.minX < rhs.screen.frame.minX
            }
    }
}
