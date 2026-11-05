import XCTest
import SQLite3
@testable import NotchStats

final class AnthropicAPITests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Creates a temporary OpenCode-shaped database. Returns its path.
    private func database(messages: [(type: String, createdAt: Date, data: String)] = [],
                          credentials: [(integrationID: String, active: Int, value: String)] = []) -> String {
        let path = NSTemporaryDirectory() + "notchstats-anthropic-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        sqlite3_exec(db, """
        create table session_message (
          id text primary key,
          session_id text not null,
          type text not null,
          seq integer not null,
          time_created integer not null,
          time_updated integer not null,
          data text not null
        );
        create table credential (
          id text primary key, integration_id text, label text not null, value text not null,
          connector_id text, method_id text, active integer, time_created integer, time_updated integer
        );
        """, nil, nil, nil)

        for (index, message) in messages.enumerated() {
            let data = message.data.replacingOccurrences(of: "'", with: "''")
            sqlite3_exec(db, """
            insert into session_message values
              ('m\(index)', 's1', '\(message.type)', \(index), \(milliseconds(message.createdAt)), 0, '\(data)');
            """, nil, nil, nil)
        }

        for (index, credential) in credentials.enumerated() {
            let value = credential.value.replacingOccurrences(of: "'", with: "''")
            sqlite3_exec(db, """
            insert into credential values
              ('c\(index)', '\(credential.integrationID)', 'Test', '\(value)', null, null,
               \(credential.active), 0, \(index));
            """, nil, nil, nil)
        }

        return path
    }

    private func assistant(provider: String, cost: Double?) -> String {
        let costField = cost.map { ",\"cost\":\($0)" } ?? ""
        return """
        {"model":{"id":"claude-opus-5-5","providerID":"\(provider)","variant":"high"}\(costField)}
        """
    }

    // MARK: - Spend ledger

    func testSpendSumsOnlyAnthropicAssistantMessagesThisMonth() {
        let now = date("2026-10-27T12:00:00Z")
        let path = database(messages: [
            ("assistant", date("2026-10-27T10:00:00Z"), assistant(provider: "anthropic", cost: 0.50)),
            ("assistant", date("2026-10-05T10:00:00Z"), assistant(provider: "anthropic", cost: 1.25)),
            ("assistant", date("2026-09-30T10:00:00Z"), assistant(provider: "anthropic", cost: 5.00)),
            ("assistant", date("2026-10-27T11:00:00Z"), assistant(provider: "openrouter", cost: 9.99)),
            ("user", date("2026-10-27T09:00:00Z"), assistant(provider: "anthropic", cost: 3.00)),
            // A message still streaming has no cost yet and must not count.
            ("assistant", date("2026-10-27T11:30:00Z"), assistant(provider: "anthropic", cost: nil))
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let spend = OpenCodeDB.anthropicSpend(now: now, calendar: calendar, path: path)
        XCTAssertEqual(spend?.monthToDate ?? -1, 1.75, accuracy: 0.0001)
        XCTAssertEqual(spend?.today ?? -1, 0.50, accuracy: 0.0001)
        XCTAssertEqual(spend?.messages, 2)
    }

    func testSpendReturnsZeroWhenNothingWasUsed() {
        let path = database()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let spend = OpenCodeDB.anthropicSpend(now: date("2026-10-27T12:00:00Z"),
                                              calendar: calendar, path: path)
        XCTAssertEqual(spend, OpenCodeDB.AnthropicSpend(monthToDate: 0, today: 0, messages: 0))
    }

    func testSpendReturnsNilForMissingDatabase() {
        XCTAssertNil(OpenCodeDB.anthropicSpend(path: "/nonexistent/nope.db"))
    }

    // MARK: - Credential detection

    func testAnthropicAPIKeyIsDetected() {
        let path = database(credentials: [
            ("anthropic", 1, #"{"type":"key","key":"sk-ant-usr-abc"}"#)
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(OpenCodeDB.hasAnthropicAPIKey(path: path))
    }

    func testAnthropicOAuthIsNotTreatedAsAPIKey() {
        let path = database(credentials: [
            ("anthropic", 1, #"{"type":"oauth","access":"sk-ant-oat-abc","refresh":"rt"}"#)
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(OpenCodeDB.hasAnthropicAPIKey(path: path))
    }

    func testInactiveOrMissingAnthropicCredentialIsNotDetected() {
        let inactive = database(credentials: [
            ("anthropic", 0, #"{"type":"key","key":"sk-ant-usr-abc"}"#)
        ])
        defer { try? FileManager.default.removeItem(atPath: inactive) }
        XCTAssertFalse(OpenCodeDB.hasAnthropicAPIKey(path: inactive))

        let missing = database()
        defer { try? FileManager.default.removeItem(atPath: missing) }
        XCTAssertFalse(OpenCodeDB.hasAnthropicAPIKey(path: missing))
    }

    // MARK: - Presentation

    func testNoteShowsMonthAndToday() {
        let spend = OpenCodeDB.AnthropicSpend(monthToDate: 4.1646, today: 1.2, messages: 3)
        XCTAssertEqual(AnthropicAPIProvider.note(spend), "$4.16 spent this month · $1.20 today")
    }

    func testNoteOmitsTodayWhenNothingWasSpent() {
        let spend = OpenCodeDB.AnthropicSpend(monthToDate: 0, today: 0, messages: 0)
        XCTAssertEqual(AnthropicAPIProvider.note(spend), "$0.00 spent this month")
    }

    func testSubCentSpendStaysVisible() {
        XCTAssertEqual(AnthropicAPIProvider.money(0.003), "<$0.01")
        XCTAssertEqual(AnthropicAPIProvider.money(0.01), "$0.01")
    }

    func testUsageHasSpendButNoQuotaWindow() {
        let usage = AnthropicAPIProvider.usage(
            OpenCodeDB.AnthropicSpend(monthToDate: 12.5, today: 0, messages: 8))
        XCTAssertNil(usage.error)
        XCTAssertEqual(usage.name, "Anthropic API")
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertNil(usage.headline)
        XCTAssertEqual(usage.note, "$12.50 spent this month")
    }
}
