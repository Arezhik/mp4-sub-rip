import XCTest
@testable import MP4SubRipCore

#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import CoreVideo

/// Builds a tiny MP4 with tx3g samples and reads it back. The sample bytes are
/// the same layout the parser tests cover, written through with
/// `outputSettings: nil` so AVFoundation stores them instead of rewriting them.
final class AVFoundationSubtitleTests: XCTestCase {
    func testRoundTripOneTextTrackIncludingAGapAndUTF16() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("Movie.mp4")
        try await TX3GFixture.write(to: movie, tracks: [
            TX3GFixture.Track(languageCode: "eng", samples: [
                .init(text: "Hello", start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1)),
                .init(text: "", start: CMTime(value: 2, timescale: 1), duration: CMTime(value: 1, timescale: 1)),
                .init(text: "World", start: CMTime(value: 3, timescale: 1), duration: CMTime(value: 1500, timescale: 1000), utf16: true)
            ])
        ])

        let tracks = try await SubtitleEngine().probe(file: movie)
        let textTracks = tracks.filter(\.isExtractable)
        XCTAssertEqual(textTracks.count, 1, "tracks: \(tracks)")
        XCTAssertEqual(textTracks.first?.languageCode, "eng")

        let outcome = try await SubtitleEngine().extract(file: movie, conflict: .overwrite)
        XCTAssertEqual(outcome.written.count, 1)
        XCTAssertTrue(outcome.written[0].path.hasSuffix("Movie.srt"))
        let srt = try String(contentsOf: URL(fileURLWithPath: outcome.written[0].path), encoding: .utf8)
        XCTAssertEqual(
            srt,
            "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n2\n00:00:03,000 --> 00:00:04,500\nWorld\n"
        )
    }

    func testTwoLanguagesAndAForcedTrackAreNamedApart() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("Movie.mp4")
        try await TX3GFixture.write(to: movie, tracks: [
            TX3GFixture.Track(languageCode: "eng", samples: [
                .init(text: "Hello", start: CMTime(value: 0, timescale: 1), duration: CMTime(value: 1, timescale: 1))
            ]),
            TX3GFixture.Track(languageCode: "spa", samples: [
                .init(text: "Hola", start: CMTime(value: 0, timescale: 1), duration: CMTime(value: 1, timescale: 1), forced: true)
            ])
        ])
        let outcome = try await SubtitleEngine().extract(file: movie, conflict: .overwrite)
        let names = Set(outcome.written.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        XCTAssertEqual(names, ["Movie.eng.srt", "Movie.spa.forced.srt"])
        let spanish = try XCTUnwrap(outcome.written.first { $0.path.hasSuffix("Movie.spa.forced.srt") })
        let body = try String(contentsOf: URL(fileURLWithPath: spanish.path), encoding: .utf8)
        XCTAssertTrue(body.contains("Hola"))
        XCTAssertTrue(spanish.isForced)
    }

    func testBoldStyleRoundTrips() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("Movie.mp4")
        try await TX3GFixture.write(to: movie, tracks: [
            TX3GFixture.Track(languageCode: "eng", samples: [
                .init(
                    text: "Hello",
                    start: CMTime(value: 0, timescale: 1),
                    duration: CMTime(value: 1, timescale: 1),
                    bold: true
                )
            ])
        ])
        let outcome = try await SubtitleEngine().extract(file: movie, conflict: .overwrite)
        let body = try String(contentsOf: URL(fileURLWithPath: outcome.written[0].path), encoding: .utf8)
        XCTAssertTrue(body.contains("<b>Hello</b>"), body)
    }

    func testVideoWithoutSubtitlesExtractsNothing() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("Plain.mp4")
        try await TX3GFixture.write(to: movie, tracks: [])
        let tracks = try await SubtitleEngine().probe(file: movie)
        XCTAssertTrue(tracks.isEmpty, "\(tracks)")
        let outcome = try await SubtitleEngine().extract(file: movie, conflict: .overwrite)
        XCTAssertTrue(outcome.written.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["Plain.mp4"])
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp4subrip-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// AVAssetWriter is not Sendable. The finish callback is, so the writer stays in here.
private final class WriterBox: @unchecked Sendable {
    let writer: AVAssetWriter
    init(_ writer: AVAssetWriter) { self.writer = writer }
}

private enum TX3GFixture {
    struct Sample {
        var text: String
        var start: CMTime
        var duration: CMTime
        var utf16 = false
        var forced = false
        var bold = false
    }

    struct Track {
        var languageCode: String
        var samples: [Sample]
    }

