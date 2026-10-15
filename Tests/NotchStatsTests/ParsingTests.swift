import XCTest
import SQLite3
@testable import NotchStats

final class ParsingTests: XCTestCase {

    // MARK: - Codex

    func testCodexParsesWindows() throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": { "used_percent": 87, "reset_at": 1792083607, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 29, "reset_at": 1792652243, "limit_window_seconds": 604800 }
          }
        }
        """
        let usage = CodexProvider.parse(Data(json.utf8))

        XCTAssertNil(usage.error)
        XCTAssertEqual(usage.id, "codex")
        XCTAssertEqual(usage.note, "Plus plan")
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(usage.windows[0].label, "5h")
        XCTAssertEqual(usage.windows[0].percent, 0.87, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[1].label, "Weekly")
        XCTAssertEqual(usage.windows[1].percent, 0.29, accuracy: 0.0001)
        XCTAssertNotNil(usage.windows[0].resetsAt)
    }

    func testCodexHandlesMissingWindows() {
        let usage = CodexProvider.parse(Data("""
        { "plan_type": "free", "rate_limit": {} }
        """.utf8))
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertEqual(usage.error, "No data")
    }

    func testCodexClampsOutOfRangePercent() {
        let usage = CodexProvider.parse(Data("""
        { "rate_limit": { "primary_window": { "used_percent": 250 } } }
        """.utf8))
        XCTAssertEqual(usage.windows.first?.percent, 1.0)
    }

    func testCodexRejectsGarbage() {
        XCTAssertEqual(CodexProvider.parse(Data("not json".utf8)).error, "Parse error")
    }

    // MARK: - OpenCode Go

    func testOpenCodeGoParsesWindows() throws {
        let json = """
        {
          "usage": {
            "rolling": { "status": "ok", "percent": 0, "resetsAt": "2026-10-15T17:49:33.000Z" },
            "weekly":  { "status": "ok", "percent": 22, "resetsAt": "2026-10-19T00:00:00.000Z" },
            "monthly": { "status": "ok", "percent": 68, "resetsAt": "2026-10-25T10:32:52.000Z" }
          }
        }
        """
        let usage = OpenCodeGoProvider.parse(Data(json.utf8))

        XCTAssertNil(usage.error)
        XCTAssertNil(usage.note)
        XCTAssertEqual(usage.windows.map(\.label), ["5h", "Weekly", "Monthly"])
        XCTAssertEqual(usage.windows[0].percent, 0.00, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[1].percent, 0.22, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[2].percent, 0.68, accuracy: 0.0001)
        XCTAssertNotNil(usage.windows[0].resetsAt, "fractional-second ISO-8601 should parse")
    }

    func testOpenCodeGoFlagsRateLimited() {
        let json = """
        {
          "usage": {
            "rolling": { "status": "rate-limited", "percent": 100, "resetsAt": "2026-10-15T17:49:33.000Z" },
            "weekly":  { "status": "ok", "percent": 62, "resetsAt": "2026-10-19T00:00:00.000Z" }
          }
        }
        """
        let usage = OpenCodeGoProvider.parse(Data(json.utf8))
        XCTAssertEqual(usage.note, "Rate limited")
        XCTAssertEqual(usage.windows.first?.percent, 1.0)
    }

    func testOpenCodeGoRejectsGarbage() {
        XCTAssertEqual(OpenCodeGoProvider.parse(Data("{}".utf8)).error, "Parse error")
    }

    // MARK: - OpenRouter

    func testOpenRouterParsesCredits() {
        let json = """
        { "data": { "total_credits": 30, "total_usage": 26.470964356 } }
        """
        let usage = OpenRouterProvider.parse(Data(json.utf8))

        XCTAssertNil(usage.error)
        XCTAssertEqual(usage.note, "$3.53")
        XCTAssertEqual(usage.windows.first?.percent ?? 0, 0.882, accuracy: 0.01)
        XCTAssertEqual(usage.windows.first?.remaining ?? 0, 0.118, accuracy: 0.01)
    }

    func testRemainingIsInverseOfUsed() {
        let exhausted = UsageWindow(id: "a", label: "5h", percent: 1.0, resetsAt: nil)
        XCTAssertEqual(exhausted.remaining, 0.0)
        let half = UsageWindow(id: "b", label: "5h", percent: 0.25, resetsAt: nil)
        XCTAssertEqual(half.remaining, 0.75, accuracy: 0.0001)
        // Out-of-range input must not produce a negative or >1 remainder.
        let over = UsageWindow(id: "c", label: "5h", percent: 1.5, resetsAt: nil)
        XCTAssertEqual(over.remaining, 0.0)
    }

    func testOpenRouterRejectsGarbage() {
        XCTAssertEqual(OpenRouterProvider.parse(Data("[]".utf8)).error, "Parse error")
    }

    // MARK: - Formatting

    func testCountdownFormatting() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(3 * 3600 + 27 * 60), now: now), "3h 27m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(2 * 86400 + 5 * 3600), now: now), "2d 5h")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(600), now: now), "10m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(-5), now: now), "now")
        XCTAssertNil(Format.countdown(to: nil, now: now))
    }

    // MARK: - OpenCode credential store

    func testCredentialLookupPrefersExplicitIntegrationAndParsesJSON() throws {
        let path = NSTemporaryDirectory() + "notchstats-test-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        sqlite3_exec(db, """
        create table credential (
          id text primary key, integration_id text, label text not null, value text not null,
          connector_id text, method_id text, active integer, time_created integer, time_updated integer
        );
        """, nil, nil, nil)

        // Legacy "opencode" row is *newer*, but "opencode-go" must win.
        let insert = """
        insert into credential values ('2','opencode','Personal','{"type":"oauth","access":"LEGACY"}',null,null,1,0,9999);
        insert into credential values ('1','opencode-go','Go','{"type":"oauth","access":"GO"}',null,null,1,0,1);
        """
        sqlite3_exec(db, insert, nil, nil, nil)
        sqlite3_close(db)

        let credential = OpenCodeDB.credentialJSON(integrationIDs: ["opencode-go", "opencode"], path: path)
        XCTAssertEqual(credential?["access"] as? String, "GO")
    }

    func testCredentialLookupReturnsNilForMissingDatabase() {
        XCTAssertNil(OpenCodeDB.credentialJSON(integrationIDs: ["opencode"], path: "/nonexistent/nope.db"))
    }
}
