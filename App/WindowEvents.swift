import AppKit
import SwiftUI
import MP4SubRipCore

// Two window patterns from PGS2SRT.
//
// 1. WindowEvents (use this by default). It observes the window's notifications and
//    logs minimize, restore, key, and close to the debug log. It never replaces the
//    window's delegate, so it cannot break what SwiftUI's own delegate does. PGS2SRT
//    #31 was hard to diagnose because the log had no window events at all.
//
// 2. SafeWindowDelegateProxy (use only when you must veto a close, such as for unsaved
//    edits). Copied from PGS2SRT's ReviewCloseProxy after the #31 fix (commit 2052471,
//    still waiting on Arezhik's retest). A Swift NSWindowDelegate otherwise answers
//    `responds(to:)` with YES for every optional method; AppKit then sends one that is
//    not implemented (windowDidMiniaturize: on minimize) and raises
//    NSInvalidArgumentException, and the window stops responding.
//    Rule: list every method you implement in `implemented`, forward everything else.

/// Attach with `.background { WindowEvents(name: "Queue") }`.
struct WindowEvents: NSViewRepresentable {
    var name: String

    func makeNSView(context: Context) -> WindowEventsView {
        let view = WindowEventsView()
        view.name = name
        return view
    }

    func updateNSView(_ view: WindowEventsView, context: Context) {
        view.name = name
    }
}

final class WindowEventsView: NSView {
    var name = "window"
    private var tokens: [NSObjectProtocol] = []
    private weak var observed: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== observed else { return }
        // Leaving a window (window == nil) also stops the old observers, so no deinit is needed.
        stopObserving()
        guard let window else { return }
        observed = window
        let events: [(Notification.Name, String)] = [
            (NSWindow.didBecomeKeyNotification, "became key"),
            (NSWindow.didMiniaturizeNotification, "minimized"),
            (NSWindow.didDeminiaturizeNotification, "restored"),
            (NSWindow.didEnterFullScreenNotification, "entered full screen"),
            (NSWindow.didExitFullScreenNotification, "left full screen"),
            (NSWindow.willCloseNotification, "will close")
        ]
        let name = self.name
        for (notification, label) in events {
            let token = NotificationCenter.default.addObserver(forName: notification, object: window, queue: .main) { _ in
                DebugLog.shared.record(.window, "\(name) window \(label)")
            }
            tokens.append(token)
        }
    }

    private func stopObserving() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens = []
        observed = nil
    }
}

/// Install with `proxy.install(on: window)` from an NSView's viewDidMoveToWindow.
/// Keep the proxy alive (store it on that view); NSWindow.delegate is weak.
final class SafeWindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var forward: NSWindowDelegate?
    var allowClose = false
    /// Return false to keep the window open, then call `closeNow(_:)` when ready.
    var shouldClose: (NSWindow) -> Bool = { _ in true }
    var onClose: () -> Void = {}

    func install(on window: NSWindow) {
        if window.delegate !== self {
            forward = window.delegate
            window.delegate = self
        }
    }

    func closeNow(_ window: NSWindow) {
        allowClose = true
        window.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose {
            allowClose = false
            return true
        }
        return shouldClose(sender)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
        forward?.windowWillClose?(notification)
    }

    /// Selectors this object actually implements. Add to this set whenever you add a
    /// delegate method above. Everything else goes to SwiftUI's own delegate.
    private static let implemented: Set<Selector> = [
        #selector(windowShouldClose(_:)),
        #selector(windowWillClose(_:))
    ]

    override func responds(to aSelector: Selector!) -> Bool {
        guard let aSelector else { return false }
        if Self.implemented.contains(aSelector) { return true }
        return forward?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard let aSelector, !Self.implemented.contains(aSelector) else { return nil }
        return forward
    }
}
