import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppStore {
    enum IslandState {
        case collapsed
        case peek
        case expanded
    }

    enum Page {
        case usage
        case activity
    }

    var state: IslandState = .collapsed {
        didSet {
            guard state != oldValue else { return }
            sessionMonitor.setWatching(state == .expanded)
        }
    }
    var page: Page = .usage
    var geometries: [IslandGeometry] = IslandGeometry.all()
    var providers: [ProviderUsage] = []
    private(set) var sessions: [AgentSession] = []
    /// Agents with a session that is currently working. Stored, not computed —
    /// deriving it during a render pass re-invalidates the view every frame —
    /// and only assigned when it changes, so observers aren't woken for nothing.
    private(set) var liveAgents: Set<AgentKind> = []
    var refreshing = false
    var lastRefresh: Date?

    /// Draw a floating pill on displays without a notch. Off by default: it
    /// floats above the menu bar and can cover other apps.
    var showOnExternalDisplays: Bool {
        didSet { UserDefaults.standard.set(showOnExternalDisplays, forKey: Self.externalKey) }
    }

    private static let externalKey = "showOnExternalDisplays"

    /// Let NotchStats perform a single non-interactive keychain read once at
    /// launch (and once after wake) when no plain file or captured snapshot
    /// holds a live token. Off by default; background polling never reads the
    /// keychain regardless of this setting.
    var allowKeychainAccess: Bool {
        didSet {
            guard allowKeychainAccess != oldValue else { return }
            UserDefaults.standard.set(allowKeychainAccess, forKey: ClaudeCredentials.keychainOptInKey)
            ClaudeCredentials.resetKeychainSession()
            AntigravityCredentials.resetKeychainSession()
            AntigravityProvider.invalidateCache()
            Task { @MainActor in
                if allowKeychainAccess {
                    await warmKeychainCredentialsIfAllowed()
                }
                await refresh(force: false)
            }
        }
    }

    private let engines: [UsageProvider] = [
        CodexProvider(),
        ClaudeProvider(),
        AntigravityProvider(),
        AnthropicAPIProvider(),
        OpenCodeGoProvider(),
        OpenRouterProvider()
    ]

    private let sessionMonitor = SessionMonitor()
    private var backoffs: [String: Backoff] = [:]
    private var wakeObservers: [NSObjectProtocol] = []

    private var hoverTask: Task<Void, Never>?
    private var forcedState = false

    init() {
        showOnExternalDisplays = UserDefaults.standard.bool(forKey: Self.externalKey)
        allowKeychainAccess = ClaudeCredentials.keychainAllowed

        // Test hook: NOTCHSTATS_STATE=collapsed|peek|expanded forces the initial state.
        switch ProcessInfo.processInfo.environment["NOTCHSTATS_STATE"] {
        case "peek": state = .peek; forcedState = true
        case "expanded": state = .expanded; forcedState = true
        case "collapsed": forcedState = true
        default: break
        }
        if ProcessInfo.processInfo.environment["NOTCHSTATS_PAGE"] == "activity" { page = .activity }
    }

    /// Size the island occupies on a given display.
    func islandSize(for geometry: IslandGeometry) -> CGSize {
        switch state {
        case .collapsed:
            return CGSize(width: geometry.collapsedWidth, height: geometry.barHeight)
        case .peek:
            return CGSize(width: geometry.collapsedWidth + (geometry.hasNotch ? 70 : 84),
                          height: geometry.barHeight)
        case .expanded:
            let width = min(geometry.screen.frame.width - 120, 560)
            return CGSize(width: width, height: Self.expandedHeight(barHeight: geometry.barHeight,
                                                                    rows: contentRows,
                                                                    rowHeight: contentRowHeight))
        }
    }

    /// Row metrics shared with the panel layout.
    static let rowHeight: CGFloat = 72
    static let sessionRowHeight: CGFloat = 52
    static let rowSpacing: CGFloat = 8
    static let footerHeight: CGFloat = 32

    /// Rows the current page shows. An empty page (loading, no providers, no
    /// sessions) gets three rows of room for its message.
    private var contentRows: Int {
        switch page {
        case .usage: return providers.isEmpty ? 3 : min(6, providers.count)
        case .activity: return sessions.isEmpty ? 3 : min(6, sessions.count)
        }
    }

    private var contentRowHeight: CGFloat {
        page == .usage ? Self.rowHeight : Self.sessionRowHeight
    }

    /// Height of the open panel: the menu-bar band, exactly the rows being
    /// shown, and the footer — no reserved space. The height only changes when
    /// the number of rows does (or the page), which is rare, so a refresh
    /// never makes the panel twitch.
    static func expandedHeight(barHeight: CGFloat, rows: Int, rowHeight: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, rows))
        return barHeight + 10 + count * rowHeight + (count - 1) * rowSpacing + 12 + footerHeight + 10
    }

    func provider(_ id: String) -> ProviderUsage? {
        providers.first { $0.id == id }
    }

    func updateGeometries(_ geometries: [IslandGeometry]) {
        self.geometries = geometries
    }

    // MARK: - Lifecycle

    func start() {
        // Documentation/screenshot mode: fictional data, no network, no reads.
        if let variant = ProcessInfo.processInfo.environment["NOTCHSTATS_DEMO"], !variant.isEmpty, variant != "0" {
            providers = DemoData.providers(variant: variant)
            apply(sessions: DemoData.sessions)
            lastRefresh = Date()
            return
        }

        sessionMonitor.onChange = { [weak self] list in
            Task { @MainActor in self?.apply(sessions: list) }
        }
        sessionMonitor.start()
        observeWake()
        Task { @MainActor in
            // At most one silent non-interactive keychain read at launch (only
            // when opted in and no file/snapshot already holds a live token).
            // The poll loop below performs zero keychain reads.
            await warmKeychainCredentialsIfAllowed()
            await refresh()
            dumpProvidersIfRequested()
            while !Task.isCancelled {
                let jitter = Double.random(in: 0...8)
                try? await Task.sleep(nanoseconds: UInt64((60 + jitter) * 1_000_000_000))
                await refresh()
            }
        }
    }

    private func dumpProvidersIfRequested() {
        guard ProcessInfo.processInfo.environment["NOTCHSTATS_DUMP"] != nil else { return }
        let lines = providers.map { p in
            let summary: String
            if let error = p.error {
                summary = "error=\"\(error)\" issue=\(String(describing: p.issue))"
            } else {
                summary = "windows=\(p.windows.count) metrics=\(p.metrics.count)"
            }
            return "[provider] id=\(p.id) name=\(p.name) \(summary)"
        }.joined(separator: "\n")
        FileHandle.standardError.write(Data((lines + "\n").utf8))
    }

    /// Performs at most one non-interactive (`UIFail` + `LAContext`) keychain
    /// read per provider when `allowKeychainAccess` is on and no plain file or
    /// captured snapshot already supplies a live token. Never prompts.
    private func warmKeychainCredentialsIfAllowed() async {
        guard allowKeychainAccess else { return }
        await ClaudeCredentials.warmFromKeychainIfAllowed()
        await AntigravityCredentials.warmFromKeychainIfAllowed()
    }

    func apply(sessions list: [AgentSession]) {
        if list != sessions { sessions = list }
        let live = Set(list.filter { $0.isLive() }.map(\.agent))
        if live != liveAgents { liveAgents = live }
    }

    /// After sleep the network is usually not back yet and the cached keychain
    /// read may be stale, so forget it and retry once (non-interactively) once
    /// things settle.
    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    ClaudeCredentials.resetKeychainSession()
                    AntigravityCredentials.resetKeychainSession()
                    AntigravityProvider.invalidateCache()
                    self.backoffs = [:]
                    self.sessionMonitor.refresh()
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    await self.warmKeychainCredentialsIfAllowed()
                    await self.refresh()
                }
            })
        }
    }

    func isAgentLive(_ kind: AgentKind) -> Bool {
        liveAgents.contains(kind)
    }

    /// Explicit menu action: may display the macOS Keychain prompt once, then
    /// saves an app-private `0600` snapshot so polling never reads the Keychain.
    func captureClaudeLogin() {
        Task { @MainActor in
            _ = await ClaudeCredentials.captureFromKeychain()
            backoffs.removeValue(forKey: ClaudeProvider.id)
            await refresh(force: false)
        }
    }

    /// Explicit menu action: deletes only NotchStats's `0600` Claude snapshot.
    func forgetClaudeLogin() {
        ClaudeCredentials.forgetSnapshot()
        providers.removeAll { $0.id == ClaudeProvider.id }
        backoffs.removeValue(forKey: ClaudeProvider.id)
        Task { @MainActor in await refresh(force: false) }
    }

    /// Explicit menu action: may display the macOS Keychain prompt once, then
    /// saves an app-private `0600` snapshot so polling never reads the Keychain.
    func captureGeminiLogin() {
        Task { @MainActor in
            _ = await AntigravityCredentials.captureFromKeychain()
            AntigravityProvider.invalidateCache()
            backoffs.removeValue(forKey: AntigravityProvider.id)
            await refresh(force: false)
        }
    }

    /// Explicit menu action: deletes only NotchStats's `0600` Gemini snapshot.
    func forgetGeminiLogin() {
        AntigravityCredentials.forgetSnapshot()
        AntigravityProvider.invalidateCache()
        providers.removeAll { $0.id == AntigravityProvider.id }
        backoffs.removeValue(forKey: AntigravityProvider.id)
        Task { @MainActor in await refresh(force: false) }
    }

    /// Manual refresh: clears cached credentials and backoff, retries the
    /// non-interactive launch read once if opted in, and re-queries providers.
    func refreshNow() {
        Task { await refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer {
            refreshing = false
            lastRefresh = Date()
        }

        if force {
            ClaudeCredentials.resetKeychainSession()
            AntigravityCredentials.resetKeychainSession()
            AntigravityProvider.invalidateCache()
            backoffs = [:]
            await warmKeychainCredentialsIfAllowed()
        }

        let now = Date()
        // Background ticks stagger their requests; the first load and manual
        // refreshes go out together so the user isn't kept waiting.
        let spread = !force && lastRefresh != nil
        let due = engines.filter { backoffs[$0.id]?.allows(now: now) ?? true }

        let results = await withTaskGroup(of: (String, ProviderUsage?).self) { group -> [String: ProviderUsage?] in
            for (position, engine) in due.enumerated() {
                // Spread the requests out: five simultaneous TLS handshakes are
                // a visible one-second CPU spike, and nothing here is urgent.
                let delay = spread ? UInt64(position) * 1_000_000_000 : 0
                // Fence each provider so one that blocks (a keychain prompt, a
                // stalled connection) can never hold up the others.
                group.addTask {
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                    let usage = await withTimeout(seconds: 20, fallback: engine.timedOut() as ProviderUsage?) {
                        await engine.fetch()
                    }
                    return (engine.id, usage)
                }
            }
            var collected: [String: ProviderUsage?] = [:]
            for await (id, usage) in group { collected[id] = usage }
            return collected
        }

        var merged: [ProviderUsage] = []
        for engine in engines {
            let previous = provider(engine.id)
            guard let outcome = results[engine.id] else {
                // Backing off: keep showing what we have.
                if let previous { merged.append(previous) }
                continue
            }
            backoffs[engine.id, default: Backoff()].record(outcome, now: now)
            if let outcome, let kept = ProviderUsage.merge(outcome, previous: previous) {
                merged.append(kept)
            }
        }

        let sorted = merged.sorted { $0.order < $1.order }
        if sorted != providers { providers = sorted }
    }

    // MARK: - Interaction

    func setHover(_ hovering: Bool) {
        hoverTask?.cancel()
        if hovering {
            if state == .collapsed { state = .peek }
        } else {
            guard state != .expanded else { return }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 220_000_000)
                if !Task.isCancelled, state == .peek { state = .collapsed }
            }
        }
    }

    func toggleExpanded() {
        state = (state == .expanded) ? .collapsed : .expanded
    }
}
