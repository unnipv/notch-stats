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

    var state: IslandState = .collapsed
    var page: Page = .usage
    var geometries: [IslandGeometry] = IslandGeometry.all()
    var providers: [ProviderUsage] = []
    var sessions: [AgentSession] = [] {
        didSet { liveAgents = Set(sessions.filter { $0.isLive() }.map(\.agent)) }
    }
    /// Agents with a session that is currently working. Stored, not computed —
    /// deriving it during a render pass re-invalidates the view every frame.
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
        OpenCodeGoProvider(),
        OpenRouterProvider()
    ]

    private let sessionMonitor = SessionMonitor()

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
            return CGSize(width: width, height: geometry.barHeight + 318)
        }
    }

    func provider(_ id: String) -> ProviderUsage? {
        providers.first { $0.id == id }
    }

    func updateGeometries(_ geometries: [IslandGeometry]) {
        self.geometries = geometries
    }

    // MARK: - Lifecycle

    func start() {
        sessionMonitor.onChange = { [weak self] list in
            Task { @MainActor in self?.sessions = list }
        }
        sessionMonitor.start()
        Task { @MainActor in
            await refresh()
            while !Task.isCancelled {
                let jitter = Double.random(in: 0...8)
                try? await Task.sleep(nanoseconds: UInt64((60 + jitter) * 1_000_000_000))
                await refresh()
            }
        }
    }

    func isAgentLive(_ kind: AgentKind) -> Bool {
        liveAgents.contains(kind)
    }

    func refreshNow() {
        Task { await refresh() }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true

        let engines = self.engines
        let results = await withTaskGroup(of: ProviderUsage.self) { group -> [ProviderUsage] in
            for engine in engines {
                group.addTask { await engine.fetch() }
            }
            var collected: [ProviderUsage] = []
            for await result in group { collected.append(result) }
            return collected
        }

        providers = results.sorted { $0.order < $1.order }
        refreshing = false
        lastRefresh = Date()
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
