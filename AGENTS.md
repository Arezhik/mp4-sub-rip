# Rules for this repo (macOS app; from PGS2SRT lessons)
- Native Swift/SwiftUI macOS app, universal (arm64 + x86_64), unsigned, not sandboxed.
- You run on Linux and can't run Xcode or the app. Put logic in the Swift package (no AppKit or SwiftUI) and cover it with `swift test`. CI on macOS is the real build check.
- Don't rename the package to the app's name, and don't move the `.xcodeproj` out of `App/`. If you add or rename an app file, edit `App/MP4SubRip.xcodeproj/project.pbxproj` and `App/project.yml`.
- Fix only the issue you were given. Note other problems in the PR description instead of fixing them.
- Build with `-strict-concurrency=complete -warnings-as-errors`. Keep the core Sendable-clean.
- Every long loop checks `Task.checkCancellation()`, including reading and decoding. Cancel deletes partial output.
- Never write `@Published` or observed state during a view update. Controls keep local `@State` and write the model on the next run-loop turn (`DispatchQueue.main.async` or `Task { @MainActor in }`).
- Throttle progress to about 10 updates a second. Menu commands read only `CommandFlags`, which publish only when they change.
- Don't replace a window's delegate. Observe `NSWindow` notifications. If you must replace it, use `SafeWindowDelegateProxy` and list every method you implement.
- Don't set window properties from `layout()`.
- Every toolbar item is also in the menu bar. Settings opens with `SettingsLink` or `openSettings`.
- Dock drops and Open With reuse the one open window. Folders walk subfolders.
- Clear Finished and the row ✕ act only on finished, failed, skipped, or canceled rows. Never delete files on disk. An empty queue shows the drop screen. No confirmation.
- Existing output: ask once per batch with "Apply to all". Never ask per file mid-batch.
- Reveal in Finder checks the file exists first, uses `activateFileViewerSelecting`, and logs the call.
- External tools: search /opt/homebrew/bin, /usr/local/bin, /Applications/<Tool>*.app/Contents/MacOS, then PATH. Log the command, exit code, and stderr (cut at 2,000 characters). Show a clear message if the tool is missing.
- Log through `DebugLog.shared.record(...)`: launch, settings, each file's start, finish, and error, window events, Saves, and Reveal. No user content. Home becomes `~`.
- Add a test with every bug fix. Use small generated fixtures and keep real media out of git.
- In the PR description, list the test steps for Arezhik to run on his Mac. He tests and approves every merge.
- Versioning (SemVer): in the same PR, run `scripts/bump-version.sh patch` for a bug fix or small tweak, `minor` for a new feature, or `major` for a major enhancement or new phase. Docs-only and CI-only PRs don't bump.
- The build number goes up by 1 with every bump and is never reused. Don't edit the version by hand. The script keeps project.pbxproj and project.yml in sync, and `--check` must pass.
- Fill in the CHANGELOG.md entry. Put `Version bump: old to new (rule)` in the PR description. Arezhik confirms it at merge.

## This project
- App MP4SubRip, bundle ID `com.arezhik.MP4SubRip`, macOS 14.0+.
- Package `MP4SubRipKit` (module `MP4SubRipCore`, tests `MP4SubRipCoreTests`). Xcode project `App/MP4SubRip.xcodeproj`, scheme `MP4SubRip`.
- Version: `scripts/bump-version.sh --current` (started at 0.1.0, build 1). History: CHANGELOG.md.
- Scope: SPEC.md. Test sheet template: docs/PR_TEST_CHECKLIST.md. CI artifact: `MP4SubRip-universal.zip`.
