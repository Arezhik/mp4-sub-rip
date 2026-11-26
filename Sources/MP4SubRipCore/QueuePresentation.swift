import Foundation

// How a queue row is described: chips, status words, the output column,
// clear / retry / remove, recent folders, and Reveal. No AppKit, so `swift test`
// covers it on Linux. The window only draws what this returns.

/// Short failure text for the status column. The full reason stays in the tooltip.
public enum FailureLine {
    public static func short(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mapped = known[trimmed] { return mapped }
        var text = trimmed
        if text.hasSuffix(".") { text.removeLast() }
        if text.count <= 20 { return text }
        let end = text.index(text.startIndex, offsetBy: 19)
        return String(text[..<end]) + "…"
    }

    private static let known: [String: String] = [
        "Folder is read-only.": "Read-only folder",
        "File not found.": "File not found",
        "Choose an output folder in Settings.": "Choose a folder",
        "The output folder can't be found.": "Folder not found",
        "This file is DRM-protected and can't be extracted.": "DRM-protected",
        "A subtitle sample could not be read.": "Unreadable sample",
        "Extracting subtitles needs macOS.": "Needs macOS",
        "Could not extract subtitles.": "Could not extract",
        "Could not read this file.": "Could not read"
    ]
}

/// The status line. `runIsActive` turns later Pending rows into "Waiting…".
public enum QueueRowText {
    public static func summary(_ status: JobStatus, runIsActive: Bool) -> String {
        switch status {
        case .probing:
            return "Reading tracks…"
        case .waiting:
            return runIsActive ? "Waiting…" : "Pending"
        case .working:
            return "Extracting"
        case let .done(written, _):
            if written.count == 1 { return "Done · 1 file" }
            return "Done · \(written.count) files"
        case .skippedExists:
            return "Done · skipped (exists)"
        case .noSubtitles:
            return "No subtitles"
        case .imageSubsOnly:
            return "Image subs only"
        case let .failed(reason):
            return "Failed · \(FailureLine.short(reason))"
        case let .skipped(reason):
            return "Skipped · \(reason)"
        case .canceled:
            return "Cancelled"
        }
    }

    /// Tooltip for the status cell. Nil when the line already says everything.
    public static func help(for item: QueueItem, languageName: @Sendable (String) -> String?) -> String? {
        switch item.status {
        case let .failed(reason):
            return reason
        case let .skipped(reason):
            return reason
        case let .done(_, skipped) where !skipped.isEmpty:
            return skippedLine(skipped)
        case let .skippedExists(paths):
            let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
            return names.isEmpty ? nil : names.joined(separator: "\n")
        case .imageSubsOnly:
            let lines = TrackChips.imageSentences(tracks: item.tracks, languageName: languageName)
            if !lines.isEmpty { return lines.joined(separator: "\n") }
            return item.statusNote ?? "Image-based subtitles (needs OCR)."
        case .noSubtitles:
            return item.statusNote
        default:
            return nil
        }
    }

    static func skippedLine(_ paths: [String]) -> String {
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
        let phrase = paths.count == 1 ? "1 skipped (exists)" : "\(paths.count) skipped (exists)"
        return "\(phrase): \(names.joined(separator: ", "))"
    }
}

/// What probe decided, before Extract.
public enum ProbeRules {
    public enum Settlement: Equatable, Sendable {
        case waiting
        case noSubtitles(note: String?)
        case imageSubsOnly
    }

    /// Extractable tracks stay Pending. Bitmap-only rows are image subs.
    /// Anything else with nothing to write is "No subtitles".
    public static func settle(_ tracks: [SubtitleTrack]) -> Settlement {
        if tracks.contains(where: \.isExtractable) { return .waiting }
        if tracks.contains(where: { $0.kind == .bitmap || $0.skipReason == .bitmap }) {
            return .imageSubsOnly
        }
        var seen: Set<String> = []
        var notes: [String] = []
        for track in tracks {
            guard let message = track.skipReason?.message, seen.insert(message).inserted else { continue }
            notes.append(message)
        }
        if notes.isEmpty { return .noSubtitles(note: nil) }
        return .noSubtitles(note: notes.joined(separator: "\n"))
    }
}

