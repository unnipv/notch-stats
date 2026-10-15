import AppKit

/// Geometry of the physical notch on the current display.
struct NotchGeometry {
    var screen: NSScreen
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var menuBarHeight: CGFloat
    var hasNotch: Bool

    /// Height the island should occupy — never taller than the camera housing.
    var barHeight: CGFloat { hasNotch ? notchHeight : menuBarHeight }

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens.first!

        let safeTop = screen.safeAreaInsets.top

        // Distance between the top of the screen and the top of the content
        // area: the visual menu bar height. Falls back to the physical notch
        // height when the menu bar is auto-hidden.
        var menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        if menuBar <= 0 { menuBar = safeTop > 0 ? safeTop : NSStatusBar.system.thickness }
        if menuBar <= 0 { menuBar = 24 }

        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        let notchWidth: CGFloat = (left != nil && right != nil) ? screen.frame.width - left!.width - right!.width : 200
        let notchHeight: CGFloat = left?.height ?? (safeTop > 0 ? safeTop : menuBar)

        return NotchGeometry(screen: screen,
                             notchWidth: notchWidth,
                             notchHeight: notchHeight,
                             menuBarHeight: menuBar,
                             hasNotch: safeTop > 0)
    }
}
