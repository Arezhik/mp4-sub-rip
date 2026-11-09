import Foundation

// What the engine tells the rest of the app about one MP4.
// tx3g (ffmpeg calls this mov_text) is read with AVFoundation. A discrete EIA-608
// track (`c608`) is extracted with ffmpeg. CEA-708 (`c708`), captions that live
// only in the video bitstream, bitmap, and WebVTT are reported and not extracted.

/// Why a subtitle track cannot be written to SRT.
public enum SubtitleSkipReason: Equatable, Sendable {
    /// CEA-708, or captions that are not a discrete EIA-608 track.
    case closedCaption
    /// The file has a discrete EIA-608 track, and ffmpeg is not installed.
    case needsFFmpeg
    /// PGS, VobSub, or another image subtitle. This app does not OCR.
    case bitmap
    /// WebVTT stored inside the MP4 (`wvtt`), which is not tx3g.
    case webVTT
    /// Some other codec. `codec` is the four-character code, lowercased.
    case notText(codec: String)

    /// A sentence the queue can show as-is.
    public var message: String {
        switch self {
        case .closedCaption:
            return "Closed captions are not a text subtitle track."
        case .needsFFmpeg:
            return "Closed-caption extraction needs ffmpeg."
        case .bitmap:
            return "Image-based subtitles (needs OCR)."
        case .webVTT:
            return "WebVTT in MP4 is not a tx3g text track."
        case .notText(let codec):
            return "Not a text subtitle track (\(codec))."
        }
    }
}

/// The kind of subtitle track, for the UI to group later.
public enum SubtitleTrackKind: String, Equatable, Sendable {
    case text
    case closedCaption
    case bitmap
    case webVTT
    case other
}

/// Which AVFoundation media type a track was discovered under.
public enum SubtitleMediaKind: String, Equatable, Sendable {
    case text
    case subtitle
    case closedCaption
}

/// One subtitle track inside an MP4, before or after extraction.
public struct SubtitleTrack: Equatable, Sendable, Identifiable {
    /// The container's track ID. Stable for the life of the file.
    public var id: Int
    /// Token used in file names. `und` when the file has no language.
    public var languageCode: String
    /// BCP-47 tag when the file has one, otherwise nil.
    public var extendedLanguageTag: String?
    /// Track title from metadata, such as "Commentary" or "SDH". Nil when absent.
    public var title: String?
    public var kind: SubtitleTrackKind
    /// Four-character codec code, lowercased, or `unknown`.
    public var codec: String
    /// The whole track is a forced-subtitle track (name, display flag, or every cue).
    public var isForced: Bool
    /// At least one cue is forced, or the sample description says so.
    /// A normal dialogue track can still contain a few forced cues.
    public var hasForcedSamples: Bool
    /// Hearing-impaired / SDH, from the track title. Not a separate codec.
    public var isSDH: Bool
    public var isExtractable: Bool
    /// Set when `isExtractable` is false.
    public var skipReason: SubtitleSkipReason?

    public init(
        id: Int,
        languageCode: String,
        extendedLanguageTag: String? = nil,
        title: String? = nil,
        kind: SubtitleTrackKind,
        codec: String,
        isForced: Bool = false,
        hasForcedSamples: Bool = false,
        isSDH: Bool = false,
        isExtractable: Bool,
        skipReason: SubtitleSkipReason? = nil
    ) {
        self.id = id
        self.languageCode = languageCode
        self.extendedLanguageTag = extendedLanguageTag
        self.title = title
        self.kind = kind
        self.codec = codec
        self.isForced = isForced
        self.hasForcedSamples = hasForcedSamples
        self.isSDH = isSDH
        self.isExtractable = isExtractable
        self.skipReason = skipReason
    }
}

/// A track as discovered from the container, before it is classified.
public struct DiscoveredMediaTrack: Equatable, Sendable {
    public var trackID: Int
    public var mediaKind: SubtitleMediaKind
    public var codec: String
    public var languageCode: String?
    public var extendedLanguageTag: String?
    public var title: String?
    /// tx3g sample-description display flags, when the bytes were available.
    public var displayFlags: UInt32?

    public init(
        trackID: Int,
        mediaKind: SubtitleMediaKind,
        codec: String,
        languageCode: String? = nil,
        extendedLanguageTag: String? = nil,
        title: String? = nil,
        displayFlags: UInt32? = nil
    ) {
        self.trackID = trackID
        self.mediaKind = mediaKind
        self.codec = codec
        self.languageCode = languageCode
        self.extendedLanguageTag = extendedLanguageTag
        self.title = title
        self.displayFlags = displayFlags
    }
}

/// Turns container facts into a `SubtitleTrack`. Pure: no AVFoundation.
public enum TrackClassifier {
    /// VobSub in MP4 is usually `mp4s`. PGS has no single standard MP4 code;
    /// these are the ones muxers actually write. Unknown codes stay "not text"
    /// rather than being called bitmap.
    static let bitmapCodecs: Set<String> = ["mp4s", "vobs", "pgs1", "pgss", "xsub", "dvbs"]
    /// Closed captions we recognize but do not extract. Discrete EIA-608
    /// (`c608`) is extractable and is handled before this set is consulted.
    static let closedCaptionCodecs: Set<String> = ["c708", "atcc"]

