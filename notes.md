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

<!-- Template for each entry:
## YYYY-MM-DD ~H:MM PM MT: PR #N (what it does)
- Agent: bc-…, branch cursor/…
- CI: green/red (run link)
- Arezhik's test: pass/fail, with the checklist items that failed
- Decision: merged (commit) / waiting / logged as issue #N
-->
