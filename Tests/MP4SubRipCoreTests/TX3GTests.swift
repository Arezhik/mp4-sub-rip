import XCTest
@testable import MP4SubRipCore

final class TX3GTests: XCTestCase {
    func testUTF8Text() {
        let parsed = TX3GSample.parse(sample("Hello"))
        XCTAssertEqual(parsed, .cue(text: "Hello", isForced: false))
    }

    func testPlainTextIsNotEscaped() {
        let parsed = TX3GSample.parse(sample("5 < 10"))
        XCTAssertEqual(parsed, .cue(text: "5 < 10", isForced: false))
    }

    func testUTF16BigEndian() {
        let body = Data([0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69])
        let parsed = TX3GSample.parse(sample(body))
        XCTAssertEqual(parsed, .cue(text: "Hi", isForced: false))
    }

    func testUTF16LittleEndian() {
        let body = Data([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00])
        let parsed = TX3GSample.parse(sample(body))
        XCTAssertEqual(parsed, .cue(text: "Hi", isForced: false))
    }

    func testUTF8BOMIsStripped() {
        var body = Data([0xEF, 0xBB, 0xBF])
        body.append(Data("Hello".utf8))
        XCTAssertEqual(TX3GSample.parse(sample(body)), .cue(text: "Hello", isForced: false))
    }

    func testEmptySampleIsAGap() {
        XCTAssertEqual(TX3GSample.parse(sample(Data())), .gap)
        XCTAssertEqual(TX3GSample.parse(Data([0x00, 0x00])), .gap)
    }

    func testEmptySampleWithForcedAtomIsStillAGap() {
        let bytes = Data([0x00, 0x00]) + atom("frcd", Data())
        XCTAssertEqual(TX3GSample.parse(bytes), .gap)
    }

    func testForcedAtomMarksTheCue() {
        let bytes = sample("Look") + atom("frcd", Data())
        XCTAssertEqual(TX3GSample.parse(bytes), .cue(text: "Look", isForced: true))
    }

    func testBoldAndItalic() {
        let styled = sample("Hello", styles: [style(start: 0, end: 5, face: 0x03)])
        XCTAssertEqual(TX3GSample.parse(styled), .cue(text: "<b><i>Hello</i></b>", isForced: false))
    }

    func testBoldRangeDoesNotEscapeTheRestAndEscapesTheStyledPart() {
        let styled = sample("a < b", styles: [style(start: 0, end: 5, face: 0x01)])
        XCTAssertEqual(TX3GSample.parse(styled), .cue(text: "<b>a &lt; b</b>", isForced: false))
    }

    func testStyleAppliesToAMiddleRange() {
        let styled = sample("Hello", styles: [style(start: 0, end: 2, face: 0x01)])
        XCTAssertEqual(TX3GSample.parse(styled), .cue(text: "<b>He</b>llo", isForced: false))
    }

    func testUnderline() {
        let styled = sample("Hi", styles: [style(start: 0, end: 2, face: 0x04)])
        XCTAssertEqual(TX3GSample.parse(styled), .cue(text: "<u>Hi</u>", isForced: false))
    }

    func testDefaultFaceStyleWhenTheSampleHasNoStyleAtom() {
        XCTAssertEqual(
            TX3GSample.parse(sample("Hello"), defaultFaceStyle: 0x01),
            .cue(text: "<b>Hello</b>", isForced: false)
        )
    }

    func testStyleRecordReplacesTheDefaultFace() {
        let styled = sample("abcdef", styles: [style(start: 2, end: 4, face: 0)])
        XCTAssertEqual(
            TX3GSample.parse(styled, defaultFaceStyle: 0x01),
            .cue(text: "<b>ab</b>cd<b>ef</b>", isForced: false)
        )
    }

    func testShortBufferAndTruncatedAtomAreMalformed() {
        XCTAssertEqual(TX3GSample.parse(Data([0x00])), .malformed)
        XCTAssertEqual(TX3GSample.parse(Data([0x00, 0x05, 0x48])), .malformed)
        let truncated = sample("Hi") + Data([0x00, 0x00, 0x00, 0x20, 0x73, 0x74, 0x79, 0x6C])
        XCTAssertEqual(TX3GSample.parse(truncated), .malformed)
    }

    func testInvalidUTF8IsMalformed() {
        XCTAssertEqual(TX3GSample.parse(sample(Data([0xFF]))), .malformed)
    }

    func testSampleEntryHeaderReadsFlagsAndFace() {
        let data = sampleEntry(flags: 0xC000_0000, face: 0x03)
        let header = TX3GSampleEntry.header(in: data)
        XCTAssertEqual(header?.displayFlags, 0xC000_0000)
        XCTAssertEqual(header?.defaultFaceStyle, 0x03)
        let wrapped: [String: Any] = ["atoms": ["entry": data]]
        let found = TX3GSampleEntry.findSampleEntry(in: wrapped)
        XCTAssertEqual(found, data)
        XCTAssertNil(TX3GSampleEntry.header(in: Data("nope".utf8)))
    }

