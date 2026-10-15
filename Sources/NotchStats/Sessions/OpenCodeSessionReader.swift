import Foundation
import SQLite3

/// Read-only reader for live OpenCode (v2) sessions.
///
/// Sessions live in `session_v2`; their messages live in `session_message`,
/// which embeds the message's content parts (reasoning / text / tool) as JSON.
/// We open a single long-lived read-only connection — safe against the CLI's
/// concurrent WAL writes — and derive a per-session state from the newest
/// message.
final class OpenCodeSessionReader {
    private let path: String
    private var db: OpaquePointer?

    init(path: String = OpenCodeDB.databasePath) {
        self.path = path
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func connection() -> OpaquePointer? {
        if let db { return db }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &handle,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        db = handle
        return handle
    }

    // MARK: - Public

    func sessions(limit: Int = 5) -> [AgentSession] {
        guard let db = connection() else { return [] }

        let sql = """
        select id, title, directory, time_updated, time_compacting, model
        from session_v2
        where time_archived is null
        order by time_updated desc
        limit ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var sessions: [AgentSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, 0) ?? ""
            let title = columnText(stmt, 1) ?? "Untitled"
            let directory = columnText(stmt, 2) ?? ""
            let sessionUpdated = (columnDouble(stmt, 3) ?? 0) / 1000
            let compacting = columnText(stmt, 4) != nil
            let modelJSON = jsonObject(columnText(stmt, 5) ?? "")

            let last = lastMessage(db, session: id)

            // `session_v2.time_updated` lags behind message activity, so prefer
            // whichever timestamp is newest.
            let updatedAt = Date(timeIntervalSince1970: max(sessionUpdated, last?.timeCreated ?? 0))

            var state = Self.state(kind: last?.kind, message: last?.data, compacting: compacting)
            // A message that never completed but has been quiet for a while is
            // no longer "working" — it was interrupted or abandoned.
            if state.isActive, Date().timeIntervalSince(updatedAt) > 15 * 60 {
                state = .done
            }

            sessions.append(AgentSession(
                id: id,
                agent: .opencode,
                title: title,
                project: projectName(directory),
                state: state,
                model: shortModel((last?.data["model"] as? [String: Any])?["id"] as? String
                                  ?? modelJSON?["id"] as? String),
                updatedAt: updatedAt
            ))
        }
        return sessions
    }

    // MARK: - State inference (unit-tested)

    static func state(kind: String?, message: [String: Any]?, compacting: Bool) -> SessionState {
        if compacting { return .compacting }
        guard let message else { return .done }
        if kind == "user" || kind == "agent-switched" { return .thinking }

        let time = message["time"] as? [String: Any] ?? [:]
        if time["completed"] != nil { return .done }

        let content = message["content"] as? [[String: Any]] ?? []
        for part in content.reversed() {
            switch part["type"] as? String {
            case "tool":
                let status = (part["state"] as? [String: Any])?["status"] as? String
                if status == "running" || status == "pending" {
                    let name = (part["name"] as? String) ?? (part["tool"] as? String) ?? "tool"
                    return .tool(name)
                }
                // Tool finished — the model is working on the result next.
                return .thinking
            case "reasoning":
                return .thinking
            case "text":
                return .responding
            default:
                continue
            }
        }
        return .thinking
    }

    // MARK: - SQLite helpers

    private func lastMessage(_ db: OpaquePointer, session: String)
        -> (kind: String, data: [String: Any], timeCreated: Double)? {
        var stmt: OpaquePointer?
        let sql = "select type, data, time_created from session_message where session_id = ?1 order by seq desc limit 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, session, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let raw = columnText(stmt, 1),
              let data = jsonObject(raw) else { return nil }
        return (columnText(stmt, 0) ?? "", data, (columnDouble(stmt, 2) ?? 0) / 1000)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private func columnDouble(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }
}