    static func write(to url: URL, tracks: [Track]) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let format = try textFormat()
        var inputs: [(AVAssetWriterInput, [CMSampleBuffer])] = []
        for track in tracks {
            let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
            input.languageCode = track.languageCode
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw writer.error ?? fixtureError("Could not add a subtitle track.")
            }
            writer.add(input)
            let buffers = try track.samples.map { try sampleBuffer($0, format: format) }
            inputs.append((input, buffers))
        }

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16,
            AVVideoHeightKey: 16
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16
            ]
        )
        guard writer.canAdd(video) else {
            throw writer.error ?? fixtureError("Could not add a video track.")
        }
        writer.add(video)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        if writer.status == .failed {
            throw writer.error ?? fixtureError("The writer failed to start.")
        }

        try append(pixelBuffer(), via: adaptor, to: video, at: .zero)
        for (input, buffers) in inputs {
            for buffer in buffers {
                try append(buffer, to: input)
            }
            input.markAsFinished()
        }
        video.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 5, timescale: 1))

        let box = WriterBox(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.writer.finishWriting {
                if box.writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: box.writer.error ?? fixtureError("The writer did not finish."))
                }
            }
        }
    }

    private static func textFormat() throws -> CMFormatDescription {
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Subtitle,
            mediaSubType: kCMTextFormatType_3GText,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw fixtureError("Could not describe a tx3g track (\(status)).")
        }
        return format
    }

    private static func sampleBuffer(_ sample: Sample, format: CMFormatDescription) throws -> CMSampleBuffer {
        let payload = payloadBytes(sample)
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else {
            throw fixtureError("Could not allocate a sample (\(status)).")
        }
        let copied = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard copied == kCMBlockBufferNoErr else {
            throw fixtureError("Could not fill a sample (\(copied)).")
        }
        var timing = CMSampleTimingInfo(
            duration: sample.duration,
            presentationTimeStamp: sample.start,
            decodeTimeStamp: .invalid
        )
        var size = payload.count
        var buffer: CMSampleBuffer?
        let made = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &buffer
        )
        guard made == noErr, let buffer else {
            throw fixtureError("Could not build a sample buffer (\(made)).")
        }
        return buffer
    }

    private static func payloadBytes(_ sample: Sample) -> Data {
        let textBytes: [UInt8]
        if sample.text.isEmpty {
            textBytes = []
        } else if sample.utf16 {
            var encoded = Data([0xFE, 0xFF])
            for unit in sample.text.utf16 {
                encoded.append(UInt8(unit >> 8))
                encoded.append(UInt8(unit & 0xFF))
            }
            textBytes = [UInt8](encoded)
        } else {
            textBytes = [UInt8](sample.text.utf8)
        }
        var data = Data()
        let length = UInt16(textBytes.count)
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))
        data.append(contentsOf: textBytes)
        if sample.bold, !textBytes.isEmpty {
            data.append(styleAtom(characterCount: sample.text.unicodeScalars.count))
        }
        if sample.forced {
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x08, 0x66, 0x72, 0x63, 0x64])
        }
        return data
    }

    private static func styleAtom(characterCount: Int) -> Data {
        let count = UInt16(min(characterCount, Int(UInt16.max)))
        var payload = Data([0x00, 0x01])
        payload.append(contentsOf: [0x00, 0x00])
        payload.append(UInt8(count >> 8))
        payload.append(UInt8(count & 0xFF))
        payload.append(contentsOf: [0x00, 0x01])
        payload.append(0x01)
        payload.append(18)
        payload.append(contentsOf: [255, 255, 255, 255])
        var atom = Data()
        let size = UInt32(8 + payload.count)
        atom.append(UInt8((size >> 24) & 0xFF))
        atom.append(UInt8((size >> 16) & 0xFF))
        atom.append(UInt8((size >> 8) & 0xFF))
        atom.append(UInt8(size & 0xFF))
        atom.append(contentsOf: [0x73, 0x74, 0x79, 0x6C])
        atom.append(payload)
        return atom
    }

    private static func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw fixtureError("Could not make a frame (\(status)).")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let count = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
            base.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput) throws {
        try waitUntilReady(input)
        guard input.append(buffer) else {
            throw fixtureError("Could not append a subtitle sample.")
        }
    }

    private static func append(
        _ buffer: CVPixelBuffer,
        via adaptor: AVAssetWriterInputPixelBufferAdaptor,
        to input: AVAssetWriterInput,
        at time: CMTime
    ) throws {
        try waitUntilReady(input)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw fixtureError("Could not append the video frame.")
        }
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput) throws {
        let deadline = Date().addingTimeInterval(5)
        while !input.isReadyForMoreMediaData {
            if Date() > deadline {
                throw fixtureError("The writer was not ready.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func fixtureError(_ message: String) -> NSError {
        NSError(domain: "TX3GFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
