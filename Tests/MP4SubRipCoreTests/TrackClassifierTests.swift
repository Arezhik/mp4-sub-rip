import XCTest
@testable import MP4SubRipCore

final class TrackClassifierTests: XCTestCase {
    func testTX3GIsExtractableAndPrefersTheISO6392Code() {
        let track = TrackClassifier.classify(discovered(codec: "tx3g", language: "eng", tag: "en-US"))
        XCTAssertTrue(track.isExtractable)
        XCTAssertEqual(track.kind, .text)
        XCTAssertNil(track.skipReason)
        XCTAssertEqual(track.languageCode, "eng")
        XCTAssertEqual(track.extendedLanguageTag, "en-US")
    }

    func testExtendedTagIsUsedWhenTheLanguageCodeIsMissing() {
        let track = TrackClassifier.classify(discovered(codec: "TX3G", language: "und", tag: "es-419"))
        XCTAssertEqual(track.languageCode, "es")
    }

    func testUnknownLanguageIsUnd() {
        let track = TrackClassifier.classify(discovered(codec: "tx3g", language: nil, tag: nil))
        XCTAssertEqual(track.languageCode, "und")
    }

    func testDiscreteEIA608IsExtractable() {
        let fromCaption = TrackClassifier.classify(discovered(codec: "c608", kind: .closedCaption))
        XCTAssertTrue(fromCaption.isExtractable)
        XCTAssertEqual(fromCaption.kind, .closedCaption)
        XCTAssertNil(fromCaption.skipReason)
        XCTAssertEqual(fromCaption.codec, "c608")

        let fromSubtitle = TrackClassifier.classify(discovered(codec: "C608", kind: .subtitle))
        XCTAssertTrue(fromSubtitle.isExtractable)
        XCTAssertEqual(fromSubtitle.codec, "c608")
    }

    func testCEA708AndInBandCaptionsAreReportedNotExtracted() {
        let c708 = TrackClassifier.classify(discovered(codec: "c708", kind: .subtitle))
        XCTAssertFalse(c708.isExtractable)
        XCTAssertEqual(c708.kind, .closedCaption)
        XCTAssertEqual(c708.skipReason, .closedCaption)
        XCTAssertEqual(c708.skipReason?.message, "Closed captions are not a text subtitle track.")

        let atcc = TrackClassifier.classify(discovered(codec: "atcc", kind: .closedCaption))
        XCTAssertEqual(atcc.skipReason, .closedCaption)

        // No discrete c608 sample: captions that live only in the video
        // bitstream stay report-only, and an empty discovery extracts nothing.
        let sei = TrackClassifier.classify(discovered(codec: "unknown", kind: .closedCaption))
        XCTAssertFalse(sei.isExtractable)
        XCTAssertEqual(sei.skipReason, .closedCaption)
        XCTAssertTrue(TrackClassifier.classifyAll([]).isEmpty)
    }

    func testBitmapCodecsAskForOCR() {
        let track = TrackClassifier.classify(discovered(codec: "mp4s"))
        XCTAssertEqual(track.kind, .bitmap)
        XCTAssertEqual(track.skipReason, .bitmap)
        XCTAssertEqual(track.skipReason?.message, "Image-based subtitles (needs OCR).")
    }

    func testWebVTTAndUnknownCodecsAreNamed() {
        XCTAssertEqual(TrackClassifier.classify(discovered(codec: "wvtt")).skipReason, .webVTT)
        let other = TrackClassifier.classify(discovered(codec: "text"))
        XCTAssertEqual(other.skipReason, .notText(codec: "text"))
        XCTAssertEqual(other.skipReason?.message, "Not a text subtitle track (text).")
    }

    func testForcedAndSDHComeFromTheTitleAndDisplayFlags() {
        let named = TrackClassifier.classify(discovered(codec: "tx3g", title: "English (Forced)"))
        XCTAssertTrue(named.isForced)
        XCTAssertTrue(named.hasForcedSamples)

        let sdh = TrackClassifier.classify(discovered(codec: "tx3g", title: "English SDH"))
        XCTAssertTrue(sdh.isSDH)
        XCTAssertFalse(sdh.isForced)

        let flags = TrackClassifier.classify(discovered(codec: "tx3g", flags: 0xC000_0000))
        XCTAssertTrue(flags.isForced)

        let some = TrackClassifier.classify(discovered(codec: "tx3g", flags: TX3GDisplayFlag.someSamplesForced))
        XCTAssertFalse(some.isForced)
        XCTAssertTrue(some.hasForcedSamples)
    }

    func testDuplicateTrackIDPrefersTX3GOverClosedCaptions() {
        let tracks = TrackClassifier.classifyAll([
            discovered(id: 4, codec: "c608", kind: .closedCaption, language: "fra"),
            discovered(id: 4, codec: "tx3g", kind: .text, language: "eng"),
            discovered(id: 4, codec: "tx3g", kind: .subtitle, language: "spa")
        ])
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].codec, "tx3g")
        XCTAssertTrue(tracks[0].isExtractable)
        XCTAssertEqual(tracks[0].languageCode, "eng")
    }

    private func discovered(
        id: Int = 1,
        codec: String,
        kind: SubtitleMediaKind = .text,
        language: String? = "eng",
        tag: String? = nil,
        title: String? = nil,
        flags: UInt32? = nil
    ) -> DiscoveredMediaTrack {
        DiscoveredMediaTrack(
            trackID: id,
            mediaKind: kind,
            codec: codec,
            languageCode: language,
            extendedLanguageTag: tag,
            title: title,
            displayFlags: flags
        )
    }
}
