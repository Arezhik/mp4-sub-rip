import XCTest
@testable import MP4SubRipCore

final class QueuePresentationTests: XCTestCase {
    private let names: @Sendable (String) -> String? = { code in
        switch code {
        case "en": return "English"
        case "es": return "Spanish"
        case "fr": return "French"
        default: return nil
        }
    }

    func testChipsUseLanguageNamesCaptionsAndImageOutlines() {
        let tracks = [
            text(1, "eng", forced: true),
            text(2, "spa", sdh: true),
            caption(3, "eng"),
            bitmap(4, "eng", codec: "pgs1"),
            bitmap(5, "und", codec: "vobs")
        ]
        let chips = TrackChips.chips(tracks: tracks, languageName: names)
        XCTAssertEqual(chips.map(\.style), [.text, .text, .caption, .bitmap, .bitmap])
        XCTAssertEqual(chips.map(\.title), [
            "English",
            "Spanish",
            "CC (eng) · c608",
            "PGS · English",
            "VobSub"
        ])
        XCTAssertEqual(chips.map(\.mark), ["Forced", "SDH", nil, nil, nil])
        XCTAssertEqual(chips[2].symbol, "captions.bubble")
        XCTAssertEqual(chips[3].symbol, "photo")
        XCTAssertNil(chips[0].symbol)
        let help = TrackChips.columnHelp(tracks: [bitmap(4, "eng", codec: "pgs1")], languageName: names)
        XCTAssertEqual(
            help,
            "English (PGS, image-based): can't be extracted as text. Open this video in PGS2SRT to OCR it."
        )
    }

    func testProbeSettlesNothingToExtract() {
        XCTAssertEqual(ProbeRules.settle([text(1, "eng")]), .waiting)
        XCTAssertEqual(ProbeRules.settle([text(1, "eng"), bitmap(2, "eng", codec: "vobs")]), .waiting)
        XCTAssertEqual(ProbeRules.settle([]), .noSubtitles(note: nil))
        XCTAssertEqual(ProbeRules.settle([bitmap(1, "eng", codec: "mp4s")]), .imageSubsOnly)
        let caption = SubtitleTrack(
            id: 1,
            languageCode: "eng",
            kind: .closedCaption,
            codec: "c708",
            isExtractable: false,
            skipReason: .closedCaption
        )
        XCTAssertEqual(
            ProbeRules.settle([caption]),
            .noSubtitles(note: SubtitleSkipReason.closedCaption.message)
        )
    }

    func testOutcomeStatusKeepsPartialSkipsOnDone() {
        let written = WrittenSubtitle(trackID: 1, path: "/out/A.eng.srt", cueCount: 1, languageCode: "eng", isForced: false)
        let existing = ExistingSubtitleOutput(trackID: 2, path: "/out/A.spa.srt")
        let partial = QueueOutcome.status(for: ExtractionOutcome(
            written: [written],
            skipped: [SkippedSubtitle(trackID: 3, reason: .bitmap)],
            alreadyExists: [existing]
        ))
        XCTAssertEqual(partial, .done(written: ["/out/A.eng.srt"], skippedExists: ["/out/A.spa.srt"]))
        let item = QueueItem(
            path: "/in/A.mp4",
            status: partial,
            tracks: [text(1, "eng"), bitmap(3, "fra", codec: "vobs")]
        )
        XCTAssertEqual(item.status.summary, "Done · 1 file")
        XCTAssertEqual(QueueRowText.help(for: item, languageName: names), "1 skipped (exists): A.spa.srt")
        guard case let .files(first, extra, help) = OutputColumnBuilder.make(for: item) else {
            return XCTFail("expected file names")
        }
        XCTAssertEqual(first, "A.eng.srt")
        XCTAssertEqual(extra, 1)
        XCTAssertTrue(help.contains("/out/A.spa.srt"))
        XCTAssertTrue(help.contains("1 skipped (exists): A.spa.srt"))
        XCTAssertTrue(help.contains("VobSub track skipped (image-based)"))
    }

