import Foundation

/// Polls for agent activity on a background queue and publishes snapshots.
///
/// Deliberately cheap: a handful of indexed SQLite reads plus a stat of the
/// newest Codex transcript. Detailed parsing only happens for the rows we show.
final class SessionMonitor: @unchecked Sendable {
    var onChange: (@Sendable ([AgentSession]) -> Void)?

    private let queue = DispatchQueue(label: "dev.notchstats.sessions", qos: .utility)
    private let opencode = OpenCodeSessionReader()
    private var timer: Timer?
    private let interval: TimeInterval = 2.5

    func start() {
        refresh()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            var sessions = self.opencode.sessions()
            if let codex = CodexSessionReader.current() { sessions.append(codex) }

            let snapshot = sessions.sorted {
                if $0.isLive() != $1.isLive() { return $0.isLive() }
                return $0.updatedAt > $1.updatedAt
            }
            self.onChange?(snapshot)
        }
    }
}
