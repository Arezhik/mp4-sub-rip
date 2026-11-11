import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MP4SubRipCore

/// UserDefaults keys. Read them in one place so the debug log can describe them.
enum SettingsKey {
    static let placement = "outputPlacement"
    static let folder = "outputFolder"
    static let existingFile = "existingFile"
    static let recentFolders = RecentFolderList.defaultsKey

    static let placementNextToSource = "nextToSource"
    static let placementFolder = "folder"
}

/// The existing-file choice. Settings is the control for the whole run.
/// There is no per-file prompt and no Apply-to-all sheet. Skip is the default.
enum ExistingFileChoice: String, CaseIterable {
    case skip
    case overwrite
    case addNumber
}

/// One line for the debug log header and the launch line.
enum SettingsSummary {
    static func current(_ defaults: UserDefaults = FFmpegSettings.defaultsStore) -> String {
        let placement = defaults.string(forKey: SettingsKey.placement) ?? SettingsKey.placementNextToSource
        let folder = defaults.string(forKey: SettingsKey.folder) ?? ""
        let existing = defaults.string(forKey: SettingsKey.existingFile) ?? ExistingFileChoice.skip.rawValue
        let place = placement == SettingsKey.placementFolder ? "folder \(folder.isEmpty ? "(not chosen)" : folder)" : "next to the source file"
        let recentCount = RecentFolderList.load(defaults, key: SettingsKey.recentFolders).count
        let custom = FFmpegSettings.customPath(in: defaults)
        let resolved = ExternalTool.locate(.primary, customPath: custom)?["ffmpeg"]
        let ffmpeg = FFmpegSettings.summary(customPath: custom, resolvedPath: resolved)
        return "save \(place), recents \(recentCount), if the output exists \(existing), \(ffmpeg)"
    }
}

/// Opened from the app menu, ⌘, and the toolbar's SettingsLink.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var placement = UITestingLaunch.defaults.string(forKey: SettingsKey.placement) ?? SettingsKey.placementNextToSource
    @AppStorage(SettingsKey.existingFile) private var existingFile = ExistingFileChoice.skip.rawValue
    @AppStorage(FFmpegSettings.placementKey) private var ffmpegPlacement = FFmpegSettings.automatic
    @AppStorage(FFmpegSettings.pathKey) private var ffmpegPath = ""
    @State private var automaticPath = ""
    @State private var automaticVersion = ""
    @State private var lookedUpAutomatic = false
    @State private var customMissing = false

    var body: some View {
        Form {
            Section {
                Picker("Save the output", selection: $placement) {
                    Text("Next to the source file").tag(SettingsKey.placementNextToSource)
                    Text("In a folder I choose").tag(SettingsKey.placementFolder)
                }
                .pickerStyle(.radioGroup)
                .disabled(model.commands.flags.isRunning)

                if placement == SettingsKey.placementFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(model.outputChoice.folderPath.isEmpty ? "No folder chosen" : model.outputChoice.folderPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(model.outputChoice.folderPath.isEmpty ? .secondary : .primary)
                            Button("Choose…") { model.chooseOutputFolder() }
                                .disabled(model.commands.flags.isRunning)
                        }
                    }
                }

                Picker("If the output file already exists", selection: $existingFile) {
                    Text("Skip that file").tag(ExistingFileChoice.skip.rawValue)
                    Text("Overwrite it").tag(ExistingFileChoice.overwrite.rawValue)
                    Text("Add a number").tag(ExistingFileChoice.addNumber.rawValue)
                }
            } header: {
                Text("Output")
            }

            Section {
                Picker("Location", selection: $ffmpegPlacement) {
                    Text("Find it automatically").tag(FFmpegSettings.automatic)
                    Text("Use a copy I choose").tag(FFmpegSettings.custom)
                }
                .pickerStyle(.radioGroup)

                if ffmpegPlacement == FFmpegSettings.automatic {
                    LabeledContent("Found") {
                        if !lookedUpAutomatic {
                            Text("Checking…")
                                .foregroundStyle(.secondary)
                        } else if automaticPath.isEmpty {
                            Text("Not found")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(automaticPath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !automaticVersion.isEmpty {
                                    Text(automaticVersion)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }
                }

                if ffmpegPlacement == FFmpegSettings.custom {
                    LabeledContent("File") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ffmpegPath.isEmpty ? "No file chosen." : ffmpegPath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(ffmpegPath.isEmpty || customMissing ? .secondary : .primary)
                                if customMissing {
                                    Text("Can't be found")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Button("Choose…") { chooseFFmpeg() }
                        }
                    }
                }
            } header: {
                Text("ffmpeg")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
        .onAppear { placement = model.outputChoice.placement }
        .onChange(of: placement) {
            let value = placement
            DispatchQueue.main.async {
                model.setOutputPlacement(value)
                if model.outputChoice.placement != value {
                    placement = model.outputChoice.placement
                }
            }
        }
        .onChange(of: model.outputChoice.placement) {
            if placement != model.outputChoice.placement {
                placement = model.outputChoice.placement
            }
        }
        .onChange(of: existingFile) { logChange() }
        .onChange(of: ffmpegPlacement) { logChange() }
        .task(id: ffmpegStatusToken) { await refreshFFmpegStatus() }
    }

    private var ffmpegStatusToken: String {
        "\(ffmpegPlacement)\u{1e}\(ffmpegPath)"
    }

    /// Settings changes go to the debug log so a tester's log shows what was set.
    private func logChange() {
        DebugLog.shared.record(.lifecycle, "Settings \(SettingsSummary.current())")
    }

    private func refreshFFmpegStatus() async {
        let placement = ffmpegPlacement
        let path = ffmpegPath
        let token = ffmpegStatusToken
        if placement == FFmpegSettings.automatic {
            lookedUpAutomatic = false
        }
        let status = await Task.detached(priority: .userInitiated) { () -> (String, String, Bool) in
            if placement == FFmpegSettings.custom {
                let missing = !path.isEmpty && FFmpegSettings.runnableExecutable(at: path) == nil
                return ("", "", missing)
            }
            guard let located = ExternalTool.describe(.primary, customPath: nil).located else {
                return ("", "", false)
            }
            return (located.path, located.version, false)
        }.value
        if Task.isCancelled || token != ffmpegStatusToken { return }
        automaticPath = status.0
        automaticVersion = status.1
        customMissing = status.2
        lookedUpAutomatic = true
    }

    private func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        // A symlink in ~/bin should stay that path. Resolving it would store the target.
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.unixExecutable, .application, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let resolved = FFmpegSettings.validatedExecutable(at: url.path) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That isn't a usable ffmpeg."
            alert.informativeText = "It has to be ffmpeg. The previous choice was kept."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        ffmpegPath = resolved
        customMissing = false
        logChange()
    }
}
