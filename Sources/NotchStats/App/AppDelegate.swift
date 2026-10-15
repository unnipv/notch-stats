import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = AppStore()
    private var island: IslandWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        island = IslandWindowController(store: store)
        island?.show()
        installStatusItem()
        store.start()
        dumpGeometryIfRequested()
    }

    private func dumpGeometryIfRequested() {
        guard ProcessInfo.processInfo.environment["NOTCHSTATS_DUMP"] != nil else { return }
        let g = store.geo
        FileHandle.standardError.write(Data("""
        [geometry]
          screen.frame        = \(g.screen.frame)
          screen.visibleFrame = \(g.screen.visibleFrame)
          safeAreaInsets.top  = \(g.screen.safeAreaInsets.top)
          auxiliaryTopLeft    = \(String(describing: g.screen.auxiliaryTopLeftArea))
          auxiliaryTopRight   = \(String(describing: g.screen.auxiliaryTopRightArea))
          notchWidth          = \(g.notchWidth)
          notchHeight         = \(g.notchHeight)
          barHeight           = \(g.barHeight)
          menuBarHeight       = \(g.menuBarHeight)
          hasNotch            = \(g.hasNotch)
          island(collapsed)   = \(store.islandSize)

        """.utf8))
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                              accessibilityDescription: "NotchStats")
            img?.isTemplate = true
            button.image = img
        }

        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NotchStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func refreshNow() {
        store.refreshNow()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        if LaunchAtLogin.set(enable) {
            sender.state = enable ? .on : .off
        }
    }
}
