import XCTest

final class HelloWorldUITests: XCTestCase {

    override func setUpWithError() throws {
        // Stop the test at the first failure instead of clicking on blindly.
        continueAfterFailure = false
    }

    func testAppOpensMainWindow() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5),
                      "The main application window never showed up")
    }
}
