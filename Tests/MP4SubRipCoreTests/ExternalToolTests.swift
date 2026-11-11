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
            version: "ffmpeg version 9.0.2",
            source: .automatic
        )
        let line = ToolDetection.logLine(spec: spec, located: located, customPath: nil)
        XCTAssertFalse(line.isError)
        XCTAssertEqual(
            line.message,
            "ffmpeg found (automatic) /opt/homebrew/bin/ffmpeg, version ffmpeg version 9.0.2"
        )
        XCTAssertFalse(line.message.contains("not found"))
        let facts = ToolDetection.facts(spec: spec, located: located, customPath: nil)
        XCTAssertEqual(facts.map(\.label), ["ffmpeg", "ffmpeg version"])
        XCTAssertEqual(facts.map(\.value), ["(automatic) /opt/homebrew/bin/ffmpeg", "ffmpeg version 9.0.2"])

        let chosen = LocatedTool(
            name: "ffmpeg",
            path: "/Users/me/bin/ffmpeg",
            version: "ffmpeg version 9.0.2",
            source: .chosenInSettings
        )
        let chosenLine = ToolDetection.logLine(spec: spec, located: chosen, customPath: chosen.path)
        let chosenFacts = ToolDetection.facts(spec: spec, located: chosen, customPath: chosen.path)
        XCTAssertEqual(
            chosenLine.message,
            "ffmpeg found (chosen in Settings) /Users/me/bin/ffmpeg, version ffmpeg version 9.0.2"
        )
        XCTAssertEqual(chosenFacts.map(\.label), ["ffmpeg", "ffmpeg version"])
        XCTAssertEqual(
            chosenFacts.map(\.value),
            ["(chosen in Settings) /Users/me/bin/ffmpeg", "ffmpeg version 9.0.2"]
        )

        let missing = ToolDetection.logLine(spec: spec, located: nil)
        XCTAssertTrue(missing.isError)
        XCTAssertEqual(missing.message, "ffmpeg not found")
        XCTAssertEqual(ToolDetection.facts(spec: spec, located: nil).map(\.value), ["not found", "not found"])

        let stale = "/Users/me/bin/ffmpeg"
        let staleLine = ToolDetection.logLine(spec: spec, located: nil, customPath: stale)
        let staleFacts = ToolDetection.facts(spec: spec, located: nil, customPath: stale)
        XCTAssertEqual(
            staleLine.message,
            "ffmpeg not found (chosen in Settings) \(stale); automatic was not used"
        )
        XCTAssertFalse(staleLine.message.contains("/opt/homebrew"))
        XCTAssertEqual(
            staleFacts.map(\.value),
            ["not found (chosen in Settings) \(stale); automatic was not used", "not found"]
        )

        let unchosenLine = ToolDetection.logLine(spec: spec, located: nil, customPath: "")
        let unchosenFacts = ToolDetection.facts(spec: spec, located: nil, customPath: "")
        XCTAssertEqual(unchosenLine.message, "ffmpeg not chosen")
        XCTAssertEqual(unchosenFacts.map(\.value), ["not chosen", "not found"])
    }

    func testCustomPathWinsOverHomebrewAndPath() {
        let spec = ExternalToolSpec.primary
        let custom = "/Users/me/bin/ffmpeg"
        let existing: Set<String> = [
            custom,
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
            "/Applications/ffmpeg.app/Contents/MacOS/ffmpeg"
        ]
        let paths = ExternalTool.locate(
            spec,
            customPath: custom,
            executableExists: { existing.contains($0) },
            applications: ["ffmpeg.app"],
            searchPath: "/usr/bin:/opt/homebrew/bin"
        )
        XCTAssertEqual(paths?["ffmpeg"], custom)
    }

    func testMissingOrUnrunnableCustomPathDoesNotUseAutomatic() {
        let spec = ExternalToolSpec.primary
        var listed = false
        let paths = ExternalTool.locateInstalled(
            spec,
            customPath: "/Users/me/bin/ffmpeg",
            executableExists: { $0 == "/opt/homebrew/bin/ffmpeg" || $0 == "/usr/bin/ffmpeg" },
            applicationNames: {
                listed = true
                return ["ffmpeg.app"]
            },
            searchPath: "/usr/bin"
        )
        XCTAssertNil(paths)
        XCTAssertFalse(listed)

        let empty = ExternalTool.locateInstalled(
            spec,
            customPath: "",
            executableExists: { $0 == "/opt/homebrew/bin/ffmpeg" },
            applicationNames: {
                listed = true
                return ["ffmpeg.app"]
            },
            searchPath: "/usr/bin"
        )
        XCTAssertNil(empty)
        XCTAssertFalse(listed)
    }

    func testCustomPathResolvesAppFolderAndFile() {
        func resolve(_ path: String, existing: Set<String>) -> String? {
            ExternalTool.resolveCustom(path, executable: "ffmpeg", executableExists: { existing.contains($0) })
        }
        XCTAssertEqual(
            resolve("/Apps/ffmpeg.app", existing: ["/Apps/ffmpeg.app/Contents/MacOS/ffmpeg"]),
            "/Apps/ffmpeg.app/Contents/MacOS/ffmpeg"
        )
        XCTAssertEqual(
            resolve("/Apps/ffmpeg.app/", existing: ["/Apps/ffmpeg.app/Contents/MacOS/ffmpeg"]),
            "/Apps/ffmpeg.app/Contents/MacOS/ffmpeg"
        )
        XCTAssertNil(resolve("/Apps/ffmpeg.app", existing: ["/Apps/ffmpeg.app/bin/ffmpeg"]))
        XCTAssertEqual(
            resolve("/Tools", existing: ["/Tools/bin/ffmpeg"]),
            "/Tools/bin/ffmpeg"
        )
        XCTAssertEqual(
            resolve("/Tools", existing: ["/Tools/ffmpeg", "/Tools/bin/ffmpeg"]),
            "/Tools/ffmpeg"
        )
        XCTAssertEqual(
            resolve("/Wrapped", existing: ["/Wrapped/Contents/MacOS/ffmpeg"]),
            "/Wrapped/Contents/MacOS/ffmpeg"
        )
        XCTAssertEqual(
            resolve("/Users/me/bin/ffmpeg", existing: ["/Users/me/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"]),
            "/Users/me/bin/ffmpeg"
        )
        XCTAssertNil(resolve("/empty", existing: ["/opt/homebrew/bin/ffmpeg"]))
    }

    func testChosenExecutableMustReportFFmpeg() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp4subrip-ffmpeg-choice-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bad = root.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\necho hello\n".utf8).write(to: bad)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bad.path)
        XCTAssertNil(FFmpegSettings.validatedExecutable(at: bad.path))
        XCTAssertEqual(
            ExternalTool.resolveCustom(bad.path, executable: "ffmpeg", executableExists: ExternalTool.isRunnable),
            bad.path
        )

        let appPath = root.appendingPathComponent("ffmpeg.app").path
        let innerPath = appPath + "/Contents/MacOS/ffmpeg"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: innerPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\necho ffmpeg version test\n".utf8).write(to: URL(fileURLWithPath: innerPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: innerPath)
        XCTAssertEqual(FFmpegSettings.validatedExecutable(at: appPath), innerPath)

        let folderPath = root.appendingPathComponent("dist").path
        let goodPath = folderPath + "/bin/ffmpeg"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: goodPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\necho FFMPEG version 1\n".utf8).write(to: URL(fileURLWithPath: goodPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: goodPath)
        XCTAssertEqual(FFmpegSettings.validatedExecutable(at: folderPath), goodPath)

        let report = ExternalTool.describe(.primary, customPath: innerPath)
        XCTAssertEqual(report.customPath, innerPath)
        XCTAssertEqual(report.located?.source, .chosenInSettings)
        XCTAssertEqual(report.located?.path, innerPath)
        XCTAssertEqual(report.located?.version, "ffmpeg version test")
        let line = ToolDetection.logLine(spec: .primary, located: report.located, customPath: report.customPath)
        let facts = ToolDetection.facts(spec: .primary, located: report.located, customPath: report.customPath)
        XCTAssertEqual(
            line.message,
            "ffmpeg found (chosen in Settings) \(innerPath), version ffmpeg version test"
        )
        XCTAssertEqual(facts.map(\.value), ["(chosen in Settings) \(innerPath)", "ffmpeg version test"])

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: goodPath)
        XCTAssertNil(FFmpegSettings.validatedExecutable(at: goodPath))
        XCTAssertNil(FFmpegSettings.runnableExecutable(at: goodPath))
    }

    func testFFmpegSummaryAndSkipMessages() {
        XCTAssertEqual(
            FFmpegSettings.summary(customPath: nil, resolvedPath: "/opt/homebrew/bin/ffmpeg"),
            "ffmpeg automatic /opt/homebrew/bin/ffmpeg"
        )
        XCTAssertEqual(FFmpegSettings.summary(customPath: nil, resolvedPath: nil), "ffmpeg not found")
        XCTAssertEqual(FFmpegSettings.summary(customPath: "", resolvedPath: nil), "ffmpeg not chosen")
        XCTAssertEqual(
            FFmpegSettings.summary(customPath: "/Users/me/bin/ffmpeg", resolvedPath: nil),
            "ffmpeg chosen /Users/me/bin/ffmpeg"
        )
        XCTAssertEqual(
            FFmpegSettings.installationMessage(customPath: nil),
            "Closed-caption extraction needs ffmpeg. Install it with Homebrew, or choose it in Settings."
        )
        XCTAssertEqual(FFmpegSettings.installationMessage(customPath: ""), "Choose ffmpeg in Settings.")
        XCTAssertEqual(
            FFmpegSettings.installationMessage(customPath: "/Users/me/bin/ffmpeg"),
            "The ffmpeg chosen in Settings can't be found. Choose it again in Settings."
        )
        XCTAssertEqual(
            ToolFailure.notInstalled("ffmpeg").errorDescription,
            SubtitleSkipReason.needsFFmpeg.message as String?
        )
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
