import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = AppStore()
    private var island: IslandWindowController?
    private var statusItem: NSStatusItem?

    private var forgetClaudeItem: NSMenuItem?
    private var forgetGeminiItem: NSMenuItem?
    private var keychainAccessItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        KeychainGuard.disableBackgroundInteraction()
        island = IslandWindowController(store: store)
        island?.show()
        installStatusItem()
        store.start()
        dumpGeometryIfRequested()
        snapshotIfRequested()
    }

    /// `NOTCHSTATS_SNAPSHOT=/path/out.png`: render the island once and quit.
    private func snapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["NOTCHSTATS_SNAPSHOT"] else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            island?.snapshot(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
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
        menu.autoenablesItems = false
        menu.delegate = self

        let title = NSMenuItem(title: "NotchStats", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let captureClaude = NSMenuItem(title: "Capture Claude login…",
                                       action: #selector(captureClaudeLogin), keyEquivalent: "")
        captureClaude.target = self
        captureClaude.toolTip = "Reads Claude Code's login from the macOS Keychain once (macOS may ask for your "
            + "password) and saves a private 0600 snapshot in ~/Library/Application Support/NotchStats/credentials/. "
            + "Background polling reads that snapshot and never touches the Keychain."
        menu.addItem(captureClaude)

        let forgetClaude = NSMenuItem(title: "Forget Claude login",
                                      action: #selector(forgetClaudeLogin), keyEquivalent: "")
        forgetClaude.target = self
        forgetClaude.isEnabled = CredentialSnapshotStore.exists(provider: .claude)
        forgetClaude.toolTip = "Deletes NotchStats's private Claude snapshot. Never touches ~/.claude/ or the Keychain."
        menu.addItem(forgetClaude)
        forgetClaudeItem = forgetClaude

        let captureGemini = NSMenuItem(title: "Capture Gemini login…",
                                       action: #selector(captureGeminiLogin), keyEquivalent: "")
        captureGemini.target = self
        captureGemini.toolTip = "Reads Antigravity's login from the macOS Keychain once (macOS may ask for your "
            + "password) and saves a private 0600 snapshot in ~/Library/Application Support/NotchStats/credentials/. "
            + "Background polling reads that snapshot and never touches the Keychain."
        menu.addItem(captureGemini)

        let forgetGemini = NSMenuItem(title: "Forget Gemini login",
                                      action: #selector(forgetGeminiLogin), keyEquivalent: "")
        forgetGemini.target = self
        forgetGemini.isEnabled = CredentialSnapshotStore.exists(provider: .gemini)
        forgetGemini.toolTip = "Deletes NotchStats's private Gemini snapshot. Never touches ~/.gemini/ or the Keychain."
        menu.addItem(forgetGemini)
        forgetGeminiItem = forgetGemini

        menu.addItem(.separator())

        let external = NSMenuItem(title: "Show on External Displays",
                                  action: #selector(toggleExternalDisplays), keyEquivalent: "")
        external.target = self
        external.state = store.showOnExternalDisplays ? .on : .off
        menu.addItem(external)

        let keychain = NSMenuItem(title: "Allow Keychain Access (read once at launch)",
                                  action: #selector(toggleKeychainAccess), keyEquivalent: "")
        keychain.target = self
        keychain.state = store.allowKeychainAccess ? .on : .off
        keychain.toolTip = "Off by default. When on, NotchStats attempts one silent, non-interactive Keychain read "
            + "at launch or wake (useful when signed with a stable certificate and granted Always Allow). "
            + "Background polls never read the Keychain."
        menu.addItem(keychain)
        keychainAccessItem = keychain

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

        if ProcessInfo.processInfo.environment["NOTCHSTATS_DUMP"] != nil {
            let visible = item.button?.window != nil
            FileHandle.standardError.write(Data("[statusItem] created=\(visible)\n".utf8))
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        forgetClaudeItem?.isEnabled = CredentialSnapshotStore.exists(provider: .claude)
        forgetGeminiItem?.isEnabled = CredentialSnapshotStore.exists(provider: .gemini)
        keychainAccessItem?.state = store.allowKeychainAccess ? .on : .off
    }

    @objc private func refreshNow() {
        store.refreshNow()
    }

    @objc private func captureClaudeLogin() {
        store.captureClaudeLogin()
    }

    @objc private func forgetClaudeLogin() {
        store.forgetClaudeLogin()
    }

    @objc private func captureGeminiLogin() {
        store.captureGeminiLogin()
    }

    @objc private func forgetGeminiLogin() {
        store.forgetGeminiLogin()
    }

    @objc private func toggleExternalDisplays(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        store.showOnExternalDisplays = enable
        sender.state = enable ? .on : .off
        island?.refreshDisplays()
    }

    @objc private func toggleKeychainAccess(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        store.allowKeychainAccess = enable
        sender.state = enable ? .on : .off
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        if LaunchAtLogin.set(enable) {
            sender.state = enable ? .on : .off
        }
    }
}
