import XCTest
@testable import MP4SubRipCore

final class QueueRulesTests: XCTestCase {
    func testRemoveAndClearSplitFailedFromProcessed() {
        XCTAssertTrue(JobStatus.waiting.canRemove)
        XCTAssertTrue(JobStatus.probing.canRemove)
        XCTAssertFalse(JobStatus.working(completed: 1, total: 3).canRemove)
        XCTAssertTrue(JobStatus.done(written: ["/a"], skippedExists: []).canRemove)
        XCTAssertTrue(JobStatus.failed(reason: "x").canRemove)
        XCTAssertFalse(JobStatus.failed(reason: "x").clearsWithProcessed)
        XCTAssertTrue(JobStatus.failed(reason: "x").clearsWithAllFinished)
        XCTAssertTrue(JobStatus.noSubtitles.clearsWithProcessed)
        XCTAssertTrue(JobStatus.imageSubsOnly.clearsWithProcessed)
        XCTAssertTrue(JobStatus.skippedExists(paths: ["/a"]).clearsWithProcessed)
        XCTAssertFalse(JobStatus.probing.clearsWithProcessed)
        XCTAssertFalse(JobStatus.waiting.clearsWithProcessed)
    }

    func testCommandFlagsFollowTheRows() {
        XCTAssertEqual(CommandFlags.from([]), CommandFlags())
        let items = [QueueItem(path: "/a", status: .working(completed: 0, total: 0)), QueueItem(path: "/b", status: .canceled)]
        XCTAssertEqual(
            CommandFlags.from(items),
            CommandFlags(hasActiveWork: true, canClearProcessed: true, canClearAllFinished: true)
        )
    }

    func testProgressTickIsWorkingToWorkingOnly() {
        let working = JobStatus.working(completed: 1, total: 10)
        XCTAssertTrue(working.isProgressTick(to: .working(completed: 2, total: 10)))
        XCTAssertFalse(working.isProgressTick(to: .done(written: ["/a"], skippedExists: [])))
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
        XCTAssertEqual(JobStatus.probing.summary, "Reading tracks…")
        XCTAssertEqual(JobStatus.done(written: ["/tmp/Movie.srt"], skippedExists: []).summary, "Done · 1 file")
        XCTAssertEqual(JobStatus.done(written: ["/tmp/A.srt", "/tmp/B.srt"], skippedExists: []).summary, "Done · 2 files")
        XCTAssertEqual(JobStatus.skippedExists(paths: ["/tmp/Movie.srt"]).summary, "Done · skipped (exists)")
        XCTAssertEqual(JobStatus.noSubtitles.summary, "No subtitles")
        XCTAssertEqual(JobStatus.imageSubsOnly.summary, "Image subs only")
        XCTAssertEqual(QueueRowText.summary(.waiting, runIsActive: true), "Waiting…")
        XCTAssertEqual(JobStatus.working(completed: 64, total: 100).progressPercent, 64)
        XCTAssertEqual(JobStatus.canceled.summary, "Cancelled")
        XCTAssertFalse(JobStatus.waiting.offersErrorDetail)
        XCTAssertFalse(JobStatus.skipped(reason: "x").offersErrorDetail)
        XCTAssertTrue(JobStatus.failed(reason: "x").offersErrorDetail)
    }

