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

    private let engines: [UsageProvider] = [
        CodexProvider(),
        ClaudeProvider(),
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
                                                                    rows: providers.count))
        }
    }

    /// Row metrics shared with the panel layout.
    static let rowHeight: CGFloat = 72
    static let rowSpacing: CGFloat = 8
    static let footerHeight: CGFloat = 32

    /// Height of the open panel: menu-bar band, the rows (at least four, so the
    /// Activity page and an empty state have room), and the footer.
    static func expandedHeight(barHeight: CGFloat, rows: Int) -> CGFloat {
        let count = CGFloat(min(6, max(4, rows)))
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
            await refresh()
            while !Task.isCancelled {
                let jitter = Double.random(in: 0...8)
                try? await Task.sleep(nanoseconds: UInt64((60 + jitter) * 1_000_000_000))
                await refresh()
            }
        }
    }

    func apply(sessions list: [AgentSession]) {
        if list != sessions { sessions = list }
        let live = Set(list.filter { $0.isLive() }.map(\.agent))
        if live != liveAgents { liveAgents = live }
    }

    /// After sleep the network is usually not back yet and the cached keychain
    /// read may be stale, so forget it and look again once things settle.
    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    ClaudeCredentials.invalidate()
                    self.backoffs = [:]
                    self.sessionMonitor.refresh()
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    await self.refresh()
                }
            })
        }
    }

    func isAgentLive(_ kind: AgentKind) -> Bool {
        liveAgents.contains(kind)
    }

    /// Manual refresh: clears cached credentials and backoff first.
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
            ClaudeCredentials.invalidate()
            backoffs = [:]
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
