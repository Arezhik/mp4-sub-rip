# Changelog

All notable changes to MP4SubRip. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions: [Semantic Versioning](https://semver.org/), MAJOR.MINOR.PATCH.

Every merged PR that changes the shipped app bumps the version in the same PR with `scripts/bump-version.sh patch|minor|major`, which also adds 1 to the build number and adds a stub section here. Fill it in with one line per user-visible change, under Added, Changed, Fixed, or Removed, with the PR or issue number. Docs-only and CI-only PRs don't bump.

## [Unreleased]

## [0.3.1] - 2026-11-09 (build 4)
### Added
- Discrete EIA-608 extracts still come from ffmpeg. The debug log also records an `AVAssetReaderOutputCaptionAdaptor` read of that `c608` track (group count, the first captions, and validation skips) and whether it matches the cleaned ffmpeg SRT. ffmpeg stays the writer (#28).

## [0.3.0] - 2026-11-09 (build 3)
### Added
- Discrete EIA-608 closed captions (`c608`) are extracted to .srt with ffmpeg. CEA-708 and captions that live only in the video are still reported and skipped. A closed-caption file is skipped when ffmpeg is missing (#27).

## [0.2.0] - 2026-11-06 (build 2)
### Added
- Dropping an MP4 extracts its text subtitles (tx3g) to .srt. One track is `Movie.srt`; several languages are `Movie.eng.srt`, and a forced track is marked. Bitmap subtitles, closed captions, and DRM-protected files are reported and skipped (#2).

## [0.1.0] - 2026-11-04 (build 1)
### Added
- Project created with new-mac-app.sh: queue window with drag and drop, Settings, and Help > Export Debug Log.
