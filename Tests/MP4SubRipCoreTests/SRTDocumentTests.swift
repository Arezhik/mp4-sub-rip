import XCTest
@testable import MP4SubRipCore

final class SRTDocumentTests: XCTestCase {
    func testOneCueUsesACommaAndMillisecondPadding() {
        let text = SRTDocument.render([
            SubtitleCue(startMilliseconds: 1500, endMilliseconds: 2750, text: "Hello")
        ])
        XCTAssertEqual(text, "1\n00:00:01,500 --> 00:00:02,750\nHello\n")
    }

    func testCuesAreNumberedAndSeparatedByABlankLine() {
        let text = SRTDocument.render([
            SubtitleCue(startMilliseconds: 0, endMilliseconds: 1000, text: "One"),
            SubtitleCue(startMilliseconds: 2000, endMilliseconds: 3000, text: "Two\nlines")
        ])
        XCTAssertEqual(
            text,
            "1\n00:00:00,000 --> 00:00:01,000\nOne\n\n2\n00:00:02,000 --> 00:00:03,000\nTwo\nlines\n"
        )
    }

    func testHoursGrowPastNinetyNine() {
        XCTAssertEqual(SRTDocument.stamp(100 * 3_600_000 + 5), "100:00:00,005")
    }

    func testNegativeStartAndBackwardsEndAreClamped() {
        let text = SRTDocument.render([
            SubtitleCue(startMilliseconds: -20, endMilliseconds: 0, text: "Hi")
        ])
        XCTAssertEqual(text, "1\n00:00:00,000 --> 00:00:00,001\nHi\n")
    }

    func testBlankLinesInsideACueAreCollapsed() {
        XCTAssertEqual(SRTDocument.normalize("a\r\n\r\nb\n"), "a\nb")
    }

    func testEmptyInputRendersNothing() {
        XCTAssertEqual(SRTDocument.render([]), "")
        XCTAssertEqual(
            SRTDocument.render([SubtitleCue(startMilliseconds: 0, endMilliseconds: 1, text: "  \n")]),
            ""
        )
    }
}
