# MP4SubRip: spec

Created 2026-11-04. Keep this short. Coding agents work from it, so update it when a decision changes.

## Goal
One or two sentences: who it's for and what it does.

## Decisions
- Platform: macOS 14.0+, universal (arm64 + x86_64), SwiftUI, unsigned CI build.
- Bundle ID: `com.arezhik.MP4SubRip` (don't change it after testers install the app).
- Input: .mp4 files and folders, from the window, Open…, the Dock, and Open With.
- Output: next to the input by default, or a chosen folder. Not sandboxed.
- Existing output file: Skip (default), Overwrite, or Add a number, from Settings. The engine applies that choice. Asking once per batch with "Apply to all" is still queue UI.
- External tools: none for extraction. AVFoundation reads tx3g. ffmpeg is located and logged at launch, and `SubtitleMediaReading` is the seam for a fallback, but it is not called.
- Subtitles: text tracks only (`tx3g` / mov_text). Bitmap, closed captions, WebVTT-in-MP4, DRM, and any other codec are reported with a typed reason and not extracted.
- Design source: <Design Bot spec and mockups path>.

## Architecture
- `MP4SubRipKit` package (`Sources/MP4SubRipCore`): all logic that doesn't need AppKit, testable on Linux.
- `App/`: thin SwiftUI app. It feeds the core and shows progress.
- Engine rules: check `Task.checkCancellation()` in every long loop, delete half-written output on cancel, and report progress through `AppModel.report` (throttled to about 10 updates a second).

## Phase 1 scope (the smallest version that's useful)
1. Extract embedded tx3g text tracks from an MP4 to .srt (issue #2). Dropping a file on the window runs it, one file at a time.
2. …

### Definition of done for Phase 1
- [ ] `swift test` passes on Linux and macOS CI, and covers the engine with small generated fixtures.
- [ ] The universal app builds in CI and the zip artifact launches on Apple silicon and Intel.
- [ ] Every item in docs/PR_TEST_CHECKLIST.md passes on Arezhik's Mac.
- [ ] Help → Export Debug Log shows the launch, each file's start and finish, errors, and tool versions.

## Later phases
Nice-to-haves go here, or become low-priority `enhancement` issues. They don't go into the current PR.

## Out of scope
- …