/// Turns an extraction result into the row status. Skip stays a success.
public enum QueueOutcome {
    public static func status(for outcome: ExtractionOutcome) -> JobStatus {
        let written = outcome.written.map(\.path)
        let existing = outcome.alreadyExists.map(\.path)
        if !written.isEmpty {
            return .done(written: written, skippedExists: existing)
        }
        if !existing.isEmpty {
            return .skippedExists(paths: existing)
        }
        if outcome.skipped.isEmpty {
            return .noSubtitles
        }
        if outcome.skipped.allSatisfy({ $0.reason == .bitmap }) {
            return .imageSubsOnly
        }
        var seen: Set<String> = []
        var parts: [String] = []
        for skip in outcome.skipped where seen.insert(skip.reason.message).inserted {
            parts.append(skip.reason.message)
        }
        return .skipped(reason: parts.joined(separator: " "))
    }
}

/// Remove, clear, and retry. These never touch the disk.
public enum QueueHousekeeping {
    public static func removing(_ items: [QueueItem], ids: Set<UUID>) -> [QueueItem] {
        items.filter { !(ids.contains($0.id) && $0.status.canRemove) }
    }

    public static func clearing(_ items: [QueueItem], includingFailed: Bool) -> [QueueItem] {
        items.filter { item in
            includingFailed ? !item.status.clearsWithAllFinished : !item.status.clearsWithProcessed
        }
    }

    /// Failed and canceled rows go back to Pending. Tracks already probed stay.
    public static func retrying(_ items: [QueueItem], ids: Set<UUID>) -> [QueueItem] {
        items.map { item in
            guard ids.contains(item.id), item.status.canRetry else { return item }
            var copy = item
            copy.status = .waiting
            copy.statusNote = nil
            return copy
        }
    }
}

/// Which context-menu and Queue-menu items apply. Hidden when they don't.
public struct RowActionSet: Equatable, Sendable {
    public var retry: Bool
    public var showError: Bool
    public var reveal: Bool
    public var showVideo: Bool
    public var openSubtitle: Bool
    public var remove: Bool

    public init(
        retry: Bool = false,
        showError: Bool = false,
        reveal: Bool = false,
        showVideo: Bool = false,
        openSubtitle: Bool = false,
        remove: Bool = false
    ) {
        self.retry = retry
        self.showError = showError
        self.reveal = reveal
        self.showVideo = showVideo
        self.openSubtitle = openSubtitle
        self.remove = remove
    }

    public static func forSelection(_ items: [QueueItem], ids: Set<UUID>) -> RowActionSet {
        let selected = items.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return RowActionSet() }
        let failed = selected.filter { $0.status.offersErrorDetail }
        return RowActionSet(
            retry: selected.contains { $0.status.canRetry },
            showError: selected.count == 1 && failed.count == 1,
            reveal: selected.contains { !$0.status.outputPaths.isEmpty },
            showVideo: true,
            openSubtitle: selected.contains { !$0.status.outputPaths.isEmpty },
            remove: selected.contains { $0.status.canRemove }
        )
    }
}

/// How Show in Finder opens what is still on disk.
///
/// Selecting many URLs at once stretches the Finder window to the desktop.
/// One file is selected with an empty root. Several files open their folder
/// with nothing selected. Files in more than one folder open each folder.
/// Nothing on disk is the missing-file alert, not an empty Finder window.
public enum RevealRules {
    /// Logged with every Show in Finder call. The app passes this to the debug log.
    public static let selectFileAPI = "NSWorkspace.selectFile(_:inFileViewerRootedAtPath:)"

    public enum Action: Equatable, Sendable {
        case nothing
        /// One file that is still there. Select it (`inFileViewerRootedAtPath: ""`).
        case file(String)
        /// Parent folders to open with no selection, first-seen order.
        case folders([String])
        case missing(name: String, folder: String, folderExists: Bool)
    }

    public static func plan(
        paths: [String],
        fileExists: @Sendable (String) -> Bool,
        directoryExists: @Sendable (String) -> Bool,
        missingGroupName: String = "Those files"
    ) -> Action {
        let unique = deduped(paths)
        if unique.isEmpty { return .nothing }
        let present = unique.filter(fileExists)
        if present.isEmpty {
            let folder = parent(of: unique[0])
            let name = unique.count == 1
                ? URL(fileURLWithPath: unique[0]).lastPathComponent
                : missingGroupName
            return .missing(name: name, folder: folder, folderExists: directoryExists(folder))
        }
        if present.count == 1 { return .file(present[0]) }
        return .folders(parentFolders(of: present))
    }