    public static func classify(_ discovered: DiscoveredMediaTrack) -> SubtitleTrack {
        let codec = normalizeCodec(discovered.codec)
        let language = LanguageCode.filename(
            languageCode: discovered.languageCode,
            extendedLanguageTag: discovered.extendedLanguageTag
        )
        let words = WordList(discovered.title)
        let namedForced = words.contains("forced")
        let namedSDH = words.contains("sdh") || (words.contains("hearing") && words.contains("impaired"))
        let flags = discovered.displayFlags ?? 0
        let allSamplesForced = flags & TX3GDisplayFlag.allSamplesForced != 0
        let someSamplesForced = allSamplesForced || flags & TX3GDisplayFlag.someSamplesForced != 0

        let kind: SubtitleTrackKind
        let extractable: Bool
        let reason: SubtitleSkipReason?

        if codec == "tx3g" {
            kind = .text
            extractable = true
            reason = nil
        } else if codec == "c608" {
            kind = .closedCaption
            extractable = true
            reason = nil
        } else if discovered.mediaKind == .closedCaption || closedCaptionCodecs.contains(codec) {
            kind = .closedCaption
            extractable = false
            reason = .closedCaption
        } else if codec == "wvtt" {
            kind = .webVTT
            extractable = false
            reason = .webVTT
        } else if bitmapCodecs.contains(codec) {
            kind = .bitmap
            extractable = false
            reason = .bitmap
        } else {
            kind = .other
            extractable = false
            reason = .notText(codec: codec)
        }

        return SubtitleTrack(
            id: discovered.trackID,
            languageCode: language,
            extendedLanguageTag: discovered.extendedLanguageTag,
            title: blankToNil(discovered.title),
            kind: kind,
            codec: codec,
            isForced: namedForced || allSamplesForced,
            hasForcedSamples: namedForced || someSamplesForced || allSamplesForced,
            isSDH: namedSDH,
            isExtractable: extractable,
            skipReason: reason
        )
    }

    /// Classifies every track. The same track ID can show up under more than one
    /// media type; an extractable tx3g hit wins over a weaker duplicate.
    public static func classifyAll(_ discovered: [DiscoveredMediaTrack]) -> [SubtitleTrack] {
        var order: [Int] = []
        var byID: [Int: SubtitleTrack] = [:]
        for item in discovered {
            let track = classify(item)
            if let existing = byID[track.id] {
                let textWins = track.codec == "tx3g" && existing.codec != "tx3g"
                if textWins || (!existing.isExtractable && track.isExtractable) {
                    byID[track.id] = track
                }
                continue
            }
            order.append(track.id)
            byID[track.id] = track
        }
        return order.compactMap { byID[$0] }
    }

    private static func normalizeCodec(_ codec: String) -> String {
        let trimmed = codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private static func blankToNil(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Filename language token. ISO 639-2 (`eng`) when the file has it, otherwise
/// the primary BCP-47 subtag (`en`), otherwise `und`.
enum LanguageCode {
    static func filename(languageCode: String?, extendedLanguageTag: String?) -> String {
        if let code = token(languageCode) { return code }
        if let tag = token(extendedLanguageTag) { return tag }
        return "und"
    }

    /// Two or three letters. `und` / `unk` count as missing so the other field can win.
    private static func token(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let primary = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? trimmed
        let lower = primary.lowercased()
        guard (2...3).contains(lower.count), lower.allSatisfy(\.isLetter) else { return nil }
        if lower == "und" || lower == "unk" { return nil }
        return lower
    }
}

/// Words in a track title, split on anything that isn't a letter or digit.
struct WordList: Equatable {
    private var words: Set<String>

    init(_ title: String?) {
        var words: Set<String> = []
        var current = ""
        let source = (title ?? "").lowercased()
        for character in source {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { words.insert(current) }
        self.words = words
    }

    func contains(_ word: String) -> Bool { words.contains(word) }
}

/// Failures the queue can show. Cancellation uses `CancellationError`, not this.
public enum SubtitleExtractionError: Error, Equatable, LocalizedError, Sendable {
    case fileNotFound
    case protectedContent
    case outputNotWritable
    case malformedSample
    case unsupportedPlatform
    case needsFFmpeg
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "File not found."
        case .protectedContent:
            return "This file is DRM-protected and can't be extracted."
        case .outputNotWritable:
            return "Folder is read-only."
        case .malformedSample:
            return "A subtitle sample could not be read."
        case .unsupportedPlatform:
            return "Extracting subtitles needs macOS."
        case .needsFFmpeg:
            return SubtitleSkipReason.needsFFmpeg.message
        case .unreadable(let message):
            return message
        }
    }
}

/// One cue, already decoded. Times are milliseconds from the start of the file.
public struct SubtitleCue: Equatable, Sendable {
    public var startMilliseconds: Int
    public var endMilliseconds: Int
    public var text: String
    /// This cue carried a `frcd` atom. The track is a forced track only when every cue is.
    public var isForced: Bool

    public init(startMilliseconds: Int, endMilliseconds: Int, text: String, isForced: Bool = false) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
        self.isForced = isForced
    }
}

/// What `probe` returns, plus the movie duration used for progress.
public struct MediaInspection: Equatable, Sendable {
    public var tracks: [SubtitleTrack]
    /// 0 when the container doesn't say. Progress then counts cues instead of time.
    public var durationMilliseconds: Int

    public init(tracks: [SubtitleTrack], durationMilliseconds: Int) {
        self.tracks = tracks
        self.durationMilliseconds = durationMilliseconds
    }
}
