import XCTest
@testable import NotchStats

final class SessionStateTests: XCTestCase {

    private func message(completed: Bool, content: [[String: Any]]) -> [String: Any] {
        var time: [String: Any] = ["created": 1, "streamed": 2]
        if completed { time["completed"] = 3 }
        return ["time": time, "content": content]
    }

    func testRunningToolIsReported() {
        let msg = message(completed: false, content: [
            ["type": "reasoning"],
            ["type": "tool", "name": "shell", "state": ["status": "running"]]
        ])
        XCTAssertEqual(OpenCodeSessionReader.state(kind: "assistant", message: msg, compacting: false),
                       .tool("shell"))
    }

    func testCompletedToolMeansThinking() {
        let msg = message(completed: false, content: [
            ["type": "tool", "name": "read", "state": ["status": "completed"]]
        ])
        XCTAssertEqual(OpenCodeSessionReader.state(kind: "assistant", message: msg, compacting: false),
                       .thinking)
    }

    func testReasoningOnlyMeansThinking() {
        let msg = message(completed: false, content: [["type": "reasoning"]])
        XCTAssertEqual(OpenCodeSessionReader.state(kind: "assistant", message: msg, compacting: false),
                       .thinking)
    }

    func testTextOnlyMeansResponding() {
        let msg = message(completed: false, content: [["type": "text", "text": "hi"]])
        XCTAssertEqual(OpenCodeSessionReader.state(kind: "assistant", message: msg, compacting: false),
                       .responding)
    }

    func testCompletedMessageIsDone() {
        let msg = message(completed: true, content: [["type": "text", "text": "all done"]])
        XCTAssertEqual(OpenCodeSessionReader.state(kind: "assistant", message: msg, compacting: false),
                       .done)
    }

    func testPendingUserPromptIsThinking() {
        let msg = message(completed: true, content: [])
        XCTAssertEqual(OpenCodeSessionReader.state(kind: "user", message: msg, compacting: false),
                       .thinking)
    }

    func testCompactingWins() {
        let msg = message(completed: false, content: [["type": "text"]])
        XCTAssertEqual(OpenCodeSessionReader.state(kind: "assistant", message: msg, compacting: true),
                       .compacting)
    }

    func testLegacyToolKeyStillWorks() {
        let msg = message(completed: false, content: [
            ["type": "tool", "tool": "bash", "state": ["status": "running"]]
        ])
        XCTAssertEqual(OpenCodeSessionReader.state(kind: "assistant", message: msg, compacting: false),
                       .tool("bash"))
    }

    func testNoMessageIsDone() {
        XCTAssertEqual(OpenCodeSessionReader.state(kind: nil, message: nil, compacting: false), .done)
    }

    func testLiveThreshold() {
        let now = Date()
        let hot = AgentSession(id: "1", agent: .codex, title: "t", project: "p",
                               state: .thinking, model: nil, updatedAt: now.addingTimeInterval(-10))
        let stale = AgentSession(id: "2", agent: .codex, title: "t", project: "p",
                                 state: .thinking, model: nil, updatedAt: now.addingTimeInterval(-600))
        let finished = AgentSession(id: "3", agent: .codex, title: "t", project: "p",
                                    state: .done, model: nil, updatedAt: now)
        XCTAssertTrue(hot.isLive(now: now))
        XCTAssertFalse(stale.isLive(now: now))
        XCTAssertFalse(finished.isLive(now: now))
    }
}