    /// Files that are still on disk, in the order they were given. Open Subtitle uses this.
    public static func existing(
        paths: [String],
        fileExists: @Sendable (String) -> Bool
    ) -> [String] {
        deduped(paths).filter(fileExists)
    }

    private static func deduped(_ paths: [String]) -> [String] {
        var unique: [String] = []
        for path in paths where !unique.contains(path) {
            unique.append(path)
        }
        return unique
    }

    private static func parentFolders(of paths: [String]) -> [String] {
        var folders: [String] = []
        for path in paths {
            let folder = parent(of: path)
            if !folder.isEmpty && !folders.contains(folder) {
                folders.append(folder)
            }
        }
        return folders
    }

    private static func parent(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
    }
}

/// Localized language names for chips. `localized` is given the ISO 639-1 code when we know it.
public enum LanguageDisplay {
    public static func name(for code: String, localized: @Sendable (String) -> String?) -> String {
        let lower = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty || lower == "und" || lower == "unk" { return "Unknown" }
        let primary = iso6391[lower] ?? lower
        if let localizedName = cleaned(localized(primary)) { return localizedName }
        if primary != lower, let localizedName = cleaned(localized(lower)) { return localizedName }
        return lower
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// ISO 639-2 (and the common bibliographic aliases) to ISO 639-1.
    static let iso6391: [String: String] = [
        "eng": "en", "spa": "es", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de",
        "ita": "it", "por": "pt", "jpn": "ja", "kor": "ko", "zho": "zh", "chi": "zh",
        "rus": "ru", "ara": "ar", "hin": "hi", "nld": "nl", "dut": "nl", "swe": "sv",
        "nor": "no", "dan": "da", "fin": "fi", "pol": "pl", "tur": "tr", "ell": "el",
        "gre": "el", "heb": "he", "ces": "cs", "cze": "cs", "hun": "hu", "ron": "ro",
        "rum": "ro", "tha": "th", "vie": "vi", "ind": "id", "msa": "ms", "may": "ms",
        "ukr": "uk", "cat": "ca", "hrv": "hr", "srp": "sr", "slk": "sk", "slo": "sk",
        "bul": "bg", "lit": "lt", "lav": "lv", "est": "et", "isl": "is", "ice": "is",
        "gle": "ga", "glg": "gl", "eus": "eu", "baq": "eu", "cym": "cy", "wel": "cy",
        "fas": "fa", "per": "fa", "urd": "ur", "ben": "bn", "tam": "ta", "tel": "te",
        "fil": "fil", "tgl": "tl", "afr": "af"
    ]
}

enum BitmapFormatName {
    static func label(codec: String) -> String {
        switch codec.lowercased() {
        case "mp4s", "vobs": return "VobSub"
        case "pgs1", "pgss": return "PGS"
        case "xsub": return "XSUB"
        case "dvbs": return "DVB"
        default:
            let trimmed = codec.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Image" : trimmed.uppercased()
        }
    }
}

/// One capsule in the Subtitle Tracks column.
public struct TrackChipModel: Equatable, Sendable, Identifiable {
    public enum Style: Equatable, Sendable {
        case text
        case caption
        case bitmap
    }

    public var id: Int
    public var style: Style
    /// Primary words, such as "English", "CC (eng) · c608", or "PGS · English".
    public var title: String
    /// "Forced" or "SDH", drawn in a secondary color after the title.
    public var mark: String?
    /// SF Symbol name. Captions and image tracks have one; plain text does not.
    public var symbol: String?

    public init(id: Int, style: Style, title: String, mark: String?, symbol: String?) {
        self.id = id
        self.style = style
        self.title = title
        self.mark = mark
        self.symbol = symbol
    }
}

public enum TrackChips {
    public static func chips(
        tracks: [SubtitleTrack],
        languageName: @Sendable (String) -> String?
    ) -> [TrackChipModel] {
        tracks.compactMap { chip(for: $0, languageName: languageName) }
    }