    func testFailureAndSkipLinesUseEngineStrings() {
        let missing = SubtitleExtractionError.fileNotFound.errorDescription
        XCTAssertEqual(missing, "File not found.")
        XCTAssertEqual(JobStatus.failed(reason: missing ?? "").summary, "Failed · File not found")
        XCTAssertEqual(JobStatus.failed(reason: missing ?? "").detail, "File not found.")
        let bitmap = SubtitleSkipReason.bitmap.message
        XCTAssertEqual(bitmap, "Image-based subtitles (needs OCR).")
        XCTAssertEqual(JobStatus.skipped(reason: bitmap).summary, "Skipped · \(bitmap)")
        XCTAssertEqual(JobStatus.skipped(reason: bitmap).detail, bitmap)
        let readOnly = SubtitleExtractionError.outputNotWritable.errorDescription
        XCTAssertEqual(JobStatus.failed(reason: readOnly ?? "").summary, "Failed · Read-only folder")
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
        let done = QueueItem(path: "/m/a.mp4", status: .done(written: ["/m/a.srt"], skippedExists: []))
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
        let done = QueueItem(path: "/m/c.mp4", status: .done(written: ["/m/c.srt"], skippedExists: []))
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
            QueueItem(path: "/m/a.mp4", status: .done(written: ["/m/a.srt"], skippedExists: [])),
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
            CommandFlags(hasActiveWork: true, canExtract: true, isRunning: false)
        )
        XCTAssertFalse(CommandFlags.from(pending, isRunning: true).canExtract)
        XCTAssertFalse(CommandFlags.from(pending, isRunning: false, hasLiveTask: true).canExtract)
        let done = [QueueItem(path: "/a", status: .done(written: ["/a.srt"], skippedExists: []))]
        XCTAssertFalse(CommandFlags.from(done).canExtract)
        XCTAssertFalse(CommandFlags.from(done).isRunning)
    }

    /// Stop puts rows back to Pending while the cancelled task is still cleaning up.
    /// Extract stays disabled until that task is gone, then it enables.
    func testExtractEnablesAfterStopCleanup() {
        let pending = [QueueItem(path: "/a", status: .waiting)]
        let cleaningUp = CommandFlags.from(pending, isRunning: false, hasLiveTask: true)
        XCTAssertFalse(cleaningUp.isRunning)
        XCTAssertFalse(cleaningUp.canExtract)
        let cleaned = CommandFlags.from(pending, isRunning: false, hasLiveTask: false)
        XCTAssertFalse(cleaned.isRunning)
        XCTAssertTrue(cleaned.canExtract)
    }

    func testNextExtractSkipsRowsSettledByProbe() {
        let pending = UUID()
        let items = [
            QueueItem(path: "/m/a.mp4", status: .probing),
            QueueItem(path: "/m/b.mp4", status: .noSubtitles),
            QueueItem(path: "/m/c.mp4", status: .imageSubsOnly),
            QueueItem(path: "/m/d.mp4", status: .skippedExists(paths: ["/m/d.srt"])),
            QueueItem(id: pending, path: "/m/e.mp4", status: .waiting)
        ]
        XCTAssertEqual(QueueRunRules.nextPending(in: items, held: []), pending)
    }

    func testClearProcessedKeepsFailedAndARunDisablesClear() {
        let done = QueueItem(path: "/a", status: .done(written: ["/a.srt"], skippedExists: []))
        let failed = QueueItem(path: "/b", status: .failed(reason: "Folder is read-only."))
        let pending = QueueItem(path: "/c", status: .waiting)
        let items = [done, failed, pending]
        XCTAssertEqual(QueueHousekeeping.clearing(items, includingFailed: false).map(\.path), ["/b", "/c"])
        XCTAssertEqual(QueueHousekeeping.clearing(items, includingFailed: true).map(\.path), ["/c"])
        XCTAssertFalse(CommandFlags.from(items, isRunning: true).canClearProcessed)
        XCTAssertFalse(CommandFlags.from(items, isRunning: true).canClearAllFinished)
        XCTAssertTrue(CommandFlags.from([failed]).canClearAllFinished)
        XCTAssertFalse(CommandFlags.from([failed]).canClearProcessed)
    }

    func testNewRowsAreMarkedForProbe() {
        let existing = QueueItem(path: "/old.mp4", status: .done(written: ["/old.srt"], skippedExists: []))
        let addition = QueueList.adding(["/old.mp4", "/new.mp4"], to: [existing])
        let marked = QueueList.markingNewRowsForProbe(addition.items, existingIDs: [existing.id])
        XCTAssertEqual(marked.probeIDs.count, 1)
        XCTAssertEqual(marked.items[0].status, existing.status)
        XCTAssertEqual(marked.items[1].status, .probing)
        XCTAssertEqual(marked.items[1].id, marked.probeIDs[0])
    }
}
