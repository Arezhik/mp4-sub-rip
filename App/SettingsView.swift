import AppKit
import SwiftUI
import MP4SubRipCore

/// UserDefaults keys. Read them in one place so the debug log can describe them.
enum SettingsKey {
    static let placement = "outputPlacement"
    static let folder = "outputFolder"
    static let existingFile = "existingFile"

    static let placementNextToSource = "nextToSource"
    static let placementFolder = "folder"
}

/// The existing-file choice. Ask once per batch with "Apply to all", never once per
/// file in the middle of a run (PGS2SRT #5). Pick the default with Arezhik and test it.
enum ExistingFileChoice: String, CaseIterable {
    case skip
    case overwrite
    case addNumber
}

/// One line for the debug log header and the launch line.
enum SettingsSummary {
    static func current(_ defaults: UserDefaults = .standard) -> String {
        let placement = defaults.string(forKey: SettingsKey.placement) ?? SettingsKey.placementNextToSource
        let folder = defaults.string(forKey: SettingsKey.folder) ?? ""
        let existing = defaults.string(forKey: SettingsKey.existingFile) ?? ExistingFileChoice.skip.rawValue
        let place = placement == SettingsKey.placementFolder ? "folder \(folder.isEmpty ? "(not chosen)" : folder)" : "next to the source file"
        return "save \(place), if the output exists \(existing)"
    }
}

/// Opened from the app menu, ⌘, and the toolbar's SettingsLink.
struct SettingsView: View {
    @AppStorage(SettingsKey.placement) private var placement = SettingsKey.placementNextToSource
    @AppStorage(SettingsKey.folder) private var outputFolder = ""
    @AppStorage(SettingsKey.existingFile) private var existingFile = ExistingFileChoice.skip.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Save the output", selection: $placement) {
                    Text("Next to the source file").tag(SettingsKey.placementNextToSource)
                    Text("In a folder I choose").tag(SettingsKey.placementFolder)
                }
                .pickerStyle(.radioGroup)

                if placement == SettingsKey.placementFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(outputFolder.isEmpty ? "No folder chosen" : outputFolder)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(outputFolder.isEmpty ? .secondary : .primary)
                            Button("Choose…") { chooseFolder() }
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
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
        .onChange(of: placement) { logChange() }
        .onChange(of: existingFile) { logChange() }
    }

    /// Settings changes go to the debug log so a tester's log shows what was set.
    private func logChange() {
        DebugLog.shared.record(.lifecycle, "Settings \(SettingsSummary.current())")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFolder = url.path
        logChange()
    }
}
