import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import MP4SubRipCore

/// The few values the menus depend on. `update` assigns only when a value changes,
/// because `@Published` notifies on every assignment, even an equal one.
@MainActor
final class CommandState: ObservableObject {
    @Published private(set) var flags = CommandFlags()

    func update(from items: [QueueItem], isRunning: Bool, hasLiveTask: Bool, selection: Set<UUID>) {
        let next = CommandFlags.from(items, isRunning: isRunning, hasLiveTask: hasLiveTask, selection: selection)
        if next != flags {
            flags = next
        }
    }
}

/// Where .srt files go. The Save to bar and Settings both read and write this.
struct OutputChoice: Equatable {
    var placement: String
    var folderPath: String
    var recents: [RecentFolderRecord]

    static func load(_ defaults: UserDefaults = .standard) -> OutputChoice {
        let placement = defaults.string(forKey: SettingsKey.placement) ?? SettingsKey.placementNextToSource
        let folder = defaults.string(forKey: SettingsKey.folder) ?? ""
        var recents = RecentFolderList.load(defaults)
        if recents.isEmpty, !folder.isEmpty, AppModel.directoryExists(folder) {
            recents = RecentFolderList.remembering(folder, bookmark: nil, in: [])
        }
        return OutputChoice(placement: placement, folderPath: folder, recents: recents)
    }
}

