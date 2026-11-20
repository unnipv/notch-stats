import Foundation
import SQLite3

/// Month-to-date Anthropic API spend, kept incrementally.
///
/// Re-aggregating a month of message JSON on every refresh costs around 0.3 s
/// of CPU. Instead the first call scans the month once, remembering each
/// message's cost by id; later calls only look at messages newer than the last
/// one seen (minus a margin for messages that were still streaming and so had
/// no cost yet) and fold those in.
final class AnthropicSpendLedger: @unchecked Sendable {
    static let shared = AnthropicSpendLedger()

    /// A message can finish — and gain its `cost` — well after it was created.
    /// Rows this far behind the newest are not revisited.
    static let overlapMS: Int64 = 30 * 60 * 1000

    private struct Entry { let created: Int64; let cost: Double }

    private let lock = NSLock()
    private var monthStartMS: Int64 = 0
    private var watermark: Int64 = 0
    private var entries: [String: Entry] = [:]

    func reset() {
        lock.lock(); defer { lock.unlock() }
        monthStartMS = 0; watermark = 0; entries = [:]
    }

    func update(now: Date = Date(),
                calendar: Calendar = .current,
                path: String = OpenCodeDB.databasePath) -> OpenCodeDB.AnthropicSpend? {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: path),
              let db = OpenCodeDB.openReadOnly(path) else { return nil }
        defer { sqlite3_close(db) }

        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let monthMS = Int64(monthStart.timeIntervalSince1970 * 1000)
        let dayMS = Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1000)

        if monthMS != monthStartMS {
            monthStartMS = monthMS; watermark = 0; entries = [:]
        }
        let from = watermark == 0 ? monthMS : max(monthMS, watermark - Self.overlapMS)

        let sql = """
        select id, time_created, cast(json_extract(data, '$.cost') as real)
        from session_message
        where time_created >= ?1 and type = 'assistant'
          and json_extract(data, '$.model.providerID') = 'anthropic'
          and json_extract(data, '$.cost') is not null
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, from)

        var scanned: [String: Entry] = [:]
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            // Busy or corrupt mid-scan: keep what we had, try again next time.
            guard step == SQLITE_ROW else {
                return watermark == 0 ? nil : summary(dayMS: dayMS, monthMS: monthMS)
            }
            guard let cString = sqlite3_column_text(stmt, 0) else { continue }
            let created = sqlite3_column_int64(stmt, 1)
            scanned[String(cString: cString)] = Entry(created: created, cost: sqlite3_column_double(stmt, 2))
        }
        for (id, entry) in scanned { entries[id] = entry }
        // Everything up to now has been seen, apart from messages still
        // streaming — those fall inside the overlap and are looked at again.
        watermark = max(watermark, Int64(now.timeIntervalSince1970 * 1000))
        return summary(dayMS: dayMS, monthMS: monthMS)
    }

    private func summary(dayMS: Int64, monthMS: Int64) -> OpenCodeDB.AnthropicSpend {
        var month = 0.0, today = 0.0
        for entry in entries.values where entry.created >= monthMS {
            month += entry.cost
            if entry.created >= dayMS { today += entry.cost }
        }
        return OpenCodeDB.AnthropicSpend(monthToDate: month, today: today, messages: entries.count)
    }
}
