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
