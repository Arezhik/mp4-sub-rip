import AppKit
import MP4SubRipCore

/// Receives files opened from the Dock or from Finder's Open With.
/// Copied from PGS2SRT (App/AppModel.swift, PR #14 for issues #10 and #11).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files that arrive before the window exists, plus the handler that takes later ones.
    /// The lock is why this shared state is safe to touch from the Dock callback.
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var deliver: (([URL]) -> Void)?
        private var pending: [URL] = []

        func accept(_ urls: [URL]) {
            lock.lock()
            let deliver = self.deliver
            if deliver == nil {
                pending.append(contentsOf: urls)
            }
            lock.unlock()
            deliver?(urls)
        }

        func setDeliver(_ deliver: @escaping ([URL]) -> Void) -> [URL] {
            lock.lock()
            self.deliver = deliver
            let urls = pending
            pending = []
            lock.unlock()
            return urls
        }
    }

    private static let inbox = Inbox()

    /// Set once `applicationDidFinishLaunching` has run. Tool detection waits
    /// for this: a check started inside `AppModel.init` reported ffmpeg missing
    /// on 2026-11-09 while the later debug-log header found it.
    private(set) static var isFinishedLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.isFinishedLaunching = true
        AppModel.shared?.logInstalledTools()
    }

    /// Asks before quitting in the middle of a run.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.shared, model.commands.flags.hasActiveWork else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop the files that are still running and quit?"
        alert.informativeText = "Files that have not finished will need to be added again."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.buttons.count > 1 {
            alert.buttons[1].keyEquivalent = "\u{1b}"
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.cancelAll()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.shared.record(.lifecycle, "Quit")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppDelegate.inbox.accept(urls)
        // The open event can also create a window. Drop the extra one after
        // SwiftUI has had a turn to show it, and again once its view exists.
        Task { @MainActor in
            QueueWindow.keepOne()
            await Task.yield()
            QueueWindow.keepOne()
        }
    }

    /// Installs the handler and returns files that arrived before the window existed.
    static func setDeliver(_ deliver: @escaping ([URL]) -> Void) -> [URL] {
        inbox.setDeliver(deliver)
    }
}

/// The queue window, as opposed to Settings. Dock and Open With drops keep one of these.
enum QueueWindow {
    static let marker = NSUserInterfaceItemIdentifier("com.arezhik.MP4SubRip.queue")

    @MainActor
    static func keepOne() {
        let windows = NSApp.windows
            .filter { $0.identifier == marker && ($0.isVisible || $0.isMiniaturized) }
            .sorted { $0.windowNumber < $1.windowNumber }
        guard let keeper = windows.first else { return }
        for extra in windows.dropFirst() {
            extra.close()
        }
        if keeper.isMiniaturized {
            keeper.deminiaturize(nil)
        }
        keeper.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
