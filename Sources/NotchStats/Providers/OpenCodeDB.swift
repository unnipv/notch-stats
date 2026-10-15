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
    static func credentialJSON(integrationIDs: [String]) -> [String: Any]? {
        guard !integrationIDs.isEmpty,
              FileManager.default.fileExists(atPath: databasePath) else { return nil }

        var db: OpaquePointer?
        let uri = "file:\(databasePath)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: integrationIDs.count).joined(separator: ",")
        let sql = """
        select value from credential
        where integration_id in (\(placeholders)) and active = 1
        order by time_updated desc limit 1
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        for (index, id) in integrationIDs.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), id, -1, SQLITE_TRANSIENT)
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

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
