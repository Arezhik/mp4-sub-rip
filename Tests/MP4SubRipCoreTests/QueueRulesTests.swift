import XCTest
@testable import MP4SubRipCore

final class QueueRulesTests: XCTestCase {
    func testOnlyFinishedRowsAreRemovable() {
        XCTAssertFalse(JobStatus.waiting.isRemovable)
        XCTAssertFalse(JobStatus.working(completed: 1, total: 3).isRemovable)
        XCTAssertTrue(JobStatus.done(outputPath: "/a").isRemovable)
        XCTAssertTrue(JobStatus.failed(reason: "x").isRemovable)
        XCTAssertTrue(JobStatus.skipped(reason: "x").isRemovable)
        XCTAssertTrue(JobStatus.canceled.isRemovable)
    }

    func testCommandFlagsFollowTheRows() {
        XCTAssertEqual(CommandFlags.from([]), CommandFlags(hasActiveWork: false, canClearFinished: false))
        let items = [QueueItem(path: "/a", status: .working(completed: 0, total: 0)), QueueItem(path: "/b", status: .canceled)]
        XCTAssertEqual(CommandFlags.from(items), CommandFlags(hasActiveWork: true, canClearFinished: true))
    }

    func testProgressTickIsWorkingToWorkingOnly() {
        let working = JobStatus.working(completed: 1, total: 10)
        XCTAssertTrue(working.isProgressTick(to: .working(completed: 2, total: 10)))
        XCTAssertFalse(working.isProgressTick(to: .done(outputPath: "/a")))
        XCTAssertFalse(JobStatus.waiting.isProgressTick(to: working))
    }

    func testThrottleAllowsAboutTenUpdatesASecond() {
        var throttle = ProgressThrottle()
        let start = Date(timeIntervalSince1970: 1000)
        var published = 0
        for tick in 0..<100 {
            // 100 ticks over one second, one every 10 ms.
            if throttle.shouldPublish(at: start.addingTimeInterval(Double(tick) * 0.01)) {
                published += 1
            }
        }
        // Floating-point tick times can land a hair under the interval, so allow 9 or 10.
        XCTAssertTrue((9...10).contains(published), "published \(published)")
        XCTAssertTrue(throttle.shouldPublish(at: start.addingTimeInterval(0.995), force: true))
    }

    func testStatusWordsMatchTheSpec() {
        XCTAssertEqual(JobStatus.waiting.summary, "Pending")
        XCTAssertEqual(JobStatus.working(completed: 1, total: 4).summary, "Extracting")
        XCTAssertEqual(JobStatus.done(outputPath: "/tmp/Movie.srt").summary, "Done · Movie.srt")
        XCTAssertEqual(JobStatus.canceled.summary, "Cancelled")
        XCTAssertFalse(JobStatus.waiting.offersErrorDetail)
        XCTAssertFalse(JobStatus.skipped(reason: "x").offersErrorDetail)
        XCTAssertTrue(JobStatus.failed(reason: "x").offersErrorDetail)
    }

    func testFailureAndSkipLinesUseEngineStrings() {
        let missing = SubtitleExtractionError.fileNotFound.errorDescription
        XCTAssertEqual(missing, "File not found.")
        XCTAssertEqual(JobStatus.failed(reason: missing ?? "").summary, "Failed · File not found.")
        XCTAssertEqual(JobStatus.failed(reason: missing ?? "").detail, "File not found.")
        let bitmap = SubtitleSkipReason.bitmap.message
        XCTAssertEqual(bitmap, "Image-based subtitles (needs OCR).")
        XCTAssertEqual(JobStatus.skipped(reason: bitmap).summary, "Skipped · \(bitmap)")
        XCTAssertEqual(JobStatus.skipped(reason: bitmap).detail, bitmap)
        let readOnly = SubtitleExtractionError.outputNotWritable.errorDescription
        XCTAssertEqual(JobStatus.failed(reason: readOnly ?? "").summary, "Failed · Folder is read-only.")
    }

