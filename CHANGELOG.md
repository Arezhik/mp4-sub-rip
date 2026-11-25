# Changelog

All notable changes to MP4SubRip. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions: [Semantic Versioning](https://semver.org/), MAJOR.MINOR.PATCH.

Every merged PR that changes the shipped app bumps the version in the same PR with `scripts/bump-version.sh patch|minor|major`, which also adds 1 to the build number and adds a stub section here. Fill it in with one line per user-visible change, under Added, Changed, Fixed, or Removed, with the PR or issue number. Docs-only and CI-only PRs don't bump.

## [Unreleased]

## [0.7.0] - 2026-11-25 (build 9)
### Added
- Files are probed when they join the queue, so language, closed-caption, and image-subtitle chips show before Extract. A file with no text subtitles, or only image subtitles, is marked right away and is not started (#7).
- Save to, under the queue, writes every .srt into a chosen folder and remembers the last three folders. It is disabled while extracting (#9).
- Failed rows can be retried. Clear Processed leaves failures in the list; hold Option, or choose Clear All Finished, to remove them too. Rows can be removed, revealed, and opened from the table (#10).

### Changed
- When the .srt is already there and Skip is selected, the row says Done · skipped (exists). Overwrite and Add a number are unchanged, and nothing asks in the middle of a batch (#8).

## [0.6.1] - 2026-11-14 (build 8)
### Fixed
- A line of only spaces or tabs inside a subtitle no longer splits the cue in the written .srt.

## [0.6.0] - 2026-11-11 (build 7)
### Added
- Settings can find ffmpeg automatically or use a copy you choose. A missing chosen copy is reported and is not replaced by another ffmpeg (#36).

### Fixed
- Extract Subtitles enables again after Stop, once the cancelled file finishes cleaning up (#39).

## [0.5.0] - 2026-11-10 (build 6)
### Added
- Extract Subtitles (⌘↩) runs the queue and becomes Stop (⌘.) while a file is extracting. Adding files waits until then. Stopped rows go back to Pending (#6).
- A failed row shows Failed and the reason, with the full message in a tooltip and Show Error…. Skipped rows stay gray (#5).

### Changed
- The window opens at 900×600. The open button is Add Files (⌘O). Adding a file that is already queued highlights that row (#3).

## [0.4.1] - 2026-11-10 (build 5)
### Fixed
- ffmpeg SRT cues that packed several captions together break onto their own lines, overlapping captions share one timeline, and a last cue shorter than one second stays up a little longer (#32).

## [0.4.0] - 2026-11-09 (build 4)
### Added
- The app icon is the Page design: a light silver rounded body, a blue play tile, and subtitle pages. Small sizes drop the back page (#31).

## [0.3.0] - 2026-11-09 (build 3)
### Added
- Discrete EIA-608 closed captions (`c608`) are extracted to .srt with ffmpeg. CEA-708 and captions that live only in the video are still reported and skipped. A closed-caption file is skipped when ffmpeg is missing (#27).

## [0.2.0] - 2026-11-06 (build 2)
### Added
- Dropping an MP4 extracts its text subtitles (tx3g) to .srt. One track is `Movie.srt`; several languages are `Movie.eng.srt`, and a forced track is marked. Bitmap subtitles, closed captions, and DRM-protected files are reported and skipped (#2).

## [0.1.0] - 2026-11-04 (build 1)
### Added
- Project created with new-mac-app.sh: queue window with drag and drop, Settings, and Help > Export Debug Log.
