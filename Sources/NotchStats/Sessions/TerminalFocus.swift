import AppKit

/// Brings a terminal / editor to the front so clicking a session row takes you
/// to where the work is happening.
enum TerminalFocus {
    /// Ordered by how likely the user is to have the agent running there.
    private static let bundleIDs = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92" // Cursor
    ]

    @discardableResult
    static func focusFrontmostTerminal() -> Bool {
        let running = NSWorkspace.shared.runningApplications
        for id in bundleIDs {
            if let app = running.first(where: { $0.bundleIdentifier == id }), !app.isTerminated {
                app.activate(options: [.activateIgnoringOtherApps])
                return true
            }
        }
        return false
    }
}
