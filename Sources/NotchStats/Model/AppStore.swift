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
    var geo: NotchGeometry = .current()
    var providers: [ProviderUsage] = []
    var sessions: [AgentSession] = []
    var refreshing = false
    var lastRefresh: Date?

    private let engines: [UsageProvider] = [
        CodexProvider(),
        OpenCodeGoProvider(),
        OpenRouterProvider()
    ]

    private let sessionMonitor = SessionMonitor()

    private var hoverTask: Task<Void, Never>?
    private var forcedState = false

    /// Width of the black "ear" that extends past the physical notch.
    let earWidth: CGFloat = 70

    init() {
        // Test hook: NOTCHSTATS_STATE=collapsed|peek|expanded forces the initial state.
        switch ProcessInfo.processInfo.environment["NOTCHSTATS_STATE"] {
        case "peek": state = .peek; forcedState = true
        case "expanded": state = .expanded; forcedState = true
        case "collapsed": forcedState = true
        default: break
        }
        if ProcessInfo.processInfo.environment["NOTCHSTATS_PAGE"] == "activity" { page = .activity }
    }

    var islandSize: CGSize {
        switch state {
        case .collapsed:
            return CGSize(width: geo.notchWidth + earWidth * 2, height: geo.barHeight)
        case .peek:
            return CGSize(width: geo.notchWidth + 210, height: geo.barHeight)
        case .expanded:
            let width = min(geo.screen.frame.width - 120, 560)
            return CGSize(width: width, height: geo.barHeight + 318)
        }
    }

    func provider(_ id: String) -> ProviderUsage? {
        providers.first { $0.id == id }
    }

    func updateGeometry(_ geometry: NotchGeometry) {
        geo = geometry
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

    /// Agents with a session that is currently working.
    var liveAgents: Set<AgentKind> {
        Set(sessions.filter { $0.isLive() }.map(\.agent))
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
