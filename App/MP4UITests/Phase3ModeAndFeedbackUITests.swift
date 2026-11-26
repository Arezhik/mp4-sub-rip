import XCTest

/// Pareto critical path for Phase 3: the queue window, the Mode picker, and Extract Subtitles.
///
/// Launch with `--uitesting` only. Do not pass `-ApplePersistenceIgnoreState YES`:
/// together with `--uitesting` it suppresses the SwiftUI main window, so the app
/// activates and no window opens.
@MainActor
final class Phase3ModeAndFeedbackUITests: XCTestCase {
    private var fixtures: UITestFixtureBuilder!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixtures = try UITestFixtureBuilder()
        // Intake shows the file in the queue. Extraction does not start until Extract Subtitles.
        try fixtures.createDummyFile(in: fixtures.input, named: "sample.mp4")
    }

    override func tearDownWithError() throws {
        fixtures?.cleanup()
        fixtures = nil
    }

    func testPhase3ModeAndFeedbackCriticalPath() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment = [
            "UITEST_INPUT_DIR": fixtures.input.path,
            "UITEST_OUTPUT_DIR": fixtures.output.path,
        ]
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5),
                      "The main application window never showed up")

        let item = app.staticTexts["sample.mp4"]
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "The seeded sample.mp4 row never showed up")

        XCTAssertTrue(app.buttons["Extract Subtitles"].waitForExistence(timeout: 2),
                      "The Extract Subtitles button never showed up")

        let picker = app.descendants(matching: .any)["extractionModePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 2),
                      "The Mode picker never showed up")

        let parallel = modeControl(named: "Parallel", in: picker, app: app)
        XCTAssertTrue(parallel.waitForExistence(timeout: 2),
                      "Parallel never showed up")
        parallel.click()

        let oneAtATime = modeControl(named: "One at a Time", in: picker, app: app)
        XCTAssertTrue(oneAtATime.waitForExistence(timeout: 2),
                      "One at a Time never showed up")
        oneAtATime.click()
    }

    /// Segmented SwiftUI pickers expose each choice as a radio button or a button.
    private func modeControl(named title: String, in picker: XCUIElement, app: XCUIApplication) -> XCUIElement {
        let candidates = [
            picker.radioButtons[title],
            picker.buttons[title],
            app.radioButtons[title],
            app.buttons[title],
        ]
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let found = candidates.first(where: \.exists) {
                return found
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return candidates[0]
    }
}
