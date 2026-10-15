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
        for g in store.geometries {
            FileHandle.standardError.write(Data("""
            [geometry] \(g.screen.localizedName) style=\(g.hasNotch ? "notch" : "pill")
              screen.frame        = \(g.screen.frame)
              screen.visibleFrame = \(g.screen.visibleFrame)
              safeAreaInsets.top  = \(g.screen.safeAreaInsets.top)
              auxiliaryTopLeft    = \(String(describing: g.screen.auxiliaryTopLeftArea))
              auxiliaryTopRight   = \(String(describing: g.screen.auxiliaryTopRightArea))
              notchWidth          = \(g.notchWidth)
              barHeight           = \(g.barHeight)
              menuBarHeight       = \(g.menuBarHeight)
              island(collapsed)   = \(store.islandSize(for: g))

            """.utf8))
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                                accessibilityDescription: "NotchStats")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "NotchStats"
        }

        let menu = NSMenu()

        let title = NSMenuItem(title: "NotchStats", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let external = NSMenuItem(title: "Show on External Displays",
                                  action: #selector(toggleExternalDisplays), keyEquivalent: "")
        external.target = self
        external.state = store.showOnExternalDisplays ? .on : .off
        menu.addItem(external)

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

    @objc private func toggleExternalDisplays(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        store.showOnExternalDisplays = enable
        sender.state = enable ? .on : .off
        island?.refreshDisplays()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        if LaunchAtLogin.set(enable) {
            sender.state = enable ? .on : .off
        }
    }
}