    public static func columnHelp(
        tracks: [SubtitleTrack],
        languageName: @Sendable (String) -> String?
    ) -> String {
        tracks.map { line(for: $0, languageName: languageName) }.joined(separator: "\n")
    }

    public static func imageSentences(
        tracks: [SubtitleTrack],
        languageName: @Sendable (String) -> String?
    ) -> [String] {
        tracks.compactMap { track in
            guard track.kind == .bitmap || track.skipReason == .bitmap else { return nil }
            return imageSentence(track, languageName: languageName)
        }
    }

    static func chip(
        for track: SubtitleTrack,
        languageName: @Sendable (String) -> String?
    ) -> TrackChipModel? {
        if track.isExtractable && track.kind == .closedCaption {
            return TrackChipModel(
                id: track.id,
                style: .caption,
                title: "CC (\(track.languageCode)) · \(track.codec)",
                mark: mark(for: track),
                symbol: "captions.bubble"
            )
        }
        if track.isExtractable {
            return TrackChipModel(
                id: track.id,
                style: .text,
                title: LanguageDisplay.name(for: track.languageCode, localized: languageName),
                mark: mark(for: track),
                symbol: nil
            )
        }
        if track.kind == .bitmap || track.skipReason == .bitmap {
            let format = BitmapFormatName.label(codec: track.codec)
            let language = LanguageDisplay.name(for: track.languageCode, localized: languageName)
            let title = language == "Unknown" ? format : "\(format) · \(language)"
            return TrackChipModel(id: track.id, style: .bitmap, title: title, mark: nil, symbol: "photo")
        }
        return nil
    }

    static func line(for track: SubtitleTrack, languageName: @Sendable (String) -> String?) -> String {
        if track.kind == .bitmap || track.skipReason == .bitmap {
            return imageSentence(track, languageName: languageName)
        }
        if let chip = chip(for: track, languageName: languageName) {
            if let mark = chip.mark { return "\(chip.title) · \(mark)" }
            return chip.title
        }
        return track.skipReason?.message ?? track.codec
    }

    static func imageSentence(_ track: SubtitleTrack, languageName: @Sendable (String) -> String?) -> String {
        let format = BitmapFormatName.label(codec: track.codec)
        let language = LanguageDisplay.name(for: track.languageCode, localized: languageName)
        return "\(language) (\(format), image-based): can't be extracted as text. Open this video in PGS2SRT to OCR it."
    }

    private static func mark(for track: SubtitleTrack) -> String? {
        if track.isForced { return "Forced" }
        if track.isSDH { return "SDH" }
        return nil
    }
}

/// What the Output column shows.
public enum OutputColumn: Equatable, Sendable {
    case dash
    case needsOCR
    case files(firstName: String, extraCount: Int, help: String)
}

public enum OutputColumnBuilder {
    public static let needsOCRText = "Use PGS2SRT (needs OCR)"

    public static func make(for item: QueueItem) -> OutputColumn {
        switch item.status {
        case .imageSubsOnly:
            return .needsOCR
        case .noSubtitles, .failed, .probing, .canceled, .skipped:
            return .dash
        case .done, .skippedExists:
            return files(names: names(from: item.status.outputPaths), helpLines: item.status.outputPaths, item: item)
        case .waiting, .working:
            let predicted = predictedNames(item)
            return files(names: predicted, helpLines: predicted, item: item)
        }
    }

    private static func files(names: [String], helpLines: [String], item: QueueItem) -> OutputColumn {
        guard let first = names.first else { return .dash }
        var lines = helpLines
        if case let .done(_, skipped) = item.status, !skipped.isEmpty {
            lines.append(QueueRowText.skippedLine(skipped))
        }
        if let note = bitmapNote(tracks: item.tracks) {
            lines.append(note)
        }
        return .files(firstName: first, extraCount: names.count - 1, help: lines.joined(separator: "\n"))
    }

