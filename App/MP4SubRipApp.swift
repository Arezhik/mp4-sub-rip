import SwiftUI
import MP4SubRipCore

// Structure copied from PGS2SRT (App/PGS2SRTApp.swift): one queue WindowGroup that
// claims Dock and Open With events, a Settings scene, and Help > Export Debug Log.
@main
struct MP4SubRipApp: App {
    // @State, not @StateObject (a change from PGS2SRT, not yet tried on a Mac): an
    // App that observes the model re-runs this body, and its menus, on every queue
    // change. That is the likely cause of PGS2SRT #35 (menus flicker while
    // converting). Views still observe the model through .environmentObject.
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .defaultAppStorage(UITestingLaunch.defaults)
                // An open queue window takes the file, instead of a new window (PGS2SRT #10).
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        // When no window is open, this scene may create one for a Dock or Open With drop.
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 900, height: 600)
        .commands {
            AppCommands(model: model, state: model.commands)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .defaultAppStorage(UITestingLaunch.defaults)
        }
    }
}

/// Menu bar items. They read only `CommandState`, which changes rarely, never the
/// queue rows or `runPresentation`. Progress, the ETA, and the Dock badge stay
/// on `AppModel`, so an open menu does not rebuild during a run (PGS2SRT #35).
/// Every toolbar button must also be here (PGS2SRT #7, #28).
struct AppCommands: Commands {
    let model: AppModel
    @ObservedObject var state: CommandState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Files") { model.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Choose Output Folder…") { model.chooseOutputFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(state.flags.isRunning)
            if state.flags.isRunning {
                Button("Stop") { model.stopExtraction() }
                    .keyboardShortcut(".")
            } else {
                Button("Extract Subtitles") { model.extractSubtitles() }
                    .keyboardShortcut(KeyEquivalent.return, modifiers: .command)
                    .disabled(!state.flags.canExtract)
            }
            Button("Cancel All") { model.cancelAll() }
                .disabled(!state.flags.isRunning)
            Button("Clear Processed") { model.clearProcessed(includingFailed: false) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!state.flags.canClearProcessed)
            Button("Clear All Finished") { model.clearProcessed(includingFailed: true) }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(!state.flags.canClearAllFinished)
        }

        CommandMenu("Queue") {
            Button("Retry") { model.retrySelection() }
                .disabled(!state.flags.canRetry)
            Button("Reveal in Finder") { model.revealSelection() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!state.flags.canReveal)
            Button("Show Video in Finder") { model.showVideoSelection() }
                .disabled(!state.flags.canShowVideo)
            Button("Open Subtitle") { model.openSubtitleSelection() }
                .disabled(!state.flags.canOpenSubtitle)
            Button("Show Error…") { model.showErrorSelection() }
                .disabled(!state.flags.canShowError)
            Divider()
            Button("Remove from Queue") { model.removeSelection() }
                .disabled(!state.flags.canRemoveSelection)
        }

        CommandGroup(replacing: .help) {
            Button("Export Debug Log…") {
                model.exportDebugLog()
            }
        }
    }
}
