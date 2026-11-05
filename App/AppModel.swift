import AppKit
import Foundation
import UniformTypeIdentifiers
import MP4SubRipCore

/// The few values the menus depend on. `update` assigns only when a value changes,
/// because `@Published` notifies on every assignment, even an equal one.
@MainActor
final class CommandState: ObservableObject {
    @Published private(set) var flags = CommandFlags()

    func update(from items: [QueueItem]) {
        let next = CommandFlags.from(items)
        if next != flags {
            flags = next
        }
    }
}

/// Owns the queue, the open panel, and the debug log. The window watches this object.
/// The real work (the engine) belongs in the MP4SubRipCore package so it can be tested
/// with `swift test` on Linux; this class only feeds it and shows its progress.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var items: [QueueItem] = []
    @Published private(set) var banners: [String] = []
    let commands = CommandState()
    static weak var shared: AppModel?

    private var throttles: [UUID: ProgressThrottle] = [:]

    init() {
        DebugLog.shared.configure(directory: DebugLog.libraryLogsDirectory, mirror: { AppLog.write($0) })
        logLaunch()
        AppModel.shared = self
        let pending = AppDelegate.setDeliver { urls in
            let urls = urls
            Task { @MainActor in
                AppModel.shared?.importURLs(urls)
            }
        }
        if !pending.isEmpty {
            importURLs(pending)
        }
        logToolDetection()
    }

    // MARK: Adding files

    /// Drops on the window, Open…, the Dock icon, and Finder's Open With all end up here.
    func importURLs(_ urls: [URL]) {
        let paths = urls.map(\.path)
        // Folder walks touch the disk. Keep them off the main thread if folders can be
        // large or on a network share (NAS over Wi-Fi was slow in PGS2SRT testing).
        let result = FileIntake.collect(paths: paths, listing: .live)
        var added = 0
        for path in result.sourcePaths where !items.contains(where: { $0.path == path && $0.status.isActive }) {
            items.append(QueueItem(path: path))
            added += 1
        }
        for notice in result.notices {
            banners.append(notice.message)
            DebugLog.shared.record(.queue, "Notice: \(notice.message)", isWarning: true)
        }
        DebugLog.shared.record(.queue, "Added \(added) of \(paths.count) dropped or opened items")
        commands.update(from: items)
        // TODO(engine): start the next waiting item. One file at a time first; add
        // parallel mode later, and keep progress throttled when you do.
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add Files"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        var types: [UTType] = [.folder]
        for ext in AppIdentity.inputExtensions.sorted() {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    // MARK: Progress from the engine

    /// Call for every status change. Counter-only ticks are throttled to about
    /// 10 a second per row (PGS2SRT #35). Every other change shows right away.
    func report(_ status: JobStatus, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[index].status
        if old.isProgressTick(to: status) {
            var throttle = throttles[id] ?? ProgressThrottle()
            let publish = throttle.shouldPublish()
            throttles[id] = throttle
            guard publish else { return }
        } else {
            throttles[id] = nil
            logStatus(status, for: items[index])
        }
        items[index].status = status
        commands.update(from: items)
    }

    private func logStatus(_ status: JobStatus, for item: QueueItem) {
        switch status {
        case .waiting:
            break
        case .working:
            DebugLog.shared.record(.work, "Started \(item.fileName)")
        case let .done(outputPath):
            DebugLog.shared.record(.work, "Finished \(item.fileName) -> \(outputPath)")
        case let .failed(reason):
            DebugLog.shared.record(.work, "Failed \(item.fileName): \(reason)", isError: true)
        case let .skipped(reason):
            DebugLog.shared.record(.work, "Skipped \(item.fileName): \(reason)", isWarning: true)
        case .canceled:
            DebugLog.shared.record(.work, "Canceled \(item.fileName)")
        }
    }

    // MARK: Queue actions

    func cancel(id: UUID) {
        // TODO(engine): cancel the running Task for this row. The engine must call
        // Task.checkCancellation() inside every long loop, including reading and
        // decoding (PGS2SRT #6), and delete a half-written output file.
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status.isActive else { return }
        report(.canceled, for: id)
    }

    func cancelAll() {
        for item in items where item.status.isActive {
            cancel(id: item.id)
        }
    }

    /// Removes the row only. The output file on disk is never touched (PGS2SRT #8).
    func remove(id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.status.isRemovable else { return }
        items.removeAll { $0.id == id }
        commands.update(from: items)
    }

    /// No confirmation. An empty list goes back to the drop screen (PGS2SRT #8).
    func clearFinished() {
        let before = items.count
        items.removeAll { $0.status.isRemovable }
        DebugLog.shared.record(.queue, "Cleared \(before - items.count) finished rows")
        commands.update(from: items)
    }

    func dismissBanner(at index: Int) {
        guard banners.indices.contains(index) else { return }
        banners.remove(at: index)
    }

    // MARK: Finder

    /// Checks that the file is still there first (PGS2SRT #9), and logs the call (#33).
    func reveal(_ item: QueueItem) {
        guard case let .done(path) = item.status else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            DebugLog.shared.record(.lifecycle, "Reveal in Finder \(path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        DebugLog.shared.record(.lifecycle, "Reveal in Finder: file missing \(path)", isWarning: true)
        let folder = url.deletingLastPathComponent()
        let alert = NSAlert()
        alert.messageText = "\(url.lastPathComponent) can't be found."
        alert.informativeText = "It may have been moved, renamed, or deleted."
        let folderExists = FileManager.default.fileExists(atPath: folder.path)
        if folderExists {
            alert.addButton(withTitle: "Show Folder")
        }
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn && folderExists {
            NSWorkspace.shared.open(folder)
        }
    }

    // MARK: Debug log

    /// Help menu. The file lands on the Desktop, with a save panel if that fails.
    func exportDebugLog() {
        let settings = SettingsSummary.current()
        Task {
            let environment = await Task.detached(priority: .userInitiated) {
                DebugMachine.environment(settings: settings)
            }.value
            let name = DebugLogDocument.fileName(at: Date())
            DebugLog.shared.record(.lifecycle, "Exporting debug log \(name)")
            let text = DebugLogDocument.document(
                environment: environment,
                logText: DebugLog.shared.recentText(),
                homeDirectory: NSHomeDirectory()
            )
            DebugLogExporter.write(text: text, fileName: name)
        }
    }

    private func logLaunch() {
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        DebugLog.shared.record(.lifecycle, "Launched \(AppVersion.marketing) (\(AppVersion.build)), \(system)")
        DebugLog.shared.record(.lifecycle, "Settings \(SettingsSummary.current())")
    }

    private func logToolDetection() {
        Task.detached {
            let spec = ExternalToolSpec.primary
            if let tools = ExternalTool.locate(spec) {
                let first = spec.executables.first ?? spec.name
                let version = tools[first].flatMap { ExternalTool.version(of: $0, arguments: spec.versionArguments) } ?? "unknown"
                let paths = spec.executables.compactMap { tools[$0] }.joined(separator: ", ")
                DebugLog.shared.record(.tool, "\(spec.name) found \(paths), version \(version)")
            } else {
                DebugLog.shared.record(.tool, "\(spec.name) not found", isError: true)
            }
        }
    }
}