/// Owns the queue, the open panel, and the debug log. The window watches this object.
/// The real work (the engine) belongs in the MP4SubRipCore package so it can be tested
/// with `swift test` on Linux; this class only feeds it and shows its progress.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var items: [QueueItem] = []
    @Published private(set) var banners: [String] = []
    @Published private(set) var outputChoice = OutputChoice.load(UITestingLaunch.defaults)
    let commands = CommandState()
    /// `commands` is not `@Published`. Forward its changes so the toolbar redraws
    /// when only the flags change, such as Extract enabling after Stop's cleanup.
    private var commandForwarding: AnyCancellable?
    static weak var shared: AppModel?
    private let defaults: UserDefaults

    private var throttles: [UUID: ProgressThrottle] = [:]
    /// Extraction tasks only. Probe tasks stay in `probeTasks` so a probe does not
    /// keep Extract disabled the way a cancelled file's cleanup does (#39).
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var probeTasks: [UUID: Task<Void, Never>] = [:]
    private var probeQueue: [UUID] = []
    private var probesInFlight = 0
    private let probeLimit = 3
    /// True after Extract Subtitles until Stop, or until no Pending row is left.
    private var accepting = false
    /// Cancelled during this run. They stay Pending and wait for the next Extract.
    private var held: Set<UUID> = []
    private var selection: Set<UUID> = []
    private var scopedOutput: URL?
    @Published private(set) var highlightedIDs: Set<UUID> = []
    private var highlightGeneration: [UUID: Int] = [:]
    private var highlightSerial = 0

    init(defaults: UserDefaults = UITestingLaunch.defaults) {
        self.defaults = defaults
        UITestingLaunch.prepare()
        // Save to reads `outputChoice`, so the UI-test folder has to land in
        // defaults before that value is loaded. Input is imported at the end.
        applyUITestingOutputFolder()
        let storedRecents = RecentFolderList.load(defaults)
        outputChoice = OutputChoice.load(defaults)
        commandForwarding = commands.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        DebugLog.shared.configure(directory: DebugLog.libraryLogsDirectory, mirror: { AppLog.write($0) })
        if outputChoice.recents != storedRecents {
            persistOutputChoice()
        }
        logLaunch()
        AppModel.shared = self
        refreshSavedFolders()
        let pending = AppDelegate.setDeliver { urls in
            let urls = urls
            Task { @MainActor in
                AppModel.shared?.importURLs(urls)
            }
        }
        if !pending.isEmpty {
            importURLs(pending)
        }
        if AppDelegate.isFinishedLaunching {
            logInstalledTools()
        }
        applyUITestingLaunch()
    }

    /// `--uitesting` only. Writes `UITEST_OUTPUT_DIR` as the chosen output folder.
    private func applyUITestingOutputFolder() {
        if let output = UITestingLaunch.outputDirectory() {
            defaults.set(SettingsKey.placementFolder, forKey: SettingsKey.placement)
            defaults.set(output.path, forKey: SettingsKey.folder)
        }
    }

    /// `--uitesting` only. Apply `UITEST_OUTPUT_DIR` as the chosen output
    /// folder and `UITEST_INPUT_DIR` as if it had been opened or dropped.
    /// Extraction does not start until Extract Subtitles.
    private func applyUITestingLaunch() {
        applyUITestingOutputFolder()
        if let input = UITestingLaunch.inputDirectory() {
            importURLs([input])
        }
    }

    var saveToTitle: String {
        if outputChoice.placement != SettingsKey.placementFolder {
            return "Same Folder as Input Files"
        }
        if outputChoice.folderPath.isEmpty { return "No folder chosen" }
        return DisplayPath.abbreviated(outputChoice.folderPath, home: NSHomeDirectory())
    }

    var queueSummary: String {
        QueueSummaryLine.text(files: items.count, textTracks: QueueSummaryLine.textTrackCount(in: items))
    }

    // MARK: Adding files

    /// Drops on the window, Add Files, the Dock icon, and Finder's Open With all end up here.
    /// Nothing starts until Extract Subtitles. The folder walk and the probe stay off the main thread.
    func importURLs(_ urls: [URL]) {
        let paths = urls.map(\.path)
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                FileIntake.collect(paths: paths, listing: .live)
            }.value
            self.receiveIntake(result, dropped: paths.count)
        }
    }

    private func receiveIntake(_ result: IntakeResult, dropped: Int) {
        let existingIDs = Set(items.map(\.id))
        let addition = QueueList.adding(result.sourcePaths, to: items)
        let marked = QueueList.markingNewRowsForProbe(addition.items, existingIDs: existingIDs)
        items = marked.items
        for notice in result.notices {
            banners.append(notice.message)
            DebugLog.shared.record(.queue, "Notice: \(notice.message)", isWarning: true)
        }
        DebugLog.shared.record(.queue, "Added \(addition.addedCount) of \(dropped) dropped or opened items")
        if !addition.duplicateIDs.isEmpty {
            DebugLog.shared.record(.queue, "Highlighted \(addition.duplicateIDs.count) already in the queue")
            highlight(addition.duplicateIDs)
        }
        publishCommands()
        scheduleProbes(marked.probeIDs)
    }

    /// Briefly marks rows that were already in the queue. Adding them again does not start work.
    private func highlight(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        highlightSerial += 1
        let generation = highlightSerial
        var shown = highlightedIDs
        for id in ids {
            highlightGeneration[id] = generation
            shown.insert(id)
        }
        highlightedIDs = shown
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            var next = self.highlightedIDs
            var changed = false
            for id in ids where self.highlightGeneration[id] == generation {
                self.highlightGeneration[id] = nil
                if next.remove(id) != nil { changed = true }
            }
            if changed { self.highlightedIDs = next }
        }
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

    // MARK: Probe

    private func scheduleProbes(_ ids: [UUID]) {
        probeQueue.append(contentsOf: ids)
        pumpProbes()
    }

    /// A few probes at a time, so a folder on a slow disk does not open dozens of files at once.
    private func pumpProbes() {
        while probesInFlight < probeLimit, !probeQueue.isEmpty {
            let id = probeQueue.removeFirst()
            guard let item = items.first(where: { $0.id == id }), item.status == .probing else { continue }
            probesInFlight += 1
            let path = item.path
            let task = Task.detached { [path] in
                let result = await Self.probe(path: path)
                await MainActor.run {
                    AppModel.shared?.finishProbe(id: id, result: result)
                }
            }
            probeTasks[id] = task
        }
    }

    private nonisolated static func probe(path: String) async -> ProbeFinish {
        do {
            try Task.checkCancellation()
            let tracks = try await SubtitleEngine().probe(file: URL(fileURLWithPath: path))
            try Task.checkCancellation()
            return .tracks(tracks)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(Self.message(for: error, fallback: "Could not read this file."))
        }
    }

    private func finishProbe(id: UUID, result: ProbeFinish) {
        probeTasks[id] = nil
        if probesInFlight > 0 { probesInFlight -= 1 }
        defer {
            pumpProbes()
            if accepting { startNextIfIdle() }
        }
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .probing else { return }
        switch result {
        case .cancelled:
            report(.waiting, for: id)
        case let .failed(reason):
            report(.failed(reason: reason), for: id)
        case let .tracks(tracks):
            items[index].tracks = tracks
            switch ProbeRules.settle(tracks) {
            case .waiting:
                items[index].statusNote = nil
                report(.waiting, for: id)
            case let .noSubtitles(note):
                items[index].statusNote = note
                report(.noSubtitles, for: id)
            case .imageSubsOnly:
                items[index].statusNote = nil
                report(.imageSubsOnly, for: id)
            }
        }
    }

    // MARK: Extraction

    /// Runs Pending rows, one at a time. Finished rows are left as they are.
    /// Adding files does not call this.
    func extractSubtitles() {
        guard !accepting, tasks.isEmpty else { return }
        guard items.contains(where: { $0.status == .waiting }) else { return }
        held = []
        accepting = true
        beginOutputScope()
        DebugLog.shared.record(.queue, "Extract Subtitles")
        startNextIfIdle()
    }

    /// Stops the run. The file that is extracting is cancelled, its partial SRT
    /// is deleted by the engine, and that row goes back to Pending.
    func stopExtraction() {
        accepting = false
        let live = tasks
        for id in live.keys {
            held.insert(id)
            live[id]?.cancel()
        }
        for item in items where item.status.isWorking {
            DebugLog.shared.record(.work, "Canceled \(item.fileName)")
        }
        items = QueueRunRules.stopped(items)
        DebugLog.shared.record(.queue, "Stop")
        publishCommands()
    }

    /// Starts the next Pending row when a run is in progress and nothing is extracting.
    private func startNextIfIdle() {
        guard accepting, tasks.isEmpty else {
            if !accepting && tasks.isEmpty { endOutputScope() }
            publishCommands()
            return
        }
        while let id = QueueRunRules.nextPending(in: items, held: held),
              let next = items.first(where: { $0.id == id }) {
            if beginExtraction(next) { return }
        }
        accepting = false
        held = []
        endOutputScope()
        publishCommands()
    }

    private func publishCommands() {
        commands.update(from: items, isRunning: accepting, hasLiveTask: !tasks.isEmpty, selection: selection)
    }

    /// False means this row was not started, so the caller should try the next one.
    private func beginExtraction(_ item: QueueItem) -> Bool {
        guard item.status == .waiting else { return false }
        let request = extractionRequest()
        if request.missingFolder {
            report(.failed(reason: "Choose an output folder in Settings."), for: item.id)
            return false
        }
        let id = item.id
        let path = item.path
        report(.working(completed: 0, total: 0), for: id)
        let task = Task.detached {
            let finish = await Self.runExtraction(id: id, path: path, request: request)
            await MainActor.run {
                AppModel.shared?.complete(id: id, finish: finish)
            }
        }
        tasks[id] = task
        return true
    }

    private nonisolated static func runExtraction(id: UUID, path: String, request: ExtractionRequest) async -> ExtractionFinish {
        do {
            let outcome = try await SubtitleEngine().extract(
                file: URL(fileURLWithPath: path),
                outputDirectory: request.directory,
                conflict: request.conflict,
                progress: { completed, total in
                    Task { @MainActor in
                        guard let model = AppModel.shared,
                              model.accepting,
                              !model.held.contains(id),
                              model.tasks[id] != nil,
                              let current = model.items.first(where: { $0.id == id }),
                              current.status.isWorking else { return }
                        model.report(.working(completed: completed, total: total), for: id)
                    }
                }
            )
            return .success(outcome)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(Self.message(for: error, fallback: "Could not extract subtitles."))
        }
    }

    private func complete(id: UUID, finish: ExtractionFinish) {
        tasks[id] = nil
        let wasHeld = held.contains(id)
        defer { startNextIfIdle() }
        if wasHeld {
            // Stop or Cancel already sent this row back to Pending. If the file
            // finished writing before the cancel landed, keep that result.
            if case let .success(outcome) = finish {
                held.remove(id)
                apply(outcome, to: id)
            }
            return
        }
        guard let item = items.first(where: { $0.id == id }), item.status.isActive else { return }
        switch finish {
        case .cancelled:
            held.insert(id)
            items = QueueRunRules.cancelled(items, id: id)
            publishCommands()
        case let .failed(message):
            report(.failed(reason: message), for: id)
        case let .success(outcome):
            apply(outcome, to: id)
        }
    }

    private func apply(_ outcome: ExtractionOutcome, to id: UUID) {
        if outcome.written.count > 1 {
            let names = outcome.written.map { URL(fileURLWithPath: $0.path).lastPathComponent }
            DebugLog.shared.record(.work, "Saved \(names.joined(separator: ", "))")
        }
        report(QueueOutcome.status(for: outcome), for: id)
    }

    private func extractionRequest() -> ExtractionRequest {
        let existing = defaults.string(forKey: SettingsKey.existingFile) ?? ExistingFileChoice.skip.rawValue
        let conflict: OutputConflictPolicy
        switch existing {
        case ExistingFileChoice.overwrite.rawValue:
            conflict = .overwrite
        case ExistingFileChoice.addNumber.rawValue:
            conflict = .keepBoth
        default:
            conflict = .skip
        }
        guard outputChoice.placement == SettingsKey.placementFolder else {
            return ExtractionRequest(directory: nil, conflict: conflict, missingFolder: false)
        }
        if outputChoice.folderPath.isEmpty {
            return ExtractionRequest(directory: nil, conflict: conflict, missingFolder: true)
        }
        return ExtractionRequest(directory: outputDirectory(), conflict: conflict, missingFolder: false)
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
        publishCommands()
    }

    private func logStatus(_ status: JobStatus, for item: QueueItem) {
        switch status {
        case .waiting, .probing:
            break
        case .working:
            DebugLog.shared.record(.work, "Started \(item.fileName)")
        case let .done(written, skipped):
            let names = (written + skipped).map { URL(fileURLWithPath: $0).lastPathComponent }
            DebugLog.shared.record(.work, "Finished \(item.fileName) -> \(names.joined(separator: ", "))")
        case let .skippedExists(paths):
            let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
            DebugLog.shared.record(.work, "Finished \(item.fileName) -> \(names.joined(separator: ", ")) (already exists)")
        case .noSubtitles:
            DebugLog.shared.record(.work, "No subtitles \(item.fileName)", isWarning: true)
        case .imageSubsOnly:
            DebugLog.shared.record(.work, "Image subs only \(item.fileName)", isWarning: true)
        case let .failed(reason):
            DebugLog.shared.record(.work, "Failed \(item.fileName): \(reason)", isError: true)
        case let .skipped(reason):
            DebugLog.shared.record(.work, "Skipped \(item.fileName): \(reason)", isWarning: true)
        case .canceled:
            DebugLog.shared.record(.work, "Canceled \(item.fileName)")
        }
    }

    // MARK: Queue actions

    func setSelection(_ ids: Set<UUID>) {
        let existing = Set(items.map(\.id))
        let next = ids.intersection(existing)
        guard next != selection else { return }
        selection = next
        publishCommands()
    }

    func cancel(id: UUID) {
        // The engine checks cancellation while it reads and deletes a half-written SRT.
        // The row goes back to Pending. This run will not pick it up again; the next
        // Extract will. `complete` leaves a held row alone unless the file fully finished.
        let hadTask = tasks[id] != nil
        tasks[id]?.cancel()
        held.insert(id)
        guard let item = items.first(where: { $0.id == id }), item.status.isActive else { return }
        DebugLog.shared.record(.work, "Canceled \(item.fileName)")
        items = QueueRunRules.cancelled(items, id: id)
        publishCommands()
        if accepting && !hadTask {
            startNextIfIdle()
        }
    }

    func cancelAll() {
        stopExtraction()
    }

    func removeSelection() {
        remove(ids: selection)
    }

    /// Removes the rows only. Output files on disk are never touched.
    func remove(ids: Set<UUID>) {
        let victims = items.filter { ids.contains($0.id) && $0.status.canRemove }
        guard !victims.isEmpty else { return }
        let victimIDs = Set(victims.map(\.id))
        for id in victimIDs {
            probeQueue.removeAll { $0 == id }
            probeTasks[id]?.cancel()
            probeTasks[id] = nil
            held.remove(id)
        }
        items = QueueHousekeeping.removing(items, ids: victimIDs)
        selection.subtract(victimIDs)
        DebugLog.shared.record(.queue, "Removed \(victims.count) from the queue")
        publishCommands()
        if accepting && tasks.isEmpty {
            startNextIfIdle()
        }
    }

    /// No confirmation. An empty list goes back to the drop screen.
    /// Failed rows stay unless `includingFailed` is set. Disabled while a run is going.
    func clearProcessed(includingFailed: Bool) {
        guard !accepting else { return }
        let before = items.count
        items = QueueHousekeeping.clearing(items, includingFailed: includingFailed)
        let removed = before - items.count
        guard removed > 0 else {
            publishCommands()
            return
        }
        let kept = Set(items.map(\.id))
        selection = selection.intersection(kept)
        let line = includingFailed ? "Cleared all finished (\(removed))" : "Cleared processed (\(removed))"
        DebugLog.shared.record(.queue, line)
        publishCommands()
    }

    /// Failed rows go back to Pending. If nothing is running, that row starts now.
    /// During a run it waits its turn with the other Pending rows.
    func retry(ids: Set<UUID>) {
        let targets = items.filter { ids.contains($0.id) && $0.status.canRetry }
        guard !targets.isEmpty else { return }
        items = QueueHousekeeping.retrying(items, ids: ids)
        for item in targets {
            held.remove(item.id)
            DebugLog.shared.record(.queue, "Retry \(item.fileName)")
        }
        if accepting {
            publishCommands()
            startNextIfIdle()
            return
        }
        guard tasks.isEmpty, let first = items.first(where: { ids.contains($0.id) && $0.status == .waiting }) else {
            publishCommands()
            return
        }
        held = []
        accepting = true
        beginOutputScope()
        DebugLog.shared.record(.queue, "Extract Subtitles")
        if !beginExtraction(first) {
            startNextIfIdle()
        }
    }

    func retrySelection() {
        retry(ids: selection)
    }

    func dismissBanner(at index: Int) {
        guard banners.indices.contains(index) else { return }
        banners.remove(at: index)
    }

    // MARK: Finder

    func revealSelection() { reveal(ids: selection) }
    func showVideoSelection() { showVideo(ids: selection) }
    func openSubtitleSelection() { openSubtitle(ids: selection) }
    func showErrorSelection() { showError(ids: selection) }

    func reveal(ids: Set<UUID>) {
        let paths = items.filter { ids.contains($0.id) }.flatMap { $0.status.outputPaths }
        present(paths: paths, retryIDs: ids, reveal: true, logAction: "Reveal in Finder", groupName: "The subtitle files")
    }

    func openSubtitle(ids: Set<UUID>) {
        let paths = items.filter { ids.contains($0.id) }.flatMap { $0.status.outputPaths }
        present(paths: paths, retryIDs: ids, reveal: false, logAction: "Open Subtitle", groupName: "The subtitle files")
    }

    func showVideo(ids: Set<UUID>) {
        let paths = items.filter { ids.contains($0.id) }.map(\.path)
        present(paths: paths, retryIDs: [], reveal: true, logAction: "Show Video in Finder", groupName: "Those videos")
    }

    /// Shows the engine's full failure text. The row already shows a shortened line.
    func showError(ids: Set<UUID>) {
        let failed = items.filter { ids.contains($0.id) && $0.status.offersErrorDetail }
        guard failed.count == 1, let item = failed.first else { return }
        guard let detail = item.status.detail else { return }
        DebugLog.shared.record(.lifecycle, "Show Error \(item.fileName)")
        let alert = NSAlert()
        alert.messageText = item.fileName
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Checks that the file is still there first (PGS2SRT #9), and logs the call (#33).
    /// A missing file does not open Finder on an empty selection.
    private func present(
        paths: [String],
        retryIDs: Set<UUID>,
        reveal: Bool,
        logAction: String,
        groupName: String
    ) {
        let action = RevealRules.plan(
            paths: paths,
            fileExists: Self.regularFileExists,
            directoryExists: Self.directoryExists,
            missingGroupName: groupName
        )
        switch action {
        case .nothing:
            return
        case let .select(found):
            let urls = found.map { URL(fileURLWithPath: $0) }
            DebugLog.shared.record(.lifecycle, "\(logAction) \(found.joined(separator: ", "))")
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            } else {
                NSWorkspace.shared.open(urls)
            }
        case let .missing(name, folder, folderExists):
            DebugLog.shared.record(.lifecycle, "\(logAction): file missing \(name)", isWarning: true)
            explainMissing(name: name, folder: folder, folderExists: folderExists, retryIDs: retryIDs)
        }
    }

    private func explainMissing(name: String, folder: String, folderExists: Bool, retryIDs: Set<UUID>) {
        let alert = NSAlert()
        alert.messageText = "\(name) can't be found."
        alert.informativeText = "It may have been moved, renamed, or deleted."
        if folderExists {
            alert.addButton(withTitle: "Show Folder")
        }
        if !retryIDs.isEmpty {
            alert.addButton(withTitle: "Convert Again")
        }
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        if folderExists && response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true))
            return
        }
        let convert: NSApplication.ModalResponse = folderExists ? .alertSecondButtonReturn : .alertFirstButtonReturn
        if !retryIDs.isEmpty && response == convert {
            retry(ids: retryIDs)
        }
    }

    // MARK: Save to

    func setOutputPlacement(_ placement: String) {
        guard !accepting else { return }
        guard placement == SettingsKey.placementNextToSource || placement == SettingsKey.placementFolder else { return }
        guard placement != outputChoice.placement else { return }
        outputChoice.placement = placement
        persistOutputChoice()
        logSettings()
    }

    func selectRecentFolder(_ path: String) {
        guard !accepting else { return }
        let bookmark = outputChoice.recents.first { $0.path == RecentFolderList.normalize(path) }?.bookmark
        outputChoice.placement = SettingsKey.placementFolder
        outputChoice.folderPath = RecentFolderList.normalize(path)
        outputChoice.recents = RecentFolderList.remembering(path, bookmark: bookmark, in: outputChoice.recents)
        persistOutputChoice()
        logSettings()
    }

    func chooseOutputFolder() {
        guard !accepting else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for the .srt files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = Self.bookmarkData(for: url)
        outputChoice.placement = SettingsKey.placementFolder
        outputChoice.folderPath = RecentFolderList.normalize(url.path)
        outputChoice.recents = RecentFolderList.remembering(url.path, bookmark: bookmark, in: outputChoice.recents)
        persistOutputChoice()
        logSettings()
    }

    private func persistOutputChoice() {
        defaults.set(outputChoice.placement, forKey: SettingsKey.placement)
        defaults.set(outputChoice.folderPath, forKey: SettingsKey.folder)
        RecentFolderList.save(outputChoice.recents, to: defaults)
    }

    private func logSettings() {
        DebugLog.shared.record(.lifecycle, "Settings \(SettingsSummary.current())")
    }

    private func refreshSavedFolders() {
        let records = outputChoice.recents
        Task.detached {
            let refreshed = RecentFolderList.refreshing(records) { record in
                AppModel.resolvedFolderPath(record)
            }
            await MainActor.run {
                AppModel.shared?.applyRefreshedRecents(refreshed)
            }
        }
    }

    private func applyRefreshedRecents(_ records: [RecentFolderRecord]) {
        var choice = outputChoice
        if !records.contains(where: { $0.path == choice.folderPath }),
           let old = choice.recents.first(where: { $0.path == choice.folderPath }),
           let moved = records.first(where: { $0.bookmark != nil && $0.bookmark == old.bookmark }) {
            choice.folderPath = moved.path
        }
        choice.recents = records
        guard choice != outputChoice else { return }
        outputChoice = choice
        persistOutputChoice()
    }

    private func outputDirectory() -> URL? {
        guard outputChoice.placement == SettingsKey.placementFolder, !outputChoice.folderPath.isEmpty else { return nil }
        if let data = outputChoice.recents.first(where: { $0.path == outputChoice.folderPath })?.bookmark,
           let url = Self.resolveBookmark(data),
           Self.directoryExists(url.path) {
            return url
        }
        return URL(fileURLWithPath: outputChoice.folderPath, isDirectory: true)
    }

    private func beginOutputScope() {
        endOutputScope()
        guard let url = outputDirectory() else { return }
        if url.startAccessingSecurityScopedResource() {
            scopedOutput = url
        }
    }

    private func endOutputScope() {
        scopedOutput?.stopAccessingSecurityScopedResource()
        scopedOutput = nil
    }

    nonisolated static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private nonisolated static func regularFileExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private nonisolated static func resolvedFolderPath(_ record: RecentFolderRecord) -> String? {
        if directoryExists(record.path) { return record.path }
        guard let data = record.bookmark, let url = resolveBookmark(data), directoryExists(url.path) else {
            return nil
        }
        return url.path
    }

    private nonisolated static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    private nonisolated static func bookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private nonisolated static func message(for error: Error, fallback: String) -> String {
        let message = (error as? LocalizedError)?.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty { return message }
        return fallback
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

    private var didLogTools = false

    /// Launch log. Uses the same `ExternalTool.describe` result shape as the
    /// exported header (`ToolDetection`), and runs only after AppKit has finished
    /// launching. Safe to call from both sides of that race; it records once.
    func logInstalledTools() {
        guard !didLogTools else { return }
        didLogTools = true
        let spec = ExternalToolSpec.primary
        Task.detached(priority: .userInitiated) {
            let report = ExternalTool.describe(spec)
            let line = ToolDetection.logLine(spec: spec, located: report.located, customPath: report.customPath)
            DebugLog.shared.record(.tool, line.message, isError: line.isError)
        }
    }
}

/// Snapshot of the output settings taken when a row starts, so a change mid-file
/// doesn't move the file it's already writing.
private struct ExtractionRequest: Sendable {
    var directory: URL?
    var conflict: OutputConflictPolicy
    var missingFolder: Bool
}

/// The bit of an extraction result that can cross back to the main actor.
/// `Error` itself is not Sendable.
private enum ExtractionFinish: Sendable {
    case success(ExtractionOutcome)
    case cancelled
    case failed(String)
}

private enum ProbeFinish: Sendable {
    case tracks([SubtitleTrack])
    case cancelled
    case failed(String)
}
