# MP4SubRip notes

Dated log of decisions, PRs, test results, and open questions. Newest at the bottom.
Times in Mountain time (MT).

- Repo: <https://github.com/Arezhik/REPO>
- Spec: SPEC.md
- Checklist used at kickoff: AGENTS.md (from the macOS Dev living checklist)

## 2026-11-04: Project created
- Generated with new-mac-app.sh (name MP4SubRip, bundle ID com.arezhik.MP4SubRip, macOS 14.0+).
- Next: confirm the Phase 1 scope in SPEC.md, get sample input files, then launch the first cloud agent.

## 2026-11-06: Extraction engine (issue #2)
- Text tracks only (tx3g / mov_text), via AVFoundation (`AVAssetReader` + nil output settings). Bitmap, closed captions, WebVTT-in-MP4, and other codecs are reported and skipped. DRM is refused.
- ffmpeg is not called. `SubtitleMediaReading` is the seam if a real tx3g file later fails in AVFoundation.
- Naming follows design spec §5. One extractable track is `Movie.srt`. Forced is marked when the track name, the all-samples display flag (`0x80000000`), or every cue's `frcd` atom says so.
- Bold, italic, and underline from tx3g `styl` records (and the sample description's default face) become `<b>`, `<i>`, and `<u>`.

## 2026-11-09: EIA-608 closed captions (issue #27)
- Discrete `c608` tracks are extractable and go through ffmpeg `-map 0:s:N -c:s srt`. tx3g stays on AVFoundation.
- ffmpeg's SRT is cleaned of `{\an7}`, `<font>` / `</font>`, and `\h`. Real `<i>` stays.
- `c708` and captions that live only in the video bitstream are still reported and not extracted. No CCExtractor, no lavfi `subcc`, no `AVAssetReaderOutputCaptionAdaptor` (that is #28).
- ffmpeg is located before `/Applications` is listed, and the launch log uses the same wording as the debug-log header. A missing ffmpeg skips the closed-caption file instead of writing a bad `.srt`.

<!-- Template for each entry:
## YYYY-MM-DD ~H:MM PM MT: PR #N (what it does)
- Agent: bc-…, branch cursor/…
- CI: green/red (run link)
- Arezhik's test: pass/fail, with the checklist items that failed
- Decision: merged (commit) / waiting / logged as issue #N
-->
