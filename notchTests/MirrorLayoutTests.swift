import CoreGraphics
import XCTest
@testable import notch

final class MirrorLayoutTests: XCTestCase {
    private let base = CGSize(width: 720, height: 270)
    private let content: CGFloat = 200

    private func height(_ aspect: CGFloat?, max: CGFloat = 2000) -> CGFloat {
        MirrorLayout.expandedHeight(base: base, contentHeight: content, railThickness: 54, aspect: aspect, maxHeight: max)
    }

    private func expected(_ aspect: CGFloat) -> CGFloat {
        base.height + MirrorLayout.previewWidth(destinationWidth: base.width, railThickness: 54) / aspect + MirrorLayout.paneHeaderHeight - content
    }

    func testSixteenByNine() { XCTAssertEqual(height(16.0 / 9.0), expected(16.0 / 9.0), accuracy: 0.001) }
    func testFourByThreeIsTaller() {
        XCTAssertEqual(height(4.0 / 3.0), expected(4.0 / 3.0), accuracy: 0.001)
        XCTAssertGreaterThan(height(4.0 / 3.0), height(16.0 / 9.0))
    }
    func testUnknownAspectFallsBackToSixteenByTen() {
        XCTAssertEqual(height(nil), expected(1.6), accuracy: 0.001)
        XCTAssertEqual(height(0), height(nil))
    }
    func testClampsToScreen() { XCTAssertEqual(height(4.0 / 3.0, max: 400), 400) }
    func testNeverShrinksBelowBase() {
        XCTAssertEqual(height(100), base.height)
        XCTAssertEqual(height(1.6, max: 100), base.height)
    }
}