    func testAllExistingOutputsAreSkippedExists() {
        let status = QueueOutcome.status(for: ExtractionOutcome(
            written: [],
            skipped: [],
            alreadyExists: [ExistingSubtitleOutput(trackID: 1, path: "/out/Movie.srt")]
        ))
        XCTAssertEqual(status, .skippedExists(paths: ["/out/Movie.srt"]))
        XCTAssertEqual(status.summary, "Done · skipped (exists)")
        XCTAssertFalse(status.canRetry)
        XCTAssertTrue(status.clearsWithProcessed)
    }

    func testOutputColumnBeforeExtractAndForRowsWithNothingToWrite() {
        let movie = QueueItem(
            path: "/Movies/Dune Part Two.mp4",
            status: .waiting,
            tracks: [text(1, "eng"), text(2, "spa"), bitmap(3, "eng", codec: "pgs1")]
        )
        guard case let .files(first, extra, help) = OutputColumnBuilder.make(for: movie) else {
            return XCTFail("expected predicted names")
        }
        XCTAssertEqual(first, "Dune Part Two.eng.srt")
        XCTAssertEqual(extra, 1)
        XCTAssertTrue(help.contains("Dune Part Two.spa.srt"))
        XCTAssertTrue(help.contains("PGS track skipped (image-based)"))

        let single = QueueItem(path: "/Movies/Dune.mp4", status: .waiting, tracks: [text(1, "eng")])
        guard case let .files(only, none, _) = OutputColumnBuilder.make(for: single) else {
            return XCTFail("expected one name")
        }
        XCTAssertEqual(only, "Dune.srt")
        XCTAssertEqual(none, 0)

        XCTAssertEqual(OutputColumnBuilder.make(for: QueueItem(path: "/a.mp4", status: .noSubtitles)), .dash)
        XCTAssertEqual(OutputColumnBuilder.make(for: QueueItem(path: "/a.mp4", status: .imageSubsOnly)), .needsOCR)
        XCTAssertEqual(
            OutputColumnBuilder.make(for: QueueItem(path: "/a.mp4", status: .failed(reason: "Folder is read-only."))),
            .dash
        )
    }

    func testFailureLineStaysShort() {
        XCTAssertEqual(FailureLine.short("Folder is read-only."), "Read-only folder")
        XCTAssertEqual(FailureLine.short("Choose an output folder in Settings."), "Choose a folder")
        let long = String(repeating: "a", count: 40)
        XCTAssertEqual(FailureLine.short(long), String(repeating: "a", count: 19) + "…")
    }

    func testRemoveKeepsTheExtractingRowAndRetryReturnsToPending() {
        let working = QueueItem(id: UUID(), path: "/a.mp4", status: .working(completed: 1, total: 2), tracks: [text(1, "eng")])
        let pending = QueueItem(path: "/b.mp4", status: .waiting)
        let failed = QueueItem(path: "/c.mp4", status: .failed(reason: "Folder is read-only."), tracks: [text(1, "spa")])
        let left = QueueHousekeeping.removing([working, pending, failed], ids: [working.id, pending.id, failed.id])
        XCTAssertEqual(left.map(\.id), [working.id])
        let retried = QueueHousekeeping.retrying([failed], ids: [failed.id])
        XCTAssertEqual(retried[0].status, .waiting)
        XCTAssertEqual(retried[0].tracks, failed.tracks)
    }

    func testRowActionsHideWhatDoesNotApply() {
        let failed = QueueItem(path: "/a.mp4", status: .failed(reason: "x"))
        let done = QueueItem(path: "/b.mp4", status: .done(written: ["/b.srt"], skippedExists: []))
        let working = QueueItem(path: "/c.mp4", status: .working(completed: 0, total: 1))
        let failedActions = RowActionSet.forSelection([failed], ids: [failed.id])
        XCTAssertTrue(failedActions.retry)
        XCTAssertTrue(failedActions.showError)
        XCTAssertFalse(failedActions.reveal)
        XCTAssertTrue(failedActions.showVideo)
        XCTAssertFalse(failedActions.openSubtitle)
        XCTAssertTrue(failedActions.remove)
        let doneActions = RowActionSet.forSelection([done], ids: [done.id])
        XCTAssertFalse(doneActions.retry)
        XCTAssertTrue(doneActions.reveal)
        XCTAssertTrue(doneActions.openSubtitle)
        XCTAssertFalse(RowActionSet.forSelection([working], ids: [working.id]).remove)
        XCTAssertEqual(RowActionSet.forSelection([failed, done], ids: []), RowActionSet())
    }

