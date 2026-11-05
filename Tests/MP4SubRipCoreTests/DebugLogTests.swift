import Foundation
import XCTest
@testable import MP4SubRipCore

final class DebugLogTests: XCTestCase {
    func testHomeFolderBecomesTildeOnlyAtAPathBoundary() {
        let text = "/Users/ada/Movies/a.file and /Users/ada2/b.file"
        let redacted = PathRedaction.redact(text, homeDirectory: "/Users/ada")
        XCTAssertEqual(redacted, "~/Movies/a.file and /Users/ada2/b.file")
    }

    func testHeaderListsMachineFactsAndExtraFacts() {
        let environment = DebugEnvironment(
            appVersion: "0.1.0",
            appBuild: "1",
            operatingSystem: "Version 15.8",
            model: "MacPro7,1",
            chip: DebugChip.label(architecture: "x86_64", runningUnderRosetta: false),
            architecture: "x86_64",
            runningUnderRosetta: false,
            facts: [DebugFact("Tool", "/usr/local/bin/tool"), DebugFact("Tool version", "v1")],
            settings: "defaults"
        )
        let header = DebugLogDocument.header(for: environment)
        XCTAssertTrue(header.hasPrefix("\(AppIdentity.name) debug log"))
        XCTAssertTrue(header.contains("Chip: Intel"))
        XCTAssertTrue(header.contains("Tool version: v1"))
        XCTAssertTrue(header.hasSuffix("Settings: defaults"))
    }

    func testFileNameUsesAppNameAndLocalTime() {
        let date = Date(timeIntervalSince1970: 0)
        let name = DebugLogDocument.fileName(at: date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(name, "\(AppIdentity.name)-debug-log-1970-01-01-000000.txt")
    }

    func testRecordWritesRedactedLinesAndRotates() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("debuglog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = DebugLog(homeDirectory: "/Users/ada", timeZone: TimeZone(identifier: "UTC")!)
        log.configure(directory: folder, maxTotalBytes: 600, fileCount: 3)
        for index in 0..<20 {
            log.record(.queue, "Added /Users/ada/Movies/file\(index).input")
        }
        let text = log.recentText()
        XCTAssertTrue(text.contains("~/Movies/file19.input"))
        XCTAssertFalse(text.contains("/Users/ada/"))
        XCTAssertFalse(text.contains("file0.input"), "the oldest lines rotate out")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertLessThanOrEqual(files.count, 3)
    }

    func testUnconfiguredLogDoesNothing() {
        let log = DebugLog()
        log.record(.error, "ignored", isError: true)
        XCTAssertEqual(log.recentText(), "")
    }
}
