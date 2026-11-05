import Foundation

/// Polls for agent activity on a background queue and publishes snapshots.
///
/// Deliberately cheap: one `PRAGMA data_version` for OpenCode, one `stat` of the
/// newest Codex transcript, and parsing only when either has changed. The timer
/// lives on the monitor's own queue (never the main run loop), runs fast while
/// something is working or the panel is open, and slows down when idle.
final class SessionMonitor: @unchecked Sendable {
    var onChange: (@Sendable ([AgentSession]) -> Void)?

    static let activeInterval: TimeInterval = 2.5
    static let idleInterval: TimeInterval = 6

    private let queue = DispatchQueue(label: "dev.notchstats.sessions", qos: .utility)
    private let opencode = OpenCodeSessionReader()
    private let codexCache = CodexSessionReader.Cache()
    private var timer: DispatchSourceTimer?
    private var lastPublished: [AgentSession]?
    private var lastLive: Set<AgentKind> = []
    private var watching = false

    /// Panel open: keep the activity page fresh.
    func setWatching(_ value: Bool) {
        queue.async { [weak self] in
            guard let self, self.watching != value else { return }
            self.watching = value
            if self.timer != nil { self.schedule(after: 0) }
        }
    }

    func start() {
        queue.async { [weak self] in self?.schedule(after: 0) }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// Next poll; a fresh timer replaces the old one so intervals can change.
    private func schedule(after delay: TimeInterval) {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay, leeway: .milliseconds(400))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    /// Wake or manual refresh: poll right away.
    func refresh() {
        queue.async { [weak self] in
            guard let self, self.timer != nil else { return }
            self.schedule(after: 0)
        }
    }

    private func tick() {
        let now = Date()
        var sessions = opencode.sessions(now: now)
        if let codex = CodexSessionReader.current(now: now, cache: codexCache) { sessions.append(codex) }

        let snapshot = sessions.sorted {
            if $0.isLive(now: now) != $1.isLive(now: now) { return $0.isLive(now: now) }
            return $0.updatedAt > $1.updatedAt
        }

        let live = Set(snapshot.filter { $0.isLive(now: now) }.map(\.agent))
        if snapshot != lastPublished || live != lastLive {
            lastPublished = snapshot
            lastLive = live
            onChange?(snapshot)
        }

        // Re-arm: a one-shot timer lets the interval follow what is happening.
        let interval = (watching || !live.isEmpty) ? Self.activeInterval : Self.idleInterval
        timer?.schedule(deadline: .now() + interval, leeway: .milliseconds(600))
    }
}