    func testAssemblerUsesDurationAndSkipsGaps() {
        let cues = CueStreamAssembler.cues(from: [
            TX3GTimedSample(startMilliseconds: 0, endMilliseconds: 1000, text: "A", isForced: false),
            TX3GTimedSample(startMilliseconds: 1000, endMilliseconds: 2000, text: nil, isForced: false),
            TX3GTimedSample(startMilliseconds: 2000, endMilliseconds: 3500, text: "B", isForced: true)
        ])
        XCTAssertEqual(cues, [
            SubtitleCue(startMilliseconds: 0, endMilliseconds: 1000, text: "A", isForced: false),
            SubtitleCue(startMilliseconds: 2000, endMilliseconds: 3500, text: "B", isForced: true)
        ])
    }

    func testZeroDurationEndsAtTheNextSample() {
        let cues = CueStreamAssembler.cues(from: [
            TX3GTimedSample(startMilliseconds: 0, endMilliseconds: nil, text: "A", isForced: false),
            TX3GTimedSample(startMilliseconds: 1500, endMilliseconds: nil, text: nil, isForced: false),
            TX3GTimedSample(startMilliseconds: 4000, endMilliseconds: nil, text: "B", isForced: false)
        ])
        XCTAssertEqual(cues.map(\.startMilliseconds), [0, 4000])
        XCTAssertEqual(cues.map(\.endMilliseconds), [1500, 5000])
    }

    func testSamplesAreOrderedByStart() {
        let cues = CueStreamAssembler.cues(from: [
            TX3GTimedSample(startMilliseconds: 2000, endMilliseconds: 3000, text: "B", isForced: false),
            TX3GTimedSample(startMilliseconds: 0, endMilliseconds: 1000, text: "A", isForced: false)
        ])
        XCTAssertEqual(cues.map(\.text), ["A", "B"])
    }

    func testMediaTimeRoundsToNearestMillisecond() {
        XCTAssertEqual(MediaTime.milliseconds(value: 0, timescale: 1000), 0)
        XCTAssertEqual(MediaTime.milliseconds(value: -5, timescale: 1000), 0)
        XCTAssertEqual(MediaTime.milliseconds(value: 5, timescale: 0), 0)
        XCTAssertEqual(MediaTime.milliseconds(value: 1, timescale: 1), 1000)
        XCTAssertEqual(MediaTime.milliseconds(value: 1500, timescale: 1000), 1500)
        XCTAssertEqual(MediaTime.milliseconds(value: 1, timescale: 3), 333)
        XCTAssertEqual(MediaTime.milliseconds(value: 2, timescale: 3), 667)
        XCTAssertEqual(MediaTime.milliseconds(value: Int64.max, timescale: 1000), Int.max)
    }

    private func sample(_ text: String, styles: [Data] = []) -> Data {
        sample(Data(text.utf8), styles: styles)
    }

    private func sample(_ body: Data, styles: [Data] = []) -> Data {
        var data = Data()
        let length = UInt16(body.count)
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))
        data.append(body)
        if !styles.isEmpty {
            data.append(atom("styl", stylePayload(styles)))
        }
        return data
    }

    private func style(start: UInt16, end: UInt16, face: UInt8) -> Data {
        var record = Data()
        record.append(UInt8(start >> 8))
        record.append(UInt8(start & 0xFF))
        record.append(UInt8(end >> 8))
        record.append(UInt8(end & 0xFF))
        record.append(contentsOf: [0x00, 0x01])
        record.append(face)
        record.append(18)
        record.append(contentsOf: [255, 255, 255, 255])
        return record
    }

    private func stylePayload(_ records: [Data]) -> Data {
        var payload = Data([0x00, UInt8(records.count)])
        for record in records { payload.append(record) }
        return payload
    }

    private func atom(_ type: String, _ payload: Data) -> Data {
        let size = UInt32(8 + payload.count)
        var data = Data()
        data.append(UInt8((size >> 24) & 0xFF))
        data.append(UInt8((size >> 16) & 0xFF))
        data.append(UInt8((size >> 8) & 0xFF))
        data.append(UInt8(size & 0xFF))
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    private func sampleEntry(flags: UInt32, face: UInt8) -> Data {
        var bytes = Data()
        func u32(_ value: UInt32) {
            bytes.append(UInt8((value >> 24) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8(value & 0xFF))
        }
        func u16(_ value: UInt16) {
            bytes.append(UInt8(value >> 8))
            bytes.append(UInt8(value & 0xFF))
        }
        u32(0)
        bytes.append(contentsOf: [0x74, 0x78, 0x33, 0x67])
        bytes.append(Data(count: 6))
        u16(1)
        u32(flags)
        bytes.append(1)
        bytes.append(255)
        bytes.append(Data(count: 4))
        bytes.append(Data(count: 8))
        u16(0)
        u16(0)
        u16(1)
        bytes.append(face)
        bytes.append(18)
        bytes.append(contentsOf: [255, 255, 255, 255])
        return bytes
    }
}
