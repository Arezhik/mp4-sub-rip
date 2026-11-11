# PR #___ test checklist: <title>

App: MP4SubRip · Branch: `cursor/…` · Commit: `…` · Date: ____ · Mac: ____ · macOS: ____

Version bump: ____ (build __) to ____ (build __) (rule: patch / minor / major / none: docs or CI only). Arezhik confirms this with the merge.

Print this, or copy it into the PR. Mark each line Pass or Fail, and write notes for every Fail.
Arezhik approves the merge only after this sheet passes.

## Setup
- [ ] Pull the branch. Quit Xcode, delete DerivedData for MP4SubRip, open `App/MP4SubRip.xcodeproj`, then Run (⌘R).
- [ ] CI is green: Linux tests, macOS tests, and the universal app. The `MP4SubRip-universal.zip` artifact is attached.
- [ ] About MP4SubRip (app menu) and the debug log header show the new version and build. CHANGELOG.md has the entry.

## What this PR changes
1. [ ] Pass / Fail: <step> → <expected result>
2. [ ] Pass / Fail: …

## Regression checks (every PR)
- [ ] A file dropped on the window, a folder (with subfolders), Add Files (⌘O), a Dock drop, and Open With all add to the one window (PGS2SRT #10, #11).
- [ ] Every toolbar button and menu item does something, including Settings (⌘, and the toolbar button) (PGS2SRT #7).
- [ ] Cancel and Cancel All stop right away, at every stage, and leave no partial output (PGS2SRT #6).
- [ ] Clear Finished and the row ✕ remove only finished rows, never files on disk. An empty list shows the drop screen (PGS2SRT #8).
- [ ] Reveal in Finder works, and gives a clear message when the file is gone (PGS2SRT #9, #33).
- [ ] Minimize, restore, full screen, and close each window. It still responds afterwards (PGS2SRT #31).
- [ ] Open a menu during a long run. No flicker (PGS2SRT #35).
- [ ] The Xcode console shows no purple runtime warnings, such as "Publishing changes from within view updates", when you click controls with the mouse and with shortcuts (PGS2SRT #30).
- [ ] Help → Export Debug Log saves to the Desktop, and the new feature's events are in it.
- [ ] With `ffmpeg` missing, a clear message appears and nothing crashes. With it installed, the debug log shows its path and version, and whether it was found automatically or chosen in Settings.

## Notes
________________________________________________________________
________________________________________________________________
