import XCTest
@testable import MP4SubRipCore

final class RunProgressTests: XCTestCase {
    func testRunningCountsFractionSummaryAndBadge() {
        let rows = [
            finished(saved: ["a"]),
            finished(saved: ["b"]),
            finished(saved: ["c"]),
            extracting(0.2),
            extracting(0.4),
            extracting(0),
            waiting()
        ]
        XCTAssertEqual(RunProgress.overallFraction(rows), (3 + 0.6) / 7, accuracy: 0.000_1)
        let presentation = RunProgress.presentation(
            phase: .running,
            rows: rows,
            etaCaption: "About 40 seconds left"
        )
        XCTAssertEqual(presentation.leadingSummary, "3 of 7 complete · 3 extracting")
        XCTAssertEqual(presentation.toolbarSubtitle, "Extracting · 3 of 7 complete")
        XCTAssertEqual(presentation.caption, "About 40 seconds left")
        XCTAssertEqual(presentation.accessibilityValue, "3 of 7 complete, About 40 seconds left")
        XCTAssertEqual(presentation.completed, 3)
        XCTAssertEqual(presentation.extracting, 3)
        XCTAssertEqual(presentation.remaining, 4)
        XCTAssertEqual(presentation.total, 7)
        XCTAssertEqual(presentation.dockBadge, "4")
        XCTAssertTrue(presentation.showsColumn)
        XCTAssertFalse(presentation.showsFinder)
        XCTAssertEqual(presentation.fraction, (3 + 0.6) / 7, accuracy: 0.000_1)

        let quiet = RunProgress.presentation(phase: .running, rows: rows, etaCaption: "")
        XCTAssertEqual(quiet.caption, "")
        XCTAssertEqual(quiet.accessibilityValue, "3 of 7 complete")
    }

    func testFinishedCountsSavedExistedAndAlreadyExisted() {
        let rows = [
            finished(saved: ["a", "b"], existed: ["c"]),
            finished(saved: ["d", "e", "f"]),
            finished(existed: ["g"]),
            finished(saved: ["h"]),
            finished(saved: ["i"]),
            RunRow(id: UUID(), state: .finished(.failed), unmeasured: false),
            RunRow(id: UUID(), state: .finished(.noSubtitles), unmeasured: false)
        ]
        let presentation = RunProgress.presentation(phase: .finished, rows: rows)
        XCTAssertEqual(presentation.leadingSummary, "5 done · 1 failed")
        XCTAssertEqual(presentation.leadingHelp, "1 no subtitles")
        XCTAssertEqual(presentation.toolbarSubtitle, "Finished · 5 of 7 succeeded")
        XCTAssertEqual(presentation.caption, "7 .srt saved · 2 existed")
        XCTAssertEqual(presentation.savedCount, 7)
        XCTAssertEqual(presentation.existedCount, 2)
        XCTAssertEqual(presentation.succeeded, 5)
        XCTAssertEqual(presentation.failed, 1)
        XCTAssertEqual(presentation.fraction, 1)
        XCTAssertNil(presentation.dockBadge)
        XCTAssertTrue(presentation.showsColumn)
        XCTAssertTrue(presentation.showsFinder)
        XCTAssertEqual(presentation.outputPaths, ["a", "b", "c", "d", "e", "f", "g", "h", "i"])

        XCTAssertEqual(RunProgress.savedCaption(saved: 3, existed: 0), "3 .srt saved")
        XCTAssertEqual(RunProgress.savedCaption(saved: 0, existed: 2), "2 already existed")
        XCTAssertEqual(RunProgress.savedCaption(saved: 8, existed: 2), "8 .srt saved · 2 existed")
        XCTAssertEqual(RunProgress.savedCaption(saved: 0, existed: 0), "")

        let existedOnly = RunProgress.presentation(
            phase: .finished,
            rows: [finished(existed: ["old-a", "old-b"])]
        )
        XCTAssertEqual(existedOnly.caption, "2 already existed")
        XCTAssertTrue(existedOnly.showsFinder)
        XCTAssertEqual(existedOnly.outputPaths, ["old-a", "old-b"])
    }

    func testFinishedHelpKeepsNoSubtitlesImageAndSkippedOffTheMainLine() {
        let rows = [
            finished(saved: ["a"]),
            RunRow(id: UUID(), state: .finished(.noSubtitles), unmeasured: false),
            RunRow(id: UUID(), state: .finished(.noSubtitles), unmeasured: false),
            RunRow(id: UUID(), state: .finished(.imageOnly), unmeasured: false),
            RunRow(id: UUID(), state: .finished(.skipped), unmeasured: false)
        ]
        let presentation = RunProgress.presentation(phase: .finished, rows: rows)
        XCTAssertEqual(presentation.leadingSummary, "1 done")
        XCTAssertEqual(presentation.leadingHelp, "2 no subtitles · 1 image subs only · 1 skipped")
        XCTAssertEqual(presentation.toolbarSubtitle, "Finished · 1 of 5 succeeded")
        XCTAssertEqual(presentation.caption, "1 .srt saved")
    }

