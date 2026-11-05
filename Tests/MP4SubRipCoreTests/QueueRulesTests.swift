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
}
