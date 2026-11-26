import XCTest
@testable import MP4SubRipCore

final class OutputReservationTests: XCTestCase {
    func testTryClaimWinsOnceUntilRelease() {
        let reservation = OutputReservation()
        let path = "/tmp/out/Movie.srt"
        XCTAssertFalse(reservation.isReserved(path))
        XCTAssertTrue(reservation.tryClaim(path))
        XCTAssertTrue(reservation.isReserved(path))
        XCTAssertFalse(reservation.tryClaim(path))
        reservation.release(path)
        XCTAssertFalse(reservation.isReserved(path))
        XCTAssertTrue(reservation.tryClaim(path))
    }

    func testPathsAreMatchedAfterStandardizing() {
        let reservation = OutputReservation()
        XCTAssertTrue(reservation.tryClaim("/tmp/a/../a/Movie.srt"))
        XCTAssertTrue(reservation.isReserved("/tmp/a/Movie.srt"))
        XCTAssertFalse(reservation.tryClaim("/tmp/a/Movie.srt"))
        reservation.release(["/tmp/a/Movie.srt"])
        XCTAssertFalse(reservation.isReserved("/tmp/a/../a/Movie.srt"))
    }

    func testOnlyOneConcurrentClaimSucceeds() {
        let reservation = OutputReservation()
        let path = "/tmp/out/Shared.srt"
        let wins = LockedCount()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if reservation.tryClaim(path) {
                wins.increment()
            }
        }
        XCTAssertEqual(wins.value, 1)
        XCTAssertTrue(reservation.isReserved(path))
    }

    func testExclusiveClaimWaitsAndKeepsThePathHeld() async {
        let reservation = OutputReservation()
        let path = "/tmp/out/Movie.srt"
        XCTAssertTrue(reservation.tryClaim(path))
        let started = Date()
        let waiter = Task {
            await reservation.claimExclusive(path)
            return Date()
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(waiter.isCancelled)
        XCTAssertTrue(reservation.isReserved(path))
        reservation.release(path)
        let resumed = await waiter.value
        XCTAssertGreaterThanOrEqual(resumed.timeIntervalSince(started), 0.1)
        XCTAssertTrue(reservation.isReserved(path))
        reservation.release(path)
        XCTAssertFalse(reservation.isReserved(path))
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
