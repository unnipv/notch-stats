import XCTest
import SQLite3
@testable import NotchStats

final class PerformanceTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func makeDatabase() -> String {
        let path = NSTemporaryDirectory() + "notchstats-perf-\(UUID().uuidString).db"
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        sqlite3_exec(db, """
        pragma journal_mode = wal;
        create table session_message (id text primary key, session_id text not null, type text not null,
          seq integer not null, time_created integer not null, time_updated integer not null, data text not null);
        create index session_message_time_created_idx on session_message (time_created);
        create table session_v2 (id text primary key, title text, directory text, time_updated integer,
          time_compacting integer, time_archived integer, model text);
        """, nil, nil, nil)
        sqlite3_close(db)
        return path
    }

    private func exec(_ path: String, _ sql: String) {
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
    }

    private func insertMessage(_ path: String, id: String, at created: Date, cost: Double?,
                               provider: String = "anthropic", type: String = "assistant") {
        let costField = cost.map { ",\"cost\":\($0)" } ?? ""
        exec(path, """
        insert or replace into session_message values
        ('\(id)', 's1', '\(type)', 0, \(ms(created)), 0,
         '{"model":{"id":"m","providerID":"\(provider)"}\(costField)}');
        """)
    }

    // MARK: - Spend ledger

    func testLedgerMatchesTheFullScan() {
        let path = makeDatabase(); defer { try? FileManager.default.removeItem(atPath: path) }
        let now = date("2026-10-27T12:00:00Z")
        insertMessage(path, id: "a", at: date("2026-10-27T10:00:00Z"), cost: 0.5)
        insertMessage(path, id: "b", at: date("2026-10-05T10:00:00Z"), cost: 1.25)
        insertMessage(path, id: "c", at: date("2026-09-30T10:00:00Z"), cost: 5)
        insertMessage(path, id: "d", at: date("2026-10-27T11:00:00Z"), cost: 9, provider: "openrouter")

        let ledger = AnthropicSpendLedger()
        let spend = ledger.update(now: now, calendar: calendar, path: path)
        let full = OpenCodeDB.anthropicSpend(now: now, calendar: calendar, path: path)
        XCTAssertEqual(spend, full)
        XCTAssertEqual(spend?.monthToDate ?? -1, 1.75, accuracy: 1e-9)
    }

    func testLedgerPicksUpNewMessagesAndLateCompletions() {
        let path = makeDatabase(); defer { try? FileManager.default.removeItem(atPath: path) }
        let ledger = AnthropicSpendLedger()
        let t0 = date("2026-10-27T12:00:00Z")

        insertMessage(path, id: "old", at: date("2026-10-10T09:00:00Z"), cost: 1)
        insertMessage(path, id: "streaming", at: t0.addingTimeInterval(-60), cost: nil)
        XCTAssertEqual(ledger.update(now: t0, calendar: calendar, path: path)?.monthToDate ?? -1, 1, accuracy: 1e-9)

        // The streaming message finishes; a new one arrives.
        insertMessage(path, id: "streaming", at: t0.addingTimeInterval(-60), cost: 0.25)
        insertMessage(path, id: "fresh", at: t0.addingTimeInterval(30), cost: 0.5)
        let later = t0.addingTimeInterval(120)
        let spend = ledger.update(now: later, calendar: calendar, path: path)
        XCTAssertEqual(spend?.monthToDate ?? -1, 1.75, accuracy: 1e-9)
        XCTAssertEqual(spend?.messages, 3)
        XCTAssertEqual(spend, OpenCodeDB.anthropicSpend(now: later, calendar: calendar, path: path))
    }

    func testLedgerDoesNotDoubleCountOverlappingScans() {
        let path = makeDatabase(); defer { try? FileManager.default.removeItem(atPath: path) }
        let ledger = AnthropicSpendLedger()
        let now = date("2026-10-27T12:00:00Z")
        insertMessage(path, id: "a", at: now.addingTimeInterval(-10), cost: 2)
        _ = ledger.update(now: now, calendar: calendar, path: path)
        let again = ledger.update(now: now.addingTimeInterval(60), calendar: calendar, path: path)
        XCTAssertEqual(again?.monthToDate ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(again?.messages, 1)
    }

    func testLedgerStartsOverInANewMonth() {
        let path = makeDatabase(); defer { try? FileManager.default.removeItem(atPath: path) }
        let ledger = AnthropicSpendLedger()
        insertMessage(path, id: "a", at: date("2026-10-31T23:00:00Z"), cost: 3)
        XCTAssertEqual(ledger.update(now: date("2026-10-31T23:30:00Z"), calendar: calendar, path: path)?.monthToDate ?? -1,
                       3, accuracy: 1e-9)
        XCTAssertEqual(ledger.update(now: date("2026-11-01T00:30:00Z"), calendar: calendar, path: path)?.monthToDate ?? -1,
                       0, accuracy: 1e-9)
    }

    func testLedgerReturnsNilForAMissingDatabase() {
        XCTAssertNil(AnthropicSpendLedger().update(path: "/nonexistent/x.db"))
    }

    // MARK: - OpenCode session reader

    private func addSession(_ path: String, id: String, updated: Date, message: String) {
        exec(path, """
        insert or replace into session_v2 values ('\(id)', 'Title \(id)', '/tmp/proj', \(ms(updated)), null, null, null);
        insert or replace into session_message values
          ('m-\(id)', '\(id)', 'assistant', 1, \(ms(updated)), 0, '\(message)');
        """)
    }

    func testReaderSkipsQueriesWhileTheDatabaseIsUnchanged() {
        let path = makeDatabase(); defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date()
        addSession(path, id: "s1", updated: now, message: #"{"time":{},"content":[{"type":"reasoning"}]}"#)

        let reader = OpenCodeSessionReader(path: path)
        XCTAssertEqual(reader.sessions(now: now).first?.state, .thinking)
        XCTAssertEqual(reader.queries, 1)
        for _ in 0..<5 { _ = reader.sessions(now: now) }
        XCTAssertEqual(reader.queries, 1, "unchanged data_version must not re-run the queries")

        addSession(path, id: "s1", updated: now.addingTimeInterval(1),
                   message: #"{"time":{"completed":1},"content":[]}"#)
        XCTAssertEqual(reader.sessions(now: now).first?.state, .done)
        XCTAssertEqual(reader.queries, 2)
    }

    func testAbandonedSessionStopsCountingAsWorkingWithoutNewQueries() {
        let path = makeDatabase(); defer { try? FileManager.default.removeItem(atPath: path) }
        let start = Date()
        addSession(path, id: "s1", updated: start, message: #"{"time":{},"content":[{"type":"reasoning"}]}"#)
        let reader = OpenCodeSessionReader(path: path)
        XCTAssertTrue(reader.sessions(now: start).first?.state.isActive ?? false)
        XCTAssertEqual(reader.sessions(now: start.addingTimeInterval(16 * 60)).first?.state, .done)
        XCTAssertEqual(reader.queries, 1)
    }

    func testReaderSurvivesAMissingOrEmptyDatabase() {
        XCTAssertTrue(OpenCodeSessionReader(path: "/nonexistent/x.db").sessions().isEmpty)
        let path = NSTemporaryDirectory() + "notchstats-garbage-\(UUID().uuidString).db"
        try? Data("not a database".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(OpenCodeSessionReader(path: path).sessions().isEmpty)
    }

    func testReaderKeepsRowsWhileAWriterHoldsTheDatabase() {
        let path = makeDatabase(); defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date()
        addSession(path, id: "s1", updated: now, message: #"{"time":{},"content":[{"type":"reasoning"}]}"#)
        let reader = OpenCodeSessionReader(path: path)
        XCTAssertEqual(reader.sessions(now: now).count, 1)

        // An exclusive writer in the middle of a transaction.
        var writer: OpaquePointer?
        sqlite3_open(path, &writer)
        sqlite3_exec(writer, "begin exclusive; insert into session_message values ('x','s1','assistant',2,1,0,'{}');",
                     nil, nil, nil)
        XCTAssertEqual(reader.sessions(now: now).count, 1, "a row must not vanish while the database is busy")
        sqlite3_exec(writer, "rollback", nil, nil, nil)
        sqlite3_close(writer)
    }

    // MARK: - Codex transcript cache

    func testUnchangedTranscriptIsNotParsedAgain() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "rollout-\(UUID().uuidString).jsonl")
        let lines = [
            #"{"payload":{"type":"session_meta","cwd":"/tmp/demo","model":"gpt-x","message":"fix it"}}"#,
            #"{"payload":{"type":"task_started"}}"#,
            #"{"payload":{"type":"function_call","name":"shell"}}"#
        ].joined(separator: "\n") + "\n"
        try lines.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = CodexSessionReader.Cache()
        let first = CodexSessionReader.parse(url: url, cache: cache)
        XCTAssertEqual(first?.state, .tool("shell"))
        XCTAssertEqual(first?.project, "demo")
        for _ in 0..<5 { _ = CodexSessionReader.parse(url: url, cache: cache) }
        XCTAssertEqual(cache.parses, 1)

        try (lines + #"{"payload":{"type":"task_complete"}}"# + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexSessionReader.parse(url: url, cache: cache)?.state, .done)
        XCTAssertEqual(cache.parses, 2)
    }

    func testStaleUnfinishedTranscriptFlipsToDoneEvenWhenCached() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "rollout-\(UUID().uuidString).jsonl")
        try #"{"payload":{"type":"reasoning"}}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = CodexSessionReader.Cache()
        let now = Date()
        XCTAssertEqual(CodexSessionReader.parse(url: url, now: now, cache: cache)?.state, .thinking)
        XCTAssertEqual(CodexSessionReader.parse(url: url, now: now.addingTimeInterval(400), cache: cache)?.state, .done)
        XCTAssertEqual(cache.parses, 1)
    }

    func testMalformedTranscriptLinesAreIgnored() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "rollout-\(UUID().uuidString).jsonl")
        try "{{{ nope\n\u{0}\u{1}\n{\"payload\":{\"type\":\"task_started\"}}\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(CodexSessionReader.parse(url: url)?.state, .thinking)
    }
}
