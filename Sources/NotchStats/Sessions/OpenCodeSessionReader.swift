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
    private var sessionsStmt: OpaquePointer?
    private var lastMessageStmt: OpaquePointer?
    private var versionStmt: OpaquePointer?

    /// `PRAGMA data_version` at the last full read. It changes whenever another
    /// connection commits, so an unchanged value means every row we hold is
    /// still current and the queries (and the JSON decode of message bodies)
    /// can be skipped.
    private var lastVersion: Int64?
    private var rows: [Row] = []
    private(set) var queries = 0
    private var sawBusy = false

    /// Everything the DB told us about one session, before the clock is applied.
    private struct Row {
        var id: String
        var title: String
        var directory: String
        var updatedAt: Date
        var state: SessionState
        var model: String?
    }

    init(path: String = OpenCodeDB.databasePath) {
        self.path = path
    }

    deinit { close() }

    private func close() {
        sqlite3_finalize(sessionsStmt); sessionsStmt = nil
        sqlite3_finalize(lastMessageStmt); lastMessageStmt = nil
        sqlite3_finalize(versionStmt); versionStmt = nil
        if let db { sqlite3_close(db) }
        db = nil
        lastVersion = nil
    }

    private func connection() -> OpaquePointer? {
        if let db { return db }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        db = OpenCodeDB.openReadOnly(path)
        return db
    }

    private func prepare(_ sql: String, into slot: inout OpaquePointer?, db: OpaquePointer) -> OpaquePointer? {
        if let slot { sqlite3_reset(slot); return slot }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        slot = stmt
        return stmt
    }

    private func dataVersion(_ db: OpaquePointer) -> Int64? {
        guard let stmt = prepare("pragma data_version", into: &versionStmt, db: db) else { return nil }
        defer { sqlite3_reset(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    // MARK: - Public

    /// Newest live sessions. If the database is busy or briefly unreadable the
    /// previous result is returned, so a row never vanishes mid-write.
    func sessions(limit: Int = 5, now: Date = Date()) -> [AgentSession] {
        guard let db = connection() else {
            rows = []
            return []
        }

        let version = dataVersion(db)
        if version == nil || version != lastVersion {
            switch load(db, limit: limit) {
            case let .loaded(fresh):
                rows = fresh
                lastVersion = version
            case .busy:
                break
            case .broken:
                // The file was replaced or corrupted under us: reconnect next time.
                close()
                return derive(now: now)
            }
        }
        return derive(now: now)
    }

    private func derive(now: Date) -> [AgentSession] {
        rows.map { row in
            var state = row.state
            // A message that never completed but has been quiet for a while is
            // no longer "working" — it was interrupted or abandoned.
            if state.isActive, now.timeIntervalSince(row.updatedAt) > 15 * 60 { state = .done }
            return AgentSession(id: row.id, agent: .opencode, title: row.title,
                                project: projectName(row.directory), state: state,
                                model: row.model, updatedAt: row.updatedAt)
        }
    }

    private enum LoadResult {
        case loaded([Row])
        case busy
        case broken
    }

    private func load(_ db: OpaquePointer, limit: Int) -> LoadResult {
        queries += 1
        sawBusy = false
        let sql = """
        select id, title, directory, time_updated, time_compacting, model
        from session_v2
        where time_archived is null
        order by time_updated desc
        limit ?
        """
        guard let stmt = prepare(sql, into: &sessionsStmt, db: db) else { return .broken }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var loaded: [Row] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            if step == SQLITE_BUSY || step == SQLITE_LOCKED { return .busy }
            guard step == SQLITE_ROW else { return .broken }

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
            let state = Self.state(kind: last?.kind, message: last?.data, compacting: compacting)

            loaded.append(Row(
                id: id, title: title, directory: directory, updatedAt: updatedAt, state: state,
                model: shortModel((last?.data["model"] as? [String: Any])?["id"] as? String
                                  ?? modelJSON?["id"] as? String)))
        }
        return sawBusy ? .busy : .loaded(loaded)
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
        let sql = "select type, data, time_created from session_message where session_id = ?1 order by seq desc limit 1"
        guard let stmt = prepare(sql, into: &lastMessageStmt, db: db) else { return nil }
        defer { sqlite3_reset(stmt) }
        sqlite3_bind_text(stmt, 1, session, -1, SQLITE_TRANSIENT)
        let step = sqlite3_step(stmt)
        if step == SQLITE_BUSY || step == SQLITE_LOCKED { sawBusy = true }
        guard step == SQLITE_ROW,
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