    func testRevealSelectsOnlyFilesThatExist() {
        let paths = ["/out/One.srt", "/out/Two.srt"]
        let some = RevealRules.plan(paths: paths, fileExists: { $0.hasSuffix("One.srt") }, directoryExists: { _ in true })
        XCTAssertEqual(some, .file("/out/One.srt"))
        let none = RevealRules.plan(
            paths: ["/out/One.srt"],
            fileExists: { _ in false },
            directoryExists: { $0 == "/out" },
            missingGroupName: "The subtitle files"
        )
        XCTAssertEqual(none, .missing(name: "One.srt", folder: "/out", folderExists: true))
        let many = RevealRules.plan(
            paths: paths,
            fileExists: { _ in false },
            directoryExists: { _ in false },
            missingGroupName: "The subtitle files"
        )
        XCTAssertEqual(many, .missing(name: "The subtitle files", folder: "/out", folderExists: false))
        XCTAssertEqual(RevealRules.plan(paths: [], fileExists: { _ in true }, directoryExists: { _ in true }), .nothing)
    }

    func testRevealOneFileSelectsThatFile() {
        XCTAssertEqual(
            RevealRules.selectFileAPI,
            "NSWorkspace.selectFile(_:inFileViewerRootedAtPath:)"
        )
        let action = RevealRules.plan(
            paths: ["/out/One.srt", "/out/One.srt"],
            fileExists: { _ in true },
            directoryExists: { _ in true }
        )
        XCTAssertEqual(action, .file("/out/One.srt"))
        XCTAssertEqual(
            RevealRules.existing(paths: ["/out/One.srt", "/out/One.srt", "/out/Two.srt"], fileExists: { $0.hasSuffix("One.srt") }),
            ["/out/One.srt"]
        )
    }

    func testRevealSharedParentOpensThatFolder() {
        let action = RevealRules.plan(
            paths: ["/out/a/One.srt", "/out/a/Two.srt", "/out/a/One.srt"],
            fileExists: { _ in true },
            directoryExists: { _ in true }
        )
        XCTAssertEqual(action, .folders(["/out/a"]))
    }

    func testRevealMultipleParentsKeepsFirstSeenOrder() {
        let action = RevealRules.plan(
            paths: [
                "/vol/a/../b/One.srt",
                "/vol/a/Two.srt",
                "/vol/b/Three.srt",
                "/vol/missing/Gone.srt"
            ],
            fileExists: { !$0.contains("missing") },
            directoryExists: { _ in true }
        )
        XCTAssertEqual(action, .folders(["/vol/b", "/vol/a"]))
    }

    func testRevealMissingOutputsDoesNotOpenFinder() {
        let action = RevealRules.plan(
            paths: ["/out/a/One.srt", "/out/b/Two.srt"],
            fileExists: { _ in false },
            directoryExists: { $0 == "/out/a" },
            missingGroupName: "The subtitle files"
        )
        XCTAssertEqual(action, .missing(name: "The subtitle files", folder: "/out/a", folderExists: true))
        XCTAssertEqual(
            RevealRules.existing(paths: ["/out/a/One.srt"], fileExists: { _ in false }),
            []
        )
    }