    func testRetryExtendsTheFinishedRun() {
        // Retry while the bar is still finished keeps the earlier rows and
        // adds the file that is running again. 6 done of 7, one extracting.
        var rows = (0..<6).map { _ in finished(saved: ["x"]) }
        rows.append(extracting(0))
        let presentation = RunProgress.presentation(phase: .running, rows: rows, etaCaption: "")
        XCTAssertEqual(presentation.leadingSummary, "6 of 7 complete · 1 extracting")
        XCTAssertEqual(presentation.toolbarSubtitle, "Extracting · 6 of 7 complete")
        XCTAssertEqual(presentation.completed, 6)
        XCTAssertEqual(presentation.extracting, 1)
        XCTAssertEqual(presentation.remaining, 1)
        XCTAssertEqual(presentation.dockBadge, "1")
        XCTAssertEqual(presentation.fraction, 6 / 7, accuracy: 0.000_1)
    }

    func testStopSummaryClearsTheBarAndTheBadge() {
        let rows = [
            finished(saved: ["a"]),
            finished(saved: ["b"]),
            finished(saved: ["c"]),
            waiting(),
            waiting(),
            waiting(),
            waiting()
        ]
        let presentation = RunProgress.presentation(phase: .stopped, rows: rows)
        XCTAssertEqual(presentation.leadingSummary, "Stopped · 3 of 7 complete")
        XCTAssertEqual(presentation.toolbarSubtitle, "Stopped · 3 of 7 complete")
        XCTAssertEqual(presentation.caption, "")
        XCTAssertEqual(presentation.accessibilityValue, "")
        XCTAssertFalse(presentation.showsColumn)
        XCTAssertFalse(presentation.showsFinder)
        XCTAssertNil(presentation.dockBadge)
        XCTAssertEqual(presentation.completed, 3)
        XCTAssertEqual(presentation.remaining, 4)
    }

    func testIdleAndEmptyRunsShowNothing() {
        XCTAssertEqual(RunProgress.presentation(phase: .idle, rows: [waiting()]), .idle)
        XCTAssertEqual(RunProgress.presentation(phase: .running, rows: []), .idle)
        XCTAssertEqual(RunProgress.overallFraction([]), 0)
    }

    func testClosedCaptionRowsStayUnmeasuredUntilTheyReportATotal() throws {
        let captions = SubtitleTrack(
            id: 1,
            languageCode: "eng",
            kind: .closedCaption,
            codec: "c608",
            isExtractable: true
        )
        let text = SubtitleTrack(
            id: 2,
            languageCode: "eng",
            kind: .text,
            codec: "tx3g",
            isExtractable: true
        )
        XCTAssertTrue(RunRows.isUnmeasured(tracks: [captions]))
        XCTAssertFalse(RunRows.isUnmeasured(tracks: [captions, text]))
        XCTAssertFalse(RunRows.isUnmeasured(tracks: []))

        let waiting = QueueItem(path: "/m/a.mp4", status: .waiting, tracks: [captions])
        XCTAssertEqual(RunRows.make(waiting)?.unmeasured, true)
        let working = QueueItem(path: "/m/a.mp4", status: .working(completed: 0, total: 0), tracks: [captions])
        let row = try XCTUnwrap(RunRows.make(working))
        XCTAssertTrue(row.unmeasured)
        guard case let .extracting(fraction) = row.state else {
            return XCTFail("expected an extracting row")
        }
        XCTAssertEqual(fraction, 0)

        let measured = QueueItem(path: "/m/b.mp4", status: .working(completed: 25, total: 100), tracks: [text])
        let measuredRow = try XCTUnwrap(RunRows.make(measured))
        XCTAssertFalse(measuredRow.unmeasured)
        guard case let .extracting(measuredFraction) = measuredRow.state else {
            return XCTFail("expected a measured extracting row")
        }
        XCTAssertEqual(measuredFraction, 0.25, accuracy: 0.000_1)
    }

    func testETASampleSeparatesQueuedUnmeasuredAndInFlightTime() {
        let slow = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 5_000)
        let rows = [
            RunRow(id: slow, state: .extracting(fraction: 0), unmeasured: true),
            RunRow(id: UUID(), state: .waiting, unmeasured: false),
            RunRow(id: UUID(), state: .waiting, unmeasured: true),
            finished(saved: ["a"])
        ]
        let sample = RunProgress.etaSample(
            rows: rows,
            runElapsed: 12,
            finishedDurations: [8],
            concurrency: 2,
            now: now,
            startedAt: [slow: now.addingTimeInterval(-4)]
        )
        XCTAssertEqual(sample.percent, 25)
        XCTAssertEqual(sample.elapsed, 12)
        XCTAssertEqual(sample.queuedCount, 2)
        XCTAssertEqual(sample.unmeasuredRemaining, 2)
        XCTAssertEqual(sample.remainingCount, 3)
        XCTAssertEqual(sample.concurrency, 2)
        XCTAssertEqual(sample.finishedDurations, [8])
        XCTAssertEqual(sample.inFlight.count, 1)
        XCTAssertEqual(sample.inFlight[0].elapsed, 4, accuracy: 0.001)
        XCTAssertTrue(sample.inFlight[0].unmeasured)
        XCTAssertFalse(sample.cancelled)
    }

    private func waiting() -> RunRow {
        RunRow(id: UUID(), state: .waiting, unmeasured: false)
    }

    private func extracting(_ fraction: Double) -> RunRow {
        RunRow(id: UUID(), state: .extracting(fraction: fraction), unmeasured: fraction == 0)
    }

    private func finished(saved: [String] = [], existed: [String] = []) -> RunRow {
        RunRow(id: UUID(), state: .finished(.succeeded(saved: saved, existed: existed)), unmeasured: false)
    }
}
