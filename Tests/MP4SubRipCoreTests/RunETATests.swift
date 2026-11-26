import XCTest
@testable import MP4SubRipCore

final class RunETATests: XCTestCase {
    func testSerialEstimateUsesTheFileThatIsRunning() {
        let sample = RunETA.Sample(
            percent: 50,
            elapsed: 10,
            finishedDurations: [],
            inFlight: [RunETA.InFlight(fraction: 0.5, elapsed: 10, unmeasured: false)],
            queuedCount: 0,
            concurrency: 1,
            remainingCount: 1
        )
        XCTAssertEqual(RunETA.caption(sample), "About 10 seconds left")
    }

    func testSerialQueueAddsFilesThatHaveNotStarted() {
        let sample = RunETA.Sample(
            percent: 20,
            elapsed: 10,
            finishedDurations: [],
            inFlight: [RunETA.InFlight(fraction: 0.5, elapsed: 10, unmeasured: false)],
            queuedCount: 2,
            concurrency: 1,
            remainingCount: 3
        )
        XCTAssertEqual(RunETA.caption(sample), "About 50 seconds left")
    }

    func testParallelSlotsShareTheQueuedWork() {
        let sample = RunETA.Sample(
            percent: 50,
            elapsed: 20,
            finishedDurations: [],
            inFlight: [
                RunETA.InFlight(fraction: 0.5, elapsed: 10, unmeasured: false),
                RunETA.InFlight(fraction: 0.5, elapsed: 20, unmeasured: false)
            ],
            queuedCount: 2,
            concurrency: 2,
            remainingCount: 4
        )
        XCTAssertEqual(RunETA.caption(sample), "About 50 seconds left")
    }

    func testFinishedDurationsFeedTheParallelEstimate() {
        let sample = RunETA.Sample(
            percent: 40,
            elapsed: 30,
            finishedDurations: [30, 50],
            inFlight: [RunETA.InFlight(fraction: 0.5, elapsed: 10, unmeasured: false)],
            queuedCount: 2,
            concurrency: 2,
            remainingCount: 3
        )
        XCTAssertEqual(RunETA.caption(sample), "About 1 minute left")
    }

    func testCaptionHidesBelowFivePercentAtTheEndAndAfterStop() {
        XCTAssertEqual(RunETA.caption(visibleSample(percent: 4)), "")
        XCTAssertEqual(RunETA.caption(visibleSample(percent: 5)), "About 10 seconds left")
        XCTAssertEqual(RunETA.caption(visibleSample(percent: 100)), "")
        XCTAssertEqual(RunETA.caption(visibleSample(percent: 140)), "")
        XCTAssertEqual(RunETA.caption(visibleSample(percent: 50, elapsed: 0)), "")
        XCTAssertEqual(RunETA.caption(visibleSample(percent: 50, elapsed: -3)), "")
        var stopped = visibleSample(percent: 50)
        stopped.cancelled = true
        XCTAssertEqual(RunETA.caption(stopped), "")
    }

    func testCaptionHidesWhenUnmeasuredFilesAreHalfOfWhatIsLeft() {
        var half = visibleSample(percent: 40)
        half.unmeasuredRemaining = 2
        half.remainingCount = 4
        XCTAssertEqual(RunETA.caption(half), "")

        var under = visibleSample(percent: 40)
        under.unmeasuredRemaining = 1
        under.remainingCount = 4
        XCTAssertEqual(RunETA.caption(under), "About 10 seconds left")
    }

    func testSentenceRoundsToSecondsMinutesAndHours() {
        XCTAssertEqual(RunETA.sentence(0), "About 1 second left")
        XCTAssertEqual(RunETA.sentence(0.4), "About 1 second left")
        XCTAssertEqual(RunETA.sentence(1), "About 1 second left")
        XCTAssertEqual(RunETA.sentence(2), "About 2 seconds left")
        XCTAssertEqual(RunETA.sentence(59.4), "About 59 seconds left")
        XCTAssertEqual(RunETA.sentence(59.6), "About 1 minute left")
        XCTAssertEqual(RunETA.sentence(60), "About 1 minute left")
        XCTAssertEqual(RunETA.sentence(90), "About 2 minutes left")
        XCTAssertEqual(RunETA.sentence(3_599), "About 1 hour left")
        XCTAssertEqual(RunETA.sentence(3_600), "About 1 hour left")
        XCTAssertEqual(RunETA.sentence(3_660), "About 1 hour 1 minute left")
        XCTAssertEqual(RunETA.sentence(5_400), "About 1 hour 30 minutes left")
        XCTAssertEqual(RunETA.sentence(7_200), "About 2 hours left")
        XCTAssertEqual(RunETA.sentence(7_320), "About 2 hours 2 minutes left")
        XCTAssertEqual(RunETA.sentence(-1), "")
        XCTAssertEqual(RunETA.sentence(.infinity), "")
    }

    func testEventUsesTheInjectedClockAndPublishesAHideImmediately() {
        var eta = RunETA()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let first = visibleSample(percent: 50)
        let later = RunETA.Sample(
            percent: 50,
            elapsed: 20,
            finishedDurations: [],
            inFlight: [
                RunETA.InFlight(fraction: 0.5, elapsed: 10, unmeasured: false),
                RunETA.InFlight(fraction: 0.5, elapsed: 20, unmeasured: false)
            ],
            queuedCount: 2,
            concurrency: 2,
            remainingCount: 4
        )
        XCTAssertEqual(eta.event(for: first, at: start)?.caption, "About 10 seconds left")
        XCTAssertNil(eta.event(for: first, at: start.addingTimeInterval(1)))
        XCTAssertNil(eta.event(for: later, at: start.addingTimeInterval(0.05)))
        XCTAssertEqual(
            eta.event(for: later, at: start.addingTimeInterval(0.1))?.caption,
            "About 50 seconds left"
        )
        var stopped = later
        stopped.cancelled = true
        XCTAssertEqual(eta.event(for: stopped, at: start.addingTimeInterval(0.12))?.caption, "")
        XCTAssertEqual(
            eta.event(for: first, at: start.addingTimeInterval(0.15))?.caption,
            "About 10 seconds left"
        )
    }

    private func visibleSample(percent: Int, elapsed: TimeInterval = 10) -> RunETA.Sample {
        RunETA.Sample(
            percent: percent,
            elapsed: elapsed,
            finishedDurations: [],
            inFlight: [RunETA.InFlight(fraction: 0.5, elapsed: 10, unmeasured: false)],
            queuedCount: 0,
            concurrency: 1,
            remainingCount: 1
        )
    }
}