    func testAddingAPathTwiceDoesNotCreateASecondRow() {
        let first = QueueList.adding(["/m/a.mp4"], to: [])
        XCTAssertEqual(first.addedCount, 1)
        XCTAssertEqual(first.duplicateIDs, [])
        let again = QueueList.adding(["/m/a.mp4"], to: first.items)
        XCTAssertEqual(again.addedCount, 0)
        XCTAssertEqual(again.items.count, 1)
        XCTAssertEqual(again.duplicateIDs, [first.items[0].id])
        XCTAssertEqual(again.items[0].status, .waiting)
    }

    func testAFinishedFileIsNotAddedAgain() {
        let done = QueueItem(path: "/m/a.mp4", status: .done(outputPath: "/m/a.srt"))
        let failed = QueueItem(path: "/m/b.mp4", status: .failed(reason: "File not found."))
        let addition = QueueList.adding(["/m/a.mp4", "/m/b.mp4", "/m/c.mp4"], to: [done, failed])
        XCTAssertEqual(addition.addedCount, 1)
        XCTAssertEqual(addition.items.map(\.path), ["/m/a.mp4", "/m/b.mp4", "/m/c.mp4"])
        XCTAssertEqual(addition.duplicateIDs, [done.id, failed.id])
        XCTAssertEqual(addition.items[0].status, done.status)
        XCTAssertEqual(addition.items[2].status, .waiting)
    }

    func testStopReturnsTheExtractingRowToPending() {
        let working = QueueItem(path: "/m/a.mp4", status: .working(completed: 1, total: 4))
        let pending = QueueItem(path: "/m/b.mp4", status: .waiting)
        let done = QueueItem(path: "/m/c.mp4", status: .done(outputPath: "/m/c.srt"))
        let failed = QueueItem(path: "/m/d.mp4", status: .failed(reason: "File not found."))
        let skipped = QueueItem(path: "/m/e.mp4", status: .skipped(reason: SubtitleSkipReason.bitmap.message))
        let stopped = QueueRunRules.stopped([working, pending, done, failed, skipped])
        XCTAssertEqual(stopped.map(\.status), [
            .waiting,
            .waiting,
            done.status,
            failed.status,
            skipped.status
        ])
    }

    func testCancelReturnsThatRowToPendingAndTheRunSkipsIt() {
        let current = UUID()
        let next = UUID()
        let items = [
            QueueItem(id: current, path: "/m/a.mp4", status: .working(completed: 0, total: 1)),
            QueueItem(id: next, path: "/m/c.mp4", status: .waiting)
        ]
        let cancelled = QueueRunRules.cancelled(items, id: current)
        XCTAssertEqual(cancelled[0].status, .waiting)
        XCTAssertEqual(cancelled[1].status, .waiting)
        XCTAssertEqual(QueueRunRules.nextPending(in: cancelled, held: [current]), next)
    }

    func testNextExtractSkipsFinishedRows() {
        let pending = UUID()
        let items = [
            QueueItem(path: "/m/a.mp4", status: .done(outputPath: "/m/a.srt")),
            QueueItem(path: "/m/b.mp4", status: .failed(reason: "File not found.")),
            QueueItem(path: "/m/c.mp4", status: .skipped(reason: SubtitleSkipReason.bitmap.message)),
            QueueItem(id: pending, path: "/m/d.mp4", status: .waiting),
            QueueItem(path: "/m/e.mp4", status: .canceled)
        ]
        XCTAssertEqual(QueueRunRules.nextPending(in: items, held: []), pending)
        XCTAssertNil(QueueRunRules.nextPending(in: items, held: [pending]))
    }

    func testExtractIsAvailableOnlyWhenPendingAndIdle() {
        let pending = [QueueItem(path: "/a", status: .waiting)]
        XCTAssertEqual(
            CommandFlags.from(pending, isRunning: false),
            CommandFlags(hasActiveWork: true, canClearFinished: false, canExtract: true, isRunning: false)
        )
        XCTAssertFalse(CommandFlags.from(pending, isRunning: true).canExtract)
        XCTAssertFalse(CommandFlags.from(pending, isRunning: false, hasLiveTask: true).canExtract)
        let done = [QueueItem(path: "/a", status: .done(outputPath: "/a.srt"))]
        XCTAssertFalse(CommandFlags.from(done).canExtract)
        XCTAssertFalse(CommandFlags.from(done).isRunning)
    }
}
