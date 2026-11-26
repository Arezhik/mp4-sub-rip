import XCTest
@testable import MP4SubRipCore

final class ExtractionModeTests: XCTestCase {
    func testMissingOrUnknownDefaultsStayOneAtATime() {
        let defaults = makeDefaults()
        XCTAssertEqual(ExtractionMode.load(defaults), .oneAtATime)
        XCTAssertEqual(ExtractionMode.oneAtATime.title, "One at a Time")
        XCTAssertEqual(ExtractionMode.parallel.title, "Parallel")
        defaults.set("sideways", forKey: ExtractionMode.defaultsKey)
        XCTAssertEqual(ExtractionMode.load(defaults), .oneAtATime)
    }

    func testModeRoundTripsThroughDefaults() {
        let defaults = makeDefaults()
        ExtractionMode.parallel.save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: ExtractionMode.defaultsKey), ExtractionMode.parallel.rawValue)
        XCTAssertEqual(ExtractionMode.load(defaults), .parallel)
        ExtractionMode.oneAtATime.save(to: defaults)
        XCTAssertEqual(ExtractionMode.load(defaults), .oneAtATime)
    }

    func testSlotCountIsOneOrTheParallelLimit() {
        XCTAssertEqual(ExtractionMode.oneAtATime.slotCount(activeProcessorCount: 8), 1)
        XCTAssertEqual(ExtractionMode.oneAtATime.slotCount(activeProcessorCount: 2), 1)
        XCTAssertEqual(ExtractionMode.parallel.slotCount(activeProcessorCount: 8), 4)
        XCTAssertEqual(ExtractionMode.parallel.slotCount(activeProcessorCount: 2), 2)
    }

    func testParallelLimitFloorsAtTwoAndCapsAtFour() {
        XCTAssertEqual(ParallelLimit.default(activeProcessorCount: -4), 2)
        XCTAssertEqual(ParallelLimit.default(activeProcessorCount: 0), 2)
        XCTAssertEqual(ParallelLimit.default(activeProcessorCount: 1), 2)
        XCTAssertEqual(ParallelLimit.default(activeProcessorCount: 2), 2)
        XCTAssertEqual(ParallelLimit.default(activeProcessorCount: 3), 2)
        XCTAssertEqual(ParallelLimit.default(activeProcessorCount: 4), 2)
        XCTAssertEqual(ParallelLimit.default(activeProcessorCount: 7), 3)
        XCTAssertEqual(ParallelLimit.default(activeProcessorCount: 8), 4)
        XCTAssertEqual(ParallelLimit.default(activeProcessorCount: 16), 4)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "ExtractionModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
