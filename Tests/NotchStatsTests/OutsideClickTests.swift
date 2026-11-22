import XCTest
@testable import NotchStats

final class OutsideClickTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let size = CGSize(width: 400, height: 200)

    func testNotchedIslandHugsTheTopEdgeCentred() {
        let frame = IslandGeometry.islandFrame(in: screen, hasNotch: true, size: size)
        XCTAssertEqual(frame.size, size)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.maxY, screen.maxY)
    }

    func testPillSitsSixPointsBelowTheTopEdge() {
        let frame = IslandGeometry.islandFrame(in: screen, hasNotch: false, size: size)
        XCTAssertEqual(frame.size, size)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.maxY, screen.maxY - 6)
    }

    func testSecondScreenWithOffsetOriginIsStillCentredOnIt() {
        let second = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        let frame = IslandGeometry.islandFrame(in: second, hasNotch: false, size: size)
        XCTAssertEqual(frame.midX, second.midX)
        XCTAssertEqual(frame.maxY, second.maxY - 6)
    }

    func testClickWithinPaddingIsOnTheIslandAndBeyondIsNot() {
        let frame = IslandGeometry.islandFrame(in: screen, hasNotch: true, size: size)
        let near = CGPoint(x: frame.maxX + 5, y: frame.midY)
        let far = CGPoint(x: frame.maxX + 11, y: frame.midY)
        let below = CGPoint(x: frame.midX, y: frame.minY - 11)
        XCTAssertTrue(IslandGeometry.isOnAnyIsland(near, islandFrames: [frame]))
        XCTAssertFalse(IslandGeometry.isOnAnyIsland(far, islandFrames: [frame]))
        XCTAssertFalse(IslandGeometry.isOnAnyIsland(below, islandFrames: [frame]))
    }

    func testClickOnAnotherDisplaysIslandCountsAsInside() {
        let first = IslandGeometry.islandFrame(in: screen, hasNotch: true, size: size)
        let secondScreen = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let second = IslandGeometry.islandFrame(in: secondScreen, hasNotch: false,
                                                size: CGSize(width: 252, height: 28))
        let point = CGPoint(x: second.midX, y: second.midY)
        XCTAssertFalse(IslandGeometry.isOnAnyIsland(point, islandFrames: [first]))
        XCTAssertTrue(IslandGeometry.isOnAnyIsland(point, islandFrames: [first, second]))
    }

    func testEmptyIslandNeverCatchesClicks() {
        let frame = IslandGeometry.islandFrame(in: screen, hasNotch: true, size: .zero)
        XCTAssertFalse(IslandGeometry.isOnAnyIsland(CGPoint(x: frame.midX, y: frame.midY),
                                                    islandFrames: [frame]))
    }
}
