# MP4SubRip tester guide

Thanks for testing! This is an early build. Please try to break it and tell me what happened.

## What you need
- A Mac running macOS 14.0 or later (Apple silicon or Intel).
- A few real .mp4 files that contain SRT-style (text) subtitles, including one with more than one language if you have it. A large file is useful too.
- ffmpeg is required for EIA-608 closed captions. Text subtitles (tx3g) do not need it. The debug log says whether ffmpeg was found.

## 1. Install
1. Unzip `MP4SubRip-universal.zip` and drag **MP4SubRip.app** into **Applications**.
2. Double-click it. macOS will say it can't verify the app, because it isn't signed by Apple. Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to MP4SubRip.
4. If macOS says the app **"is damaged and can't be opened"**, run this in Terminal, then open it again:
   `xattr -dr com.apple.quarantine /Applications/MP4SubRip.app`

## 2. Basic use
1. Drag a file onto the window. Watch its row move from Waiting to working to Done.
2. Click **Reveal in Finder** and check the output file.

## 3. Other ways to add files
- **Open…** (⌘O), a **folder** dropped on the window, files dropped on the **Dock icon**, and **Open With** in Finder. Each should use the same window, without opening a second one.

## 4. Things to try
- Several files at once, and a folder with subfolders.
- **Cancel** and **Cancel All** (⌘.) while a file is still starting. It should stop right away and leave no half-written file.
- The same file twice. Check the existing-file setting is followed.
- Delete an output file, then click **Reveal in Finder**. You should get a clear message.
- Clear Finished (⌘⌫) and the ✕ on a finished row. Files on disk must not be touched.
- A large file on a network drive.
- Open a menu while a file is working. It shouldn't flicker.

## 5. Reporting a problem
1. Choose **Help → Export Debug Log…**. It saves a file to your Desktop. Send it to me.
2. Tell me what you did, what you expected, and what happened, with a screenshot (⌘⇧4).
3. Tell me your Mac model and macOS version (Apple menu → About This Mac).

## Known limits in this build
- Not signed by Apple, so the Open Anyway step is needed once.
- Text subtitles (tx3g) and discrete EIA-608 closed captions (`c608`, via ffmpeg). CEA-708 and captions that exist only in the video are skipped with a message. Image subtitles are skipped too.
- One file at a time. The full queue (parallel, track chips, conflict prompt) is not in this build yet. Settings still choose Skip, Overwrite, or Add a number.