    private static func names(from paths: [String]) -> [String] {
        paths.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    private static func predictedNames(_ item: QueueItem) -> [String] {
        let map = SubtitleFileNames.names(
            baseName: SubtitleFileNames.baseName(forFile: item.path),
            tracks: item.tracks,
            alwaysIncludeLanguageCode: false
        )
        return item.tracks.filter(\.isExtractable).compactMap { map[$0.id] }
    }

    /// Shown when a file still has text to extract and also an image track.
    static func bitmapNote(tracks: [SubtitleTrack]) -> String? {
        guard tracks.contains(where: \.isExtractable) else { return nil }
        let bitmaps = tracks.filter { $0.kind == .bitmap || $0.skipReason == .bitmap }
        guard !bitmaps.isEmpty else { return nil }
        var labels: [String] = []
        for track in bitmaps {
            let label = BitmapFormatName.label(codec: track.codec)
            if !labels.contains(label) { labels.append(label) }
        }
        if labels.count == 1 {
            return "\(labels[0]) track skipped (image-based)"
        }
        return "\(labels.joined(separator: ", ")) tracks skipped (image-based)"
    }
}

public enum QueueSummaryLine {
    public static func text(files: Int, textTracks: Int) -> String {
        let filesPart = files == 1 ? "1 file" : "\(files) files"
        let tracksPart = textTracks == 1 ? "1 text track" : "\(textTracks) text tracks"
        return "\(filesPart) · \(tracksPart)"
    }

    public static func textTrackCount(in items: [QueueItem]) -> Int {
        items.reduce(0) { $0 + $1.tracks.filter(\.isExtractable).count }
    }
}

public enum DisplayPath {
    public static func abbreviated(_ path: String, home: String) -> String {
        let home = strip(home)
        if path == home { return "~" }
        let prefix = home + "/"
        if path.hasPrefix(prefix) {
            return "~/" + String(path.dropFirst(prefix.count))
        }
        return path
    }

    public static func parent(_ path: String, home: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        if directory.isEmpty || directory == "." || directory == path { return "" }
        return abbreviated(directory, home: home)
    }

    public static func folderName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func strip(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// A chosen output folder. `bookmark` is security-scoped bookmark data from AppKit.
public struct RecentFolderRecord: Equatable, Sendable, Codable, Identifiable {
    public var path: String
    public var bookmark: Data?
    public var id: String { path }

    public init(path: String, bookmark: Data? = nil) {
        self.path = RecentFolderList.normalize(path)
        self.bookmark = bookmark
    }
}

public enum RecentFolderList {
    public static let limit = 3
    public static let defaultsKey = "outputRecentFolders"

    public static func normalize(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Most recent first, at most `limit`, with duplicates collapsed.
    /// A nil bookmark keeps the one already stored for that path.
    public static func remembering(
        _ path: String,
        bookmark: Data?,
        in records: [RecentFolderRecord]
    ) -> [RecentFolderRecord] {
        let path = normalize(path)
        let normalized = records.map { RecentFolderRecord(path: $0.path, bookmark: $0.bookmark) }
        let kept = bookmark ?? normalized.first { $0.path == path }?.bookmark
        var next = normalized.filter { $0.path != path }
        next.insert(RecentFolderRecord(path: path, bookmark: kept), at: 0)
        if next.count > limit { next = Array(next.prefix(limit)) }
        return next
    }

    public static func droppingMissing(
        _ records: [RecentFolderRecord],
        exists: @Sendable (String) -> Bool
    ) -> [RecentFolderRecord] {
        records.filter { exists(normalize($0.path)) }
    }

    /// `resolvedPath` returns the folder to keep, or nil to drop the entry.
    public static func refreshing(
        _ records: [RecentFolderRecord],
        resolvedPath: @Sendable (RecentFolderRecord) -> String?
    ) -> [RecentFolderRecord] {
        var result: [RecentFolderRecord] = []
        for record in records {
            guard let path = resolvedPath(record) else { continue }
            let updated = RecentFolderRecord(path: path, bookmark: record.bookmark)
            if result.contains(where: { $0.path == updated.path }) { continue }
            result.append(updated)
        }
        return result
    }

    public static func load(_ defaults: UserDefaults = .standard, key: String = defaultsKey) -> [RecentFolderRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let decoded = try? JSONDecoder().decode([RecentFolderRecord].self, from: data) else { return [] }
        return decoded.map { RecentFolderRecord(path: $0.path, bookmark: $0.bookmark) }
    }

    public static func save(_ records: [RecentFolderRecord], to defaults: UserDefaults, key: String = defaultsKey) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}
