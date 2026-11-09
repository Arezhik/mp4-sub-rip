import XCTest
@testable import MP4SubRipCore

final class SubtitleNamingTests: XCTestCase {
    func testOneTrackOmitsTheLanguage() {
        let names = SubtitleFileNames.names(
            baseName: "Movie",
            tracks: [text(1, "eng", forced: true)],
            alwaysIncludeLanguageCode: false
        )
        XCTAssertEqual(names, [1: "Movie.srt"])
    }

    func testAlwaysIncludeLanguageKeepsForcedOnASingleTrack() {
        let names = SubtitleFileNames.names(
            baseName: "Movie",
            tracks: [text(1, "eng", forced: true)],
            alwaysIncludeLanguageCode: true
        )
        XCTAssertEqual(names, [1: "Movie.eng.forced.srt"])
    }

    func testSeveralLanguages() {
        let names = SubtitleFileNames.names(
            baseName: "Movie",
            tracks: [text(1, "eng"), text(2, "spa")],
            alwaysIncludeLanguageCode: false
        )
        XCTAssertEqual(names, [1: "Movie.eng.srt", 2: "Movie.spa.srt"])
    }

    func testForcedAndSDHAreMarked() {
        let names = SubtitleFileNames.names(
            baseName: "Movie",
            tracks: [text(1, "eng"), text(2, "eng", forced: true), text(3, "eng", sdh: true)],
            alwaysIncludeLanguageCode: false
        )
        XCTAssertEqual(names, [
            1: "Movie.eng.srt",
            2: "Movie.eng.forced.srt",
            3: "Movie.eng.sdh.srt"
        ])
    }

    func testDuplicateLanguagesGetAnIndex() {
        let names = SubtitleFileNames.names(
            baseName: "Movie",
            tracks: [text(1, "eng"), text(2, "eng"), text(3, "und")],
            alwaysIncludeLanguageCode: false
        )
        XCTAssertEqual(names, [
            1: "Movie.eng.srt",
            2: "Movie.eng.2.srt",
            3: "Movie.und.srt"
        ])
    }

    func testDuplicateLanguagesUseATitleBeforeAnIndex() {
        let names = SubtitleFileNames.names(
            baseName: "Movie",
            tracks: [text(1, "eng", title: "Commentary"), text(2, "eng")],
            alwaysIncludeLanguageCode: false
        )
        XCTAssertEqual(names, [1: "Movie.eng.commentary.srt", 2: "Movie.eng.srt"])
    }

    func testIdenticalTitlesStillGetAnIndex() {
        let names = SubtitleFileNames.names(
            baseName: "Movie",
            tracks: [text(1, "eng", title: "Commentary"), text(2, "eng", title: "Commentary!")],
            alwaysIncludeLanguageCode: false
        )
        XCTAssertEqual(names, [
            1: "Movie.eng.commentary.srt",
            2: "Movie.eng.commentary.2.srt"
        ])
    }

    func testTwoForcedTracksOfTheSameLanguage() {
        let names = SubtitleFileNames.names(
            baseName: "Movie",
            tracks: [text(1, "eng", forced: true), text(2, "eng", forced: true)],
            alwaysIncludeLanguageCode: false
        )
        XCTAssertEqual(names, [1: "Movie.eng.forced.srt", 2: "Movie.eng.forced.2.srt"])
    }

    func testBaseNameDropsOnlyTheExtension() {
        XCTAssertEqual(SubtitleFileNames.baseName(forFile: "/Films/My.Movie.mp4"), "My.Movie")
    }

    func testKeepBothInsertsTheNumberBeforeSRT() {
        XCTAssertEqual(SubtitleFileNames.numbered("Movie.eng.srt", index: 1), "Movie.eng (1).srt")
    }

    func testNonExtractableTracksAreNotNamed() {
        var bitmap = text(9, "eng")
        bitmap.isExtractable = false
        bitmap.kind = .bitmap
        let names = SubtitleFileNames.names(
            baseName: "Movie",
            tracks: [bitmap, text(1, "spa")],
            alwaysIncludeLanguageCode: false
        )
        XCTAssertEqual(names, [1: "Movie.srt"])
    }

    private func text(
        _ id: Int,
        _ language: String,
        title: String? = nil,
        forced: Bool = false,
        sdh: Bool = false
    ) -> SubtitleTrack {
        SubtitleTrack(
            id: id,
            languageCode: language,
            title: title,
            kind: .text,
            codec: "tx3g",
            isForced: forced,
            hasForcedSamples: forced,
            isSDH: sdh,
            isExtractable: true
        )
    }
}
