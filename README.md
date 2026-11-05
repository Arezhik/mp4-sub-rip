# MP4SubRip

A native macOS app (SwiftUI, macOS 14.0 or later, universal for Apple silicon and Intel).
It takes .mp4 files and folders. Describe what it does here in one sentence.

## Use the window
- Drop files or a folder on the window, or choose **Open…** (⌘O).
- Drop them on the Dock icon, or right-click a file in Finder and choose **Open With → MP4SubRip**. Files go into the window that's already open.
- **Cancel All** (⌘.) stops everything that's running. **Clear Finished** (⌘⌫) removes finished rows from the list; it never deletes files.
- **Settings** (⌘,) holds the output options.
- **Help → Export Debug Log…** saves a log to the Desktop to send with a bug report.

## Needs ffmpeg
MP4SubRip runs `ffmpeg`, which isn't part of macOS. Install it with Homebrew (`brew install ffmpeg`) or from its website. The app looks in `/opt/homebrew/bin`, `/usr/local/bin`, `/Applications/ffmpeg*.app/Contents/MacOS`, then `PATH`. Record the version you tested in TESTERS.md, and test an Intel Mac early (PGS2SRT found MKVToolNix v97+ failing on an Intel Mac Pro while v96 worked).

## Open it in Xcode and press Run
1. Quit Xcode. In the repository folder, delete `.build` if you see one, then run `rm -rf ~/Library/Developer/Xcode/DerivedData/MP4SubRip-*`.
2. Double-click **`App/MP4SubRip.xcodeproj`**. Don't open `Package.swift`; that's the core library.
3. If Xcode asks whether to trust the project, choose Trust, and wait for the package to load.
4. Check that the scheme says **MP4SubRip** and the destination says **My Mac**, then press ⌘R.

The project is set to **Sign to Run Locally**, so no Apple Developer team is needed. If Xcode asks for one, select the MP4SubRip target, open Signing & Capabilities, and choose **Sign to Run Locally**.

### Why the project is set up this way
- The core logic is a Swift package named **MP4SubRipKit** at the repository root, with no AppKit or SwiftUI, so `swift test` runs on Linux and in cloud agents.
- The Xcode project is in `App/`, one folder down, and has a different name from the package. Xcode's window reports the package products as missing when the two share a name and a folder.
- Debug builds only the chip in your Mac. Release builds both arm64 and x86_64.
- The app isn't sandboxed, so it can write output next to the input file.
- `App/project.yml` is an optional [XcodeGen](https://github.com/yonaskolb/XcodeGen) recipe for regenerating the project. The checked-in `.xcodeproj` is the one to open.

## Download the app that GitHub built
1. On GitHub, open **Actions** and choose the latest green **CI** run.
2. Under **Artifacts**, download **MP4SubRip-universal.zip** and unzip it.
3. The app isn't signed or notarized. Right-click it and choose **Open**, or go to **System Settings → Privacy & Security** and click **Open Anyway**. If macOS says the app is damaged, run `xattr -dr com.apple.quarantine /path/to/MP4SubRip.app`.

## Versioning
The version is MAJOR.MINOR.PATCH (shown in About MP4SubRip), plus a build number that goes up by 1 on every merged PR. Bump it in the same PR as the change with `scripts/bump-version.sh patch|minor|major`: patch for a bug fix or small tweak, minor for a new feature, and major for a major enhancement or a new phase. Docs-only and CI-only PRs don't bump. Each version gets an entry in CHANGELOG.md.

## For developers
```bash
swift test      # the core package, on macOS or Linux
swift build
```
- `SPEC.md` has the scope and the definition of done for the current phase.
- `AGENTS.md` has the rules for coding agents. Read it before the first change.
- `scripts/bump-version.sh --check` confirms the version agrees everywhere (CI runs it).
- `docs/PR_TEST_CHECKLIST.md` is the template for each PR's printable test sheet.
- `TESTERS.md` is the guide for friends who test builds.
