import Foundation

// Design spec section 5.
// One extractable track: `Movie.srt`, so players pick it up automatically.
// Several: `Movie.eng.srt`, `Movie.spa.srt`. Unknown language is `und`.
// Forced and SDH tracks are marked (`Movie.eng.forced.srt`, `Movie.eng.sdh.srt`).
// Same-language duplicates that are still identical get the track title, or
// `.2`, `.3`, ... The first of a set keeps the plain name.
// "Always include language code" puts the language on a single track too.

enum SubtitleFileNames {
    static func baseName(forFile path: String) -> String {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return name.isEmpty ? "subtitles" : name
    }

    /// Track id to file name, only for extractable tracks, in input order.
    static func names(
        baseName: String,
        tracks: [SubtitleTrack],
        alwaysIncludeLanguageCode: Bool
    ) -> [Int: String] {
        let tracks = tracks.filter(\.isExtractable)
        guard let only = tracks.first, tracks.count == 1, !alwaysIncludeLanguageCode else {
            return named(baseName: baseName, tracks: tracks)
        }
        return [only.id: "\(baseName).srt"]
    }

    /// `Movie.eng.srt` existing becomes `Movie.eng (1).srt`, then `(2)`, and so on.
    static func numbered(_ fileName: String, index: Int) -> String {
        let url = URL(fileURLWithPath: fileName)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        if ext.isEmpty { return "\(fileName) (\(index))" }
        return "\(base) (\(index)).\(ext)"
    }

    private static func named(baseName: String, tracks: [SubtitleTrack]) -> [Int: String] {
        let proposals = proposals(for: tracks)
        var used: Set<String> = []
        var result: [Int: String] = [:]
        for proposal in proposals {
            var token = proposal.token
            if used.contains(token) {
                var number = 2
                while used.contains("\(proposal.token).\(number)") {
                    number += 1
                }
                token = "\(proposal.token).\(number)"
            }
            used.insert(token)
            result[proposal.id] = "\(baseName).\(token).srt"
        }
        return result
    }

    /// Language, then `forced` or `sdh`. A title is added only when that token
    /// would otherwise collide with another track in this batch.
    private static func proposals(for tracks: [SubtitleTrack]) -> [(id: Int, token: String)] {
        let draft: [(id: Int, token: String, title: String?)] = tracks.map { track in
            let language = track.languageCode.isEmpty ? "und" : track.languageCode
            var token = language
            if track.isForced {
                token += ".forced"
            } else if track.isSDH {
                token += ".sdh"
            }
            return (track.id, token, filenameToken(track.title))
        }
        var counts: [String: Int] = [:]
        for item in draft {
            counts[item.token, default: 0] += 1
        }
        return draft.map { item in
            if counts[item.token, default: 0] > 1, let title = item.title {
                return (item.id, item.token + "." + title)
            }
            return (item.id, item.token)
        }
    }

    /// A short, lowercase token safe to drop into a file name. `forced`, `sdh`,
    /// `und`, and bare numbers are rejected so they don't look like our own suffixes.
    static func filenameToken(_ title: String?) -> String? {
        guard let title else { return nil }
        var token = ""
        var dash = false
        for character in title.lowercased() {
            if character.isLetter || character.isNumber {
                if dash, !token.isEmpty { token.append("-") }
                dash = false
                token.append(character)
                if token.count >= 40 { break }
            } else if !token.isEmpty {
                dash = true
            }
        }
        while token.hasSuffix("-") { token.removeLast() }
        if token.isEmpty || token == "forced" || token == "sdh" || token == "und" { return nil }
        if token.allSatisfy(\.isNumber) { return nil }
        return token
    }
}
