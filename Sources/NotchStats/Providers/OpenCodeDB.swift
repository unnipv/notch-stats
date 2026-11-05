import Foundation
import SQLite3

/// Minimal read-only reader for OpenCode's SQLite store.
///
/// OpenCode keeps provider credentials in the `credential` table. We open the
/// database read-only (`mode=ro`) and never write to it — the CLI owns
/// refreshing its own tokens.
enum OpenCodeDB {
    static var databasePath: String {
        NSHomeDirectory() + "/.local/share/opencode/opencode.db"
    }

    /// Returns true when OpenCode holds an Anthropic **API key** (not an OAuth
    /// login, which belongs to a Claude subscription and isn't billed per use).
    static func hasAnthropicAPIKey(path: String = OpenCodeDB.databasePath) -> Bool {
        guard let credential = credentialJSON(integrationIDs: ["anthropic"], path: path) else {
            return false
        }
        // OAuth credentials carry `access`/`refresh`; API keys carry `key`.
        if (credential["type"] as? String) == "oauth" { return false }
        let key = ((credential["key"] as? String) ?? (credential["access"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A few versions stored user OAuth tokens under `key`.
        if key.contains("-oat") { return false }
        return !key.isEmpty
    }

    /// Spend attributed to Anthropic API models, as recorded by OpenCode.
    struct AnthropicSpend: Equatable, Sendable {
        /// Cost of assistant messages since the start of the current month.
        let monthToDate: Double
        /// Cost of assistant messages since local midnight.
        let today: Double
        /// Number of billed assistant messages behind those totals.
        let messages: Int
    }

    /// Sums OpenCode's own per-message cost for `providerID == "anthropic"`.
    ///
    /// OpenCode writes `cost` on every completed assistant message, which makes
    /// this an accurate local ledger of pay-as-you-go API spend. It is *spend*,
    /// not a credit balance — Anthropic exposes no balance endpoint for API
    /// keys. Returns nil if the database can't be queried.
    static func anthropicSpend(now: Date = Date(),
                               calendar: Calendar = .current,
                               path: String = OpenCodeDB.databasePath) -> AnthropicSpend? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let dayStart = calendar.startOfDay(for: now)
        let monthStartMS = Int64(monthStart.timeIntervalSince1970 * 1000)
        let dayStartMS = Int64(dayStart.timeIntervalSince1970 * 1000)

        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // Restrict to this month before touching JSON so the time index does the
        // heavy lifting. Incomplete (still-streaming) messages have no cost yet.
        let sql = """
        select
          coalesce(sum(cost), 0),
          coalesce(sum(case when time_created >= ?2 then cost else 0 end), 0),
          count(*)
        from (
          select time_created, cast(json_extract(data, '$.cost') as real) as cost
          from session_message
          where type = 'assistant'
            and json_extract(data, '$.model.providerID') = 'anthropic'
            and json_extract(data, '$.cost') is not null
            and time_created >= ?1
        )
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, monthStartMS)
        sqlite3_bind_int64(stmt, 2, dayStartMS)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return AnthropicSpend(monthToDate: sqlite3_column_double(stmt, 0),
                              today: sqlite3_column_double(stmt, 1),
                              messages: Int(sqlite3_column_int(stmt, 2)))
    }

    /// Returns the parsed JSON credential for the first matching integration
    /// (`integration_id`), most recently updated first.
    static func credentialJSON(integrationIDs: [String], path: String = OpenCodeDB.databasePath) -> [String: Any]? {
        guard !integrationIDs.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }

        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // Prefer earlier entries in `integrationIDs` (e.g. "opencode-go" over the
        // legacy "opencode"), then the most recently updated row.
        let inClause = Array(repeating: "?", count: integrationIDs.count).joined(separator: ",")
        let caseClause = integrationIDs.enumerated()
            .map { "when ? then \($0.offset)" }
            .joined(separator: " ")
        let sql = """
        select value from credential
        where integration_id in (\(inClause)) and active = 1
        order by case integration_id \(caseClause) else 99 end, time_updated desc
        limit 1
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var bind: Int32 = 1
        for id in integrationIDs {
            sqlite3_bind_text(stmt, bind, id, -1, SQLITE_TRANSIENT); bind += 1
        }
        for id in integrationIDs {
            sqlite3_bind_text(stmt, bind, id, -1, SQLITE_TRANSIENT); bind += 1
        }

        guard sqlite3_step(stmt) == SQLITE_ROW, let cString = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        let raw = String(cString: cString)

        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return ["key": raw]
    }
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
