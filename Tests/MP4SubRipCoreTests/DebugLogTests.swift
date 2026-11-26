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

    func testConcurrentRecordsStayIntact() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("debuglog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = DebugLog(homeDirectory: "/Users/ada", timeZone: TimeZone(identifier: "UTC")!)
        log.configure(directory: folder, maxTotalBytes: 5_000_000, fileCount: 3)
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            log.record(.work, "marker \(index) /Users/ada/Movies/clip.mp4")
        }
        let text = log.recentText()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 40)
        for index in 0..<40 {
            XCTAssertEqual(lines.filter { $0.contains("marker \(index) ~/Movies/clip.mp4") }.count, 1)
        }
        XCTAssertFalse(text.contains("/Users/ada/"))
        for line in lines {
            XCTAssertTrue(line.contains("[work] info "))
            XCTAssertFalse(line.contains("marker") && line.contains("payload"))
        }
    }

    func testSharedLogAcceptsConcurrentRecords() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("debuglog-shared-\(UUID().uuidString)", isDirectory: true)
        defer {
            DebugLog.shared.reset()
            try? FileManager.default.removeItem(at: folder)
        }
        DebugLog.shared.reset()
        DebugLog.shared.configure(
            directory: folder,
            maxTotalBytes: 5_000_000,
            fileCount: 3,
            homeDirectory: "/Users/ada",
            timeZone: TimeZone(identifier: "UTC")!
        )
        DispatchQueue.concurrentPerform(iterations: 30) { index in
            DebugLog.shared.record(.queue, "shared \(index) /Users/ada/Movies/a.mp4")
        }
        let text = DebugLog.shared.recentText()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 30)
        for index in 0..<30 {
            XCTAssertTrue(text.contains("shared \(index) ~/Movies/a.mp4"))
        }
        XCTAssertFalse(text.contains("/Users/ada/"))
    }

    func testRollingLogStoreAppendsFromSeveralThreads() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rolling-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RollingLogStore(directory: folder, maxTotalBytes: 5_000_000, fileCount: 3)
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            store.append("row \(index) payload")
        }
        let text = store.combinedText()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 40)
        for index in 0..<40 {
            XCTAssertTrue(lines.contains("row \(index) payload"))
        }
        for line in lines {
            XCTAssertTrue(line.hasPrefix("row "))
            XCTAssertTrue(line.hasSuffix("payload"))
            XCTAssertEqual(line.components(separatedBy: "payload").count, 2)
        }
    }
}
