import XCTest
@testable import MP4SubRipCore

final class ExternalToolTests: XCTestCase {
    private let spec = ExternalToolSpec(name: "Demo", executables: ["demo", "demo-extract"], appBundlePrefix: "Demo")

    func testHomebrewBeatsAppBundleAndPath() {
        let existing: Set<String> = [
            "/opt/homebrew/bin/demo", "/opt/homebrew/bin/demo-extract",
            "/Applications/Demo.app/Contents/MacOS/demo", "/usr/bin/demo"
        ]
        let paths = ExternalTool.locate(spec, executableExists: { existing.contains($0) }, applications: ["Demo.app"], searchPath: "/usr/bin")
        XCTAssertEqual(paths?["demo"], "/opt/homebrew/bin/demo")
        XCTAssertEqual(paths?["demo-extract"], "/opt/homebrew/bin/demo-extract")
    }

    func testIntelHomebrewThenAppBundleThenPath() {
        let existing: Set<String> = ["/usr/local/bin/demo", "/Applications/Demo 2.app/Contents/MacOS/demo-extract"]
        let paths = ExternalTool.locate(spec, executableExists: { existing.contains($0) }, applications: ["Demo 2.app", "Other.app"], searchPath: "")
        XCTAssertEqual(paths?["demo"], "/usr/local/bin/demo")
        XCTAssertEqual(paths?["demo-extract"], "/Applications/Demo 2.app/Contents/MacOS/demo-extract")
    }

    func testHomebrewHitDoesNotListApplications() {
        let spec = ExternalToolSpec(name: "ffmpeg", executables: ["ffmpeg"], appBundlePrefix: "ffmpeg")
        var listed = false
        let paths = ExternalTool.locateInstalled(
            spec,
            executableExists: { $0 == "/opt/homebrew/bin/ffmpeg" },
            applicationNames: {
                listed = true
                return ["ffmpeg.app"]
            },
            searchPath: "/usr/bin"
        )
        XCTAssertEqual(paths?["ffmpeg"], "/opt/homebrew/bin/ffmpeg")
        XCTAssertFalse(listed)
    }

    func testAppBundleStillBeatsPathWhenHomebrewIsMissing() {
        let spec = ExternalToolSpec(name: "ffmpeg", executables: ["ffmpeg"], appBundlePrefix: "ffmpeg")
        let bundle = "/Applications/ffmpeg.app/Contents/MacOS/ffmpeg"
        let paths = ExternalTool.locateInstalled(
            spec,
            executableExists: { $0 == bundle || $0 == "/usr/bin/ffmpeg" },
            applicationNames: { ["ffmpeg.app"] },
            searchPath: "/usr/bin"
        )
        XCTAssertEqual(paths?["ffmpeg"], bundle)
    }

    func testRunnableFollowsARelativeSymlinkAndRejectsADirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp4subrip-tool-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("ffmpeg")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../ffmpeg")
        XCTAssertTrue(ExternalTool.isRunnable(link.path))
        XCTAssertTrue(ExternalTool.isRunnable(target.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        XCTAssertFalse(ExternalTool.isRunnable(target.path))
        XCTAssertFalse(ExternalTool.isRunnable(link.path))
        XCTAssertFalse(ExternalTool.isRunnable(bin.path))
    }

    func testDetectionLineAndHeaderShareOneResult() {
        let spec = ExternalToolSpec.primary
        let located = LocatedTool(
            name: "ffmpeg",
            path: "/opt/homebrew/bin/ffmpeg",
            version: "ffmpeg version 9.0.2"
        )
        let line = ToolDetection.logLine(spec: spec, located: located)
        XCTAssertFalse(line.isError)
        XCTAssertEqual(
            line.message,
            "ffmpeg found /opt/homebrew/bin/ffmpeg, version ffmpeg version 9.0.2"
        )
        XCTAssertFalse(line.message.contains("not found"))
        let facts = ToolDetection.facts(spec: spec, located: located)
        XCTAssertEqual(facts.map(\.label), ["ffmpeg", "ffmpeg version"])
        XCTAssertEqual(facts.map(\.value), ["/opt/homebrew/bin/ffmpeg", "ffmpeg version 9.0.2"])

        let missing = ToolDetection.logLine(spec: spec, located: nil)
        XCTAssertTrue(missing.isError)
        XCTAssertEqual(missing.message, "ffmpeg not found")
        XCTAssertEqual(ToolDetection.facts(spec: spec, located: nil).map(\.value), ["not found", "not found"])
    }

    func testPartialInstallCountsAsMissing() {
        let existing: Set<String> = ["/usr/bin/demo"]
        XCTAssertNil(ExternalTool.locate(spec, executableExists: { existing.contains($0) }, applications: [], searchPath: "/usr/bin"))
    }

    func testStderrIsFlattenedAndCut() {
        let long = String(repeating: "x", count: 2500)
        XCTAssertEqual(ToolCommandFormatting.stderrText(Data("a\nb\n".utf8)), "a b")
        XCTAssertEqual(ToolCommandFormatting.stderrText(Data(long.utf8))?.count, 2001)
        XCTAssertNil(ToolCommandFormatting.stderrText(Data()))
    }

    #if !os(Windows)
    func testRunReportsExitCodeAndCancels() async throws {
        let result = try await ToolCommand.run(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "out\n")

        let task = Task { try await ToolCommand.run(executable: "/bin/sleep", arguments: ["30"]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancel should throw")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        }
    }
    #endif
}
