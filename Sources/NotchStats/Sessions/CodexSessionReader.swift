import Foundation

/// Reads the newest Codex rollout transcript and derives its current state.
///
/// Codex writes JSONL events to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
/// We only ever read the tail, so cost stays flat regardless of session length.
struct CodexSessionReader {

    /// Newest rollout file, searching today's date bucket first.
    static func newestRollout(now: Date = Date()) -> URL? {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions")
        let calendar = Calendar.current

        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = parts.year, let m = parts.month, let d = parts.day else { continue }
            let dir = root
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))

            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }

            let newest = files
                .filter { $0.pathExtension == "jsonl" }
                .max { lhs, rhs in modification(lhs) < modification(rhs) }

            if let newest { return newest }
        }
        return nil
    }

    private static func modification(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Current session state, or nil when there is no recent transcript.
    static func current(now: Date = Date()) -> AgentSession? {
        guard let url = newestRollout(now: now) else { return nil }
        return parse(url: url)
    }

    static func parse(url: URL, now: Date = Date()) -> AgentSession? {
        let updatedAt = modification(url)
        let meta = readHead(url)
        guard let lines = readTail(url) else { return nil }

        var taskRunning: Bool?
        var detail: SessionState = .thinking

        for line in lines {
            guard let event = jsonObject(line) else { continue }
            guard let payload = event["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }

            switch type {
            case "task_started":
                taskRunning = true
            case "task_complete", "turn_aborted":
                taskRunning = false
                detail = .done
            case "function_call", "custom_tool_call":
                detail = .tool(payload["name"] as? String ?? "tool")
            case "reasoning":
                detail = .thinking
            case "message", "agent_message":
                detail = .responding
            case "compaction":
                detail = .compacting
            default:
                break
            }
        }

        let state: SessionState
        if taskRunning == true { state = detail }
        else if taskRunning == false { state = .done }
        else { state = updatedAt.timeIntervalSince(now) > -300 ? .thinking : .done }

        return AgentSession(
            id: url.deletingPathExtension().lastPathComponent,
            agent: .codex,
            title: meta.title,
            project: projectName(meta.cwd),
            state: state,
            model: meta.model,
            updatedAt: updatedAt
        )
    }

    // MARK: - Transcript IO

    private static func readTail(_ url: URL, maxBytes: Int = 128 * 1024) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }

        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func readHead(_ url: URL, maxBytes: Int = 8 * 1024) -> (title: String, cwd: String, model: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("Codex session", "", nil) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return ("Codex session", "", nil) }

        var cwd = ""
        var model: String?
        var title: String?

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            guard let event = jsonObject(String(line)),
                  let payload = event["payload"] as? [String: Any] else { continue }

            if let value = payload["cwd"] as? String, !value.isEmpty { cwd = value }
            if let value = payload["model"] as? String, !value.isEmpty { model = value }
            if title == nil, let text = payload["message"] as? String, !text.isEmpty {
                title = String(text.prefix(48))
            }
        }

        let name = projectName(cwd)
        return (title ?? (name.isEmpty ? "Codex session" : name), cwd, model)
    }
}
