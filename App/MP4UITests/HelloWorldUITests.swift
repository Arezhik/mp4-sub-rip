import XCTest

final class HelloWorldUITests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Input", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Output", isDirectory: true), withIntermediateDirectories: true)
        fixtureRoot = root
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    func testAppOpensMainWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = [
            "UITEST_INPUT_DIR": fixtureRoot.appendingPathComponent("Input", isDirectory: true).path,
            "UITEST_OUTPUT_DIR": fixtureRoot.appendingPathComponent("Output", isDirectory: true).path,
        ]
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5),
                      "The main application window never showed up")

        // An empty input folder is ingested the same way as Add Files / drop.
        let banner = app.descendants(matching: .any)["intakeBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "The intake banner never showed up")
        XCTAssertTrue(banner.label.contains("Input"),
                      "The input folder was not seeded from UITEST_INPUT_DIR: \(banner.label)")
    }
}
