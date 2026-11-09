import XCTest
@testable import MP4SubRipCore

final class ClosedCaptionSpikeTests: XCTestCase {
    func testShippingWriterStaysFFmpeg() {
        XCTAssertEqual(ClosedCaptionSpike.writer, .ffmpeg)
    }

    func testIdenticalCuesMatchAndDoNotSwitchTheWriter() {
        let native = [
            snap("Hello there", start: 1_701, end: 4_000),
            snap("<i>Real italics</i>", start: 4_500, end: 6_000, rollUp: true)
        ]
        let comparison = ClosedCaptionSpike.compare(
            trackID: 3,
            nativeGroupCount: 2,
            nativeCues: native,
            reference: cues(native),
            validationSkips: []
        )
        XCTAssertTrue(comparison.matchesCleanedReference)
        XCTAssertFalse(comparison.referenceIsJeannieShape)
        XCTAssertEqual(comparison.textMismatchCount, 0)
        XCTAssertEqual(comparison.timingMismatchCount, 0)
        XCTAssertEqual(comparison.italicsMismatchCount, 0)
        XCTAssertEqual(comparison.rollUpMismatchCount, 0)
        XCTAssertEqual(ClosedCaptionSpike.writer, .ffmpeg)

        let lines = ClosedCaptionSpike.logLines(comparison)
        XCTAssertTrue(lines[0].contains("groups 2"))
        XCTAssertTrue(lines[0].contains("native cues 2"))
        XCTAssertTrue(lines[0].contains("ffmpeg cues 2"))
        XCTAssertTrue(lines[0].contains("validation skips 0"))
        XCTAssertTrue(lines[0].contains("match yes"))
        XCTAssertTrue(lines[0].contains("Jeannie shape no"))
        XCTAssertTrue(lines[0].contains("shipping ffmpeg"))
        XCTAssertTrue(lines[0].contains("native matches this file's cleaned ffmpeg SRT; shipping stays ffmpeg"))
        XCTAssertFalse(lines[0].contains("Hello"))
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].contains("00:00:01,701 --> 00:00:04,000"))
        XCTAssertTrue(lines[1].contains("roll-up no: Hello there"))
        XCTAssertTrue(lines[2].contains("roll-up yes: <i>Real italics</i>"))
    }

    func testJeannieShapeMatchStillKeepsFFmpeg() {
        let native = jeannie()
        let comparison = ClosedCaptionSpike.compare(
            trackID: 1,
            nativeGroupCount: native.count,
            nativeCues: native,
            reference: cues(native),
            validationSkips: []
        )
        XCTAssertTrue(comparison.matchesCleanedReference)
        XCTAssertTrue(comparison.referenceIsJeannieShape)
        XCTAssertEqual(comparison.referenceCues.count, 633)
        XCTAssertEqual(comparison.referenceCues.first?.startMilliseconds, 1_701)
        XCTAssertEqual(comparison.referenceCues.last?.endMilliseconds, 1_490_269)
        let summary = ClosedCaptionSpike.logLines(comparison)[0]
        XCTAssertTrue(summary.contains("ffmpeg first 00:00:01,701 last 00:24:50,269"))
        XCTAssertTrue(summary.contains("native matches the cleaned Jeannie SRT; shipping stays ffmpeg until that is accepted"))
        XCTAssertTrue(summary.contains("shipping ffmpeg"))
        XCTAssertEqual(ClosedCaptionSpike.writer, .ffmpeg)
        XCTAssertEqual(ClosedCaptionSpike.logLines(comparison).count, 6)
    }

    func testJeannieShapeRequiresCountAndBothEnds() {
        var short = jeannie()
        short.removeLast()
        XCTAssertFalse(ClosedCaptionSpike.isJeannieShape(short))

        var late = jeannie()
        late[0].startMilliseconds = 1_702
        XCTAssertFalse(ClosedCaptionSpike.isJeannieShape(late))

        var earlyEnd = jeannie()
        earlyEnd[earlyEnd.count - 1].endMilliseconds = 1_490_268
        XCTAssertFalse(ClosedCaptionSpike.isJeannieShape(earlyEnd))
        XCTAssertTrue(ClosedCaptionSpike.isJeannieShape(jeannie()))
    }

    func testTextTimingAndItalicsAreSeparate() {
        let reference = [
            snap("<i>Hi</i>", start: 0, end: 1_000),
            snap("Next", start: 1_000, end: 2_000)
        ]
        let reworded = ClosedCaptionSpike.compare(
            trackID: 1,
            nativeGroupCount: 2,
            nativeCues: [snap("<i>Hello</i>", start: 0, end: 1_000), reference[1]],
            reference: cues(reference),
            validationSkips: []
        )
        XCTAssertEqual(reworded.textMismatchCount, 1)
        XCTAssertEqual(reworded.italicsMismatchCount, 0)
        XCTAssertEqual(reworded.timingMismatchCount, 0)
        XCTAssertFalse(reworded.matchesCleanedReference)

        let plain = ClosedCaptionSpike.compare(
            trackID: 1,
            nativeGroupCount: 2,
            nativeCues: [snap("Hi", start: 0, end: 1_000), reference[1]],
            reference: cues(reference),
            validationSkips: []
        )
        XCTAssertEqual(plain.italicsMismatchCount, 1)
        XCTAssertEqual(plain.textMismatchCount, 1)

        let late = ClosedCaptionSpike.compare(
            trackID: 1,
            nativeGroupCount: 2,
            nativeCues: [snap("<i>Hi</i>", start: 0, end: 1_001), reference[1]],
            reference: cues(reference),
            validationSkips: []
        )
        XCTAssertEqual(late.timingMismatchCount, 1)
        XCTAssertEqual(late.textMismatchCount, 0)
        XCTAssertEqual(late.italicsMismatchCount, 0)
        XCTAssertFalse(late.matchesCleanedReference)
    }

    func testExtraCueCountsItalicsOnlyWhenTagged() {
        let reference = [snap("Hello", start: 0, end: 1_000)]
        let plainExtra = ClosedCaptionSpike.compare(
            trackID: 1,
            nativeGroupCount: 2,
            nativeCues: reference + [snap("Again", start: 1_000, end: 2_000)],
            reference: cues(reference),
            validationSkips: []
        )
        XCTAssertEqual(plainExtra.textMismatchCount, 1)
        XCTAssertEqual(plainExtra.timingMismatchCount, 1)
        XCTAssertEqual(plainExtra.italicsMismatchCount, 0)

        let italicExtra = ClosedCaptionSpike.compare(
            trackID: 1,
            nativeGroupCount: 2,
            nativeCues: reference + [snap("<i>Again</i>", start: 1_000, end: 2_000)],
            reference: cues(reference),
            validationSkips: []
        )
        XCTAssertEqual(italicExtra.italicsMismatchCount, 1)
        XCTAssertFalse(italicExtra.matchesCleanedReference)
    }

    func testRollUpShapeMatchesGrowAndRollAndRejectsACollapsedWindow() {
        let window = [
            snap("Hello", start: 0, end: 1_000, rollUp: true),
            snap("Hello\nthere", start: 1_000, end: 2_000, rollUp: true),
            snap("there\nfriend", start: 2_000, end: 3_000, rollUp: true)
        ]
        XCTAssertEqual(ClosedCaptionSpike.rollUpSteps(window), [.grow, .roll])
        let matched = ClosedCaptionSpike.compare(
            trackID: 1,
            nativeGroupCount: 3,
            nativeCues: window,
            reference: cues(window),
            validationSkips: []
        )
        XCTAssertEqual(matched.rollUpMismatchCount, 0)
        XCTAssertTrue(matched.matchesCleanedReference)

        let collapsed = ClosedCaptionSpike.compare(
            trackID: 1,
            nativeGroupCount: 1,
            nativeCues: [snap("there\nfriend", start: 2_000, end: 3_000, rollUp: true)],
            reference: cues(window),
            validationSkips: []
        )
        XCTAssertGreaterThan(collapsed.rollUpMismatchCount, 0)
        XCTAssertGreaterThan(collapsed.textMismatchCount, 0)
        XCTAssertFalse(collapsed.matchesCleanedReference)

        let held = [
            snap("Hello", start: 0, end: 1_000),
            snap("Hello", start: 1_000, end: 2_000)
        ]
        XCTAssertEqual(ClosedCaptionSpike.rollUpSteps(held), [.hold])
    }

    func testItalicsDoNotChangeTheRollUpLines() {
        let previous = snap("Hello", start: 0, end: 1_000)
        let native = snap("<i>Hello</i>\nthere", start: 1_000, end: 2_000)
        let reference = snap("Hello\nthere", start: 1_000, end: 2_000)
        XCTAssertEqual(ClosedCaptionSpike.plainLines(native.text), ["Hello", "there"])
        XCTAssertEqual(ClosedCaptionSpike.italicMarks("<I>Hi</I>"), "<i></i>")
        let comparison = ClosedCaptionSpike.compare(
            trackID: 1,
            nativeGroupCount: 2,
            nativeCues: [previous, native],
            reference: cues([previous, reference]),
            validationSkips: []
        )
        XCTAssertEqual(comparison.rollUpMismatchCount, 0)
        XCTAssertEqual(comparison.italicsMismatchCount, 1)
        XCTAssertEqual(comparison.textMismatchCount, 1)
    }

    func testValidationSkipsBlockAMatchAndAreSampled() {
        let native = [snap("Hello", start: 0, end: 1_000)]
        let comparison = ClosedCaptionSpike.compare(
            trackID: 7,
            nativeGroupCount: 1,
            nativeCues: native,
            reference: cues(native),
            validationSkips: ["ruby", "ruby", "position", "  "]
        )
        XCTAssertEqual(comparison.validationSkipCount, 4)
        XCTAssertEqual(comparison.validationSkipSamples, ["ruby", "position"])
        XCTAssertFalse(comparison.matchesCleanedReference)
        let lines = ClosedCaptionSpike.logLines(comparison)
        XCTAssertTrue(lines[0].contains("validation skips 4"))
        XCTAssertTrue(lines[0].contains("keep ffmpeg"))
        XCTAssertTrue(lines[1].contains("validation skips 4 (ruby, position)"))
    }

    func testEmptyAdaptorReadDoesNotMatch() {
        let comparison = ClosedCaptionSpike.compare(
            trackID: 1,
            nativeGroupCount: 0,
            nativeCues: [],
            reference: [SubtitleCue(startMilliseconds: 1_701, endMilliseconds: 4_000, text: "Hello")],
            validationSkips: []
        )
        XCTAssertFalse(comparison.matchesCleanedReference)
        XCTAssertEqual(comparison.textMismatchCount, 1)
        XCTAssertTrue(ClosedCaptionSpike.logLines(comparison)[0].contains("keep ffmpeg"))
    }

    func testBlankLinesNormalizeBeforeTheTextCompare() {
        let native = [snap("Hello\n\nthere", start: 0, end: 1_000)]
        let reference = [snap("Hello\nthere", start: 0, end: 1_000)]
        let comparison = ClosedCaptionSpike.compare(
            trackID: 1,
            nativeGroupCount: 5,
            nativeCues: native,
            reference: cues(reference),
            validationSkips: []
        )
        XCTAssertEqual(comparison.textMismatchCount, 0)
        XCTAssertTrue(comparison.matchesCleanedReference)
        XCTAssertTrue(ClosedCaptionSpike.logLines(comparison)[0].contains("groups 5"))
    }

    func testFailureKeepsThePartialPreviewOutOfTheSummary() {
        let comparison = ClosedCaptionSpike.failed(
            trackID: 4,
            reason: "NSInvalidArgumentException: not a caption\ntrack",
            nativeGroupCount: 1,
            nativeCues: [snap("Hello there", start: 1_701, end: 4_000)],
            reference: [SubtitleCue(startMilliseconds: 1_701, endMilliseconds: 4_000, text: "Hello there")]
        )
        XCTAssertFalse(comparison.matchesCleanedReference)
        XCTAssertEqual(comparison.failure, "NSInvalidArgumentException: not a caption track")
        let lines = ClosedCaptionSpike.logLines(comparison)
        XCTAssertTrue(lines[0].contains("failed (NSInvalidArgumentException: not a caption track)"))
        XCTAssertTrue(lines[0].contains("shipping ffmpeg"))
        XCTAssertTrue(lines[0].contains("keep ffmpeg"))
        XCTAssertFalse(lines[0].contains("Hello"))
        XCTAssertTrue(lines[1].contains("Hello there"))
    }

    func testFailureWithoutGroupsDoesNotLogReferenceText() {
        let comparison = ClosedCaptionSpike.failed(
            trackID: 4,
            reason: "The caption adaptor vended no caption groups.",
            reference: [SubtitleCue(startMilliseconds: 0, endMilliseconds: 1_000, text: "Secret line")]
        )
        XCTAssertFalse(ClosedCaptionSpike.logLines(comparison).joined(separator: "\n").contains("Secret"))
        XCTAssertEqual(comparison.nativeGroupCount, 0)
    }

    func testLongFailureAndPreviewAreCut() {
        let comparison = ClosedCaptionSpike.failed(
            trackID: 1,
            reason: String(repeating: "a", count: 400),
            nativeCues: [snap(String(repeating: "b", count: 120), start: 0, end: 1_000)],
            reference: []
        )
        XCTAssertEqual(comparison.failure?.count, 300)
        let preview = ClosedCaptionSpike.logLines(comparison).last ?? ""
        let text = preview.split(separator: ":").last.map(String.init) ?? ""
        XCTAssertEqual(text.trimmingCharacters(in: .whitespaces).count, 80)
    }

    func testPreviewStopsAtFiveGroups() {
        let native = (0..<6).map { snap("Cue \($0)", start: $0 * 1_000, end: $0 * 1_000 + 500) }
        let lines = ClosedCaptionSpike.logLines(ClosedCaptionSpike.compare(
            trackID: 2,
            nativeGroupCount: 6,
            nativeCues: native,
            reference: cues(native),
            validationSkips: []
        ))
        XCTAssertEqual(lines.count, 6)
        XCTAssertTrue(lines[5].contains("Cue 4"))
        XCTAssertFalse(lines.joined(separator: "\n").contains("Cue 5"))
    }

    private func snap(
        _ text: String,
        start: Int,
        end: Int,
        rollUp: Bool = false
    ) -> CaptionCueSnapshot {
        CaptionCueSnapshot(
            startMilliseconds: start,
            endMilliseconds: end,
            text: text,
            isRollUp: rollUp
        )
    }

    private func cues(_ snapshots: [CaptionCueSnapshot]) -> [SubtitleCue] {
        snapshots.map {
            SubtitleCue(startMilliseconds: $0.startMilliseconds, endMilliseconds: $0.endMilliseconds, text: $0.text)
        }
    }

    private func jeannie() -> [CaptionCueSnapshot] {
        (0..<633).map { index in
            let start = index == 0 ? 1_701 : 2_000 + index * 1_000
            let end = index == 632 ? 1_490_269 : start + 500
            return snap("Line \(index)", start: start, end: end)
        }
    }
}
