import XCTest
@testable import NotchStats

@MainActor
final class PanelSizingTests: XCTestCase {

    private func height(_ rows: Int, rowHeight: CGFloat? = nil) -> CGFloat {
        AppStore.expandedHeight(barHeight: 32, rows: rows, rowHeight: rowHeight ?? AppStore.rowHeight)
    }

    func testPanelHeightIsExactlyItsContent() {
        // Each extra row adds one row plus one gap, and nothing else.
        XCTAssertEqual(height(4) - height(3), AppStore.rowHeight + AppStore.rowSpacing)
        XCTAssertEqual(height(5) - height(3), 2 * (AppStore.rowHeight + AppStore.rowSpacing))
    }

    func testPanelHeightDependsOnlyOnTheRowCount() {
        // A refresh that changes values or window counts per row cannot resize it.
        XCTAssertEqual(height(5), height(5))
    }

    func testSessionRowsAreShorterThanUsageRows() {
        XCTAssertLessThan(height(4, rowHeight: AppStore.sessionRowHeight), height(4))
    }

    func testPanelNeverCollapsesBelowOneRow() {
        XCTAssertEqual(height(0), height(1))
    }

    func testSixRowsStillFitTheWindow() {
        // The island window is 620 pt tall.
        XCTAssertLessThanOrEqual(height(6), 620)
    }

    func testSingleWindowSpansTwoSlotsWithoutLeavingAGap() {
        XCTAssertEqual(UsageGrid.width(forFigures: 1), UsageGrid.span)
        XCTAssertEqual(UsageGrid.width(forFigures: 2), UsageGrid.slot)
        XCTAssertEqual(UsageGrid.width(forFigures: 3), UsageGrid.slot)
        XCTAssertEqual(UsageGrid.span, UsageGrid.slot * 2 + UsageGrid.gutter)
        XCTAssertEqual(UsageGrid.total, UsageGrid.slot * 3 + UsageGrid.gutter * 2)
    }

    func testSingleWindowPlanNoteIsNotDuplicatedInWindowDetail() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(3600)

        let codexWithReset = ProviderUsage(
            id: CodexProvider.id, name: "Codex", accentHex: CodexProvider.accent, order: 0,
            windows: [UsageWindow(id: "5h", label: "5h", percent: 0.25, resetsAt: reset)],
            note: "Plus plan", error: nil)
        XCTAssertEqual(ProviderRow.planLabel(for: codexWithReset), "Plus plan")
        XCTAssertEqual(ProviderRow.detail(for: codexWithReset.windows[0], in: codexWithReset, now: now),
                       .reset("1h 0m"))

        let codexWithoutReset = ProviderUsage(
            id: CodexProvider.id, name: "Codex", accentHex: CodexProvider.accent, order: 0,
            windows: [UsageWindow(id: "5h", label: "5h", percent: 0.25, resetsAt: nil)],
            note: "Plus plan", error: nil)
        XCTAssertEqual(ProviderRow.planLabel(for: codexWithoutReset), "Plus plan")
        XCTAssertNil(ProviderRow.detail(for: codexWithoutReset.windows[0], in: codexWithoutReset, now: now))

        // OpenRouter's dollar balance still belongs in the single-window detail slot.
        let openRouter = ProviderUsage(
            id: OpenRouterProvider.id, name: "OpenRouter", accentHex: OpenRouterProvider.accent, order: 4,
            windows: [UsageWindow(id: "credits", label: "Credits", percent: 0.5, resetsAt: nil)],
            note: "$3.26", error: nil)
        XCTAssertNil(ProviderRow.planLabel(for: openRouter))
        XCTAssertEqual(ProviderRow.detail(for: openRouter.windows[0], in: openRouter, now: now),
                       .text("$3.26"))
    }

    func testBarPartitionHandlesSingleLeftEntryCleanly() {
        let codex = BarEntry(
            provider: ProviderUsage(
                id: CodexProvider.id, name: "Codex", accentHex: CodexProvider.accent, order: 0,
                windows: [UsageWindow(id: "5h", label: "5h", percent: 0.2, resetsAt: nil)],
                note: "Plus plan", error: nil),
            live: false)
        let claude = BarEntry(
            provider: ProviderUsage(
                id: ClaudeProvider.id, name: "Claude", accentHex: ClaudeProvider.accent, order: 1,
                windows: [UsageWindow(id: "5h", label: "5h", percent: 0.1, resetsAt: nil)],
                note: "Max", error: nil),
            live: false)

        let ears = BarLayout.partition([codex, claude])
        XCTAssertEqual(ears.left.map(\.id), [CodexProvider.id])
        XCTAssertEqual(ears.right.map(\.id), [ClaudeProvider.id])

        let empty = BarLayout.partition([])
        XCTAssertTrue(empty.left.isEmpty)
        XCTAssertTrue(empty.right.isEmpty)
    }
}