    func testRecentFoldersStayAtThreeAndDropMissing() {
        var records: [RecentFolderRecord] = []
        records = RecentFolderList.remembering("/Movies/Subtitles/", bookmark: Data([1]), in: records)
        records = RecentFolderList.remembering("/Movies/Subs", bookmark: Data([2]), in: records)
        records = RecentFolderList.remembering("/Desktop/Exports", bookmark: Data([3]), in: records)
        records = RecentFolderList.remembering("/Volumes/Media/Subs", bookmark: Data([4]), in: records)
        XCTAssertEqual(records.map(\.path), ["/Volumes/Media/Subs", "/Desktop/Exports", "/Movies/Subs"])
        records = RecentFolderList.remembering("/Movies/Subs/", bookmark: nil, in: records)
        XCTAssertEqual(records.map(\.path), ["/Movies/Subs", "/Volumes/Media/Subs", "/Desktop/Exports"])
        XCTAssertEqual(records[0].bookmark, Data([2]))
        let kept = RecentFolderList.droppingMissing(records) { $0 == "/Movies/Subs" }
        XCTAssertEqual(kept.map(\.path), ["/Movies/Subs"])
        let moved = RecentFolderList.refreshing(records) { record in
            record.path == "/Movies/Subs" ? "/Volumes/New" : record.path
        }
        XCTAssertEqual(moved.first?.path, "/Volumes/New")
        XCTAssertEqual(moved.first?.bookmark, Data([2]))
    }

    func testRecentFoldersRoundTripThroughDefaults() throws {
        let suite = "mp4subrip.tests.recents.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let saved = RecentFolderList.remembering("/Movies/Subtitles", bookmark: Data([9, 8, 7]), in: [])
        RecentFolderList.save(saved, to: defaults)
        XCTAssertEqual(RecentFolderList.load(defaults), saved)
        defaults.removePersistentDomain(forName: suite)
    }

    func testSummaryAndAbbreviatedPaths() {
        XCTAssertEqual(QueueSummaryLine.text(files: 7, textTracks: 9), "7 files · 9 text tracks")
        XCTAssertEqual(QueueSummaryLine.text(files: 1, textTracks: 1), "1 file · 1 text track")
        XCTAssertEqual(DisplayPath.abbreviated("/Users/arezhik/Movies/Subs", home: "/Users/arezhik"), "~/Movies/Subs")
        XCTAssertEqual(DisplayPath.parent("/Users/arezhik/Movies/A.mp4", home: "/Users/arezhik"), "~/Movies")
        XCTAssertEqual(DisplayPath.folderName("/Users/arezhik/Movies/Subs"), "Subs")
        XCTAssertEqual(LanguageDisplay.name(for: "und", localized: names), "Unknown")
        XCTAssertEqual(LanguageDisplay.name(for: "eng", localized: names), "English")
    }

    func testSelectionFlagsFollowTheSelectedRow() {
        let failed = QueueItem(id: UUID(), path: "/a.mp4", status: .failed(reason: "x"))
        let flags = CommandFlags.from([failed], selection: [failed.id])
        XCTAssertTrue(flags.canRetry)
        XCTAssertTrue(flags.canShowError)
        XCTAssertTrue(flags.canShowVideo)
        XCTAssertTrue(flags.canRemoveSelection)
        XCTAssertFalse(flags.canReveal)
        XCTAssertFalse(CommandFlags.from([failed]).canRetry)
    }

    private func text(_ id: Int, _ language: String, forced: Bool = false, sdh: Bool = false) -> SubtitleTrack {
        SubtitleTrack(
            id: id,
            languageCode: language,
            kind: .text,
            codec: "tx3g",
            isForced: forced,
            isSDH: sdh,
            isExtractable: true
        )
    }

    private func caption(_ id: Int, _ language: String) -> SubtitleTrack {
        SubtitleTrack(
            id: id,
            languageCode: language,
            kind: .closedCaption,
            codec: "c608",
            isExtractable: true
        )
    }

    private func bitmap(_ id: Int, _ language: String, codec: String) -> SubtitleTrack {
        SubtitleTrack(
            id: id,
            languageCode: language,
            kind: .bitmap,
            codec: codec,
            isExtractable: false,
            skipReason: .bitmap
        )
    }
}
