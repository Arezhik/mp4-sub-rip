import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MP4SubRipCore

/// The single queue window: a drop screen when empty, the queue otherwise.
/// The deployment target is macOS 14, so the queue is a SwiftUI `Table`.
/// Column show/hide is left out; it is optional for 0.7.0.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var targeted = false
    @State private var selection = Set<QueueItem.ID>()
    @State private var sortOrder = [KeyPathComparator<QueueItem>]()
    @State private var optionHeld = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.banners.isEmpty {
                bannerList
            }
            // No rows left, including after Clear Processed or the last remove, is the drop screen.
            if model.items.isEmpty {
                emptyDrop
            } else {
                queueTable
                saveToBar
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onDrop(of: [.fileURL], isTargeted: $targeted, perform: handleDrop)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .toolbar { toolbar }
        .background {
            QueueWindowMarker().allowsHitTesting(false)
            WindowEvents(name: "Queue").allowsHitTesting(false)
            QueueKeyReader(optionHeld: $optionHeld) {
                model.removeSelection()
            }
            .allowsHitTesting(false)
        }
        .onChange(of: selection) {
            let ids = selection
            DispatchQueue.main.async {
                model.setSelection(ids)
            }
        }
    }

    private var tableRows: [QueueItem] {
        sortOrder.isEmpty ? model.items : model.items.sorted(using: sortOrder)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Every toolbar button is also in the menu bar (AppCommands).
        ToolbarItemGroup(placement: .automatic) {
            Button("Add Files") { model.showOpenPanel() }
                .help("Add Files (⌘O)")
            Button(optionHeld ? "Clear All Finished" : "Clear Processed") {
                model.clearProcessed(includingFailed: optionHeld)
            }
            .disabled(optionHeld ? !model.commands.flags.canClearAllFinished : !model.commands.flags.canClearProcessed)
            .help(optionHeld
                  ? "Clear All Finished removes failed rows too (⌥⌘⌫). Files on disk stay."
                  : "Clear Processed (⇧⌘K). Failed rows stay so they can be retried.")
            Button("Cancel All") { model.cancelAll() }
                .disabled(!model.commands.flags.isRunning)
            // macOS 14+: SettingsLink. The old showSettingsWindow: action does nothing (PGS2SRT #7).
            SettingsLink {
                Text("Settings…")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.commands.flags.isRunning {
                Button("Stop") { model.stopExtraction() }
                    .buttonStyle(.borderedProminent)
                    .help("Stop (⌘.)")
            } else {
                Button("Extract Subtitles") { model.extractSubtitles() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.commands.flags.canExtract)
                    .help("Extract Subtitles (⌘↩)")
            }
        }
    }

    private var emptyDrop: some View {
        ContentUnavailableView {
            Label("Drop \(AppIdentity.inputDescription) files here", systemImage: "tray.and.arrow.down")
        } description: {
            Text("Or drop a folder, or choose Add Files (⌘O). Then click Extract Subtitles.")
        } actions: {
            Button("Add Files") { model.showOpenPanel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bannerList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.banners.enumerated()), id: \.offset) { index, banner in
                HStack {
                    Image(systemName: "info.circle")
                    Text(banner)
                        .accessibilityIdentifier("intakeBanner")
                    Spacer()
                    Button("Dismiss") { model.dismissBanner(at: index) }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary)
    }

    private var queueTable: some View {
        Table(tableRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.fileName) { item in
                NameCell(item: item)
            }
            .width(min: 200, ideal: 264)

            TableColumn("Subtitle Tracks") { item in
                TracksCell(item: item)
            }
            .width(min: 120, ideal: 180, max: 280)

            TableColumn("Status") { item in
                StatusCell(item: item, runIsActive: model.commands.flags.isRunning)
            }
            .width(min: 140, ideal: 176, max: 240)

            TableColumn("Output") { item in
                OutputCell(item: item)
            }
            .width(min: 120, ideal: 196, max: 320)

            TableColumn("") { item in
                ActionsCell(item: item)
            }
            .width(min: 56, ideal: 56, max: 56)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: QueueItem.ID.self) { ids in
            QueueSelectionMenu(model: model, ids: ids)
        } primaryAction: { ids in
            model.reveal(ids: ids)
        }
    }

    private var saveToBar: some View {
        ViewThatFits(in: .horizontal) {
            saveToContents(showsSummary: true)
            saveToContents(showsSummary: false)
        }
        .frame(height: 56)
        .padding(.horizontal, 16)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func saveToContents(showsSummary: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Save to:")
                saveToMenu
            }
            .disabled(model.commands.flags.isRunning)
            .help(model.commands.flags.isRunning ? "Output folder can't be changed while extracting." : "Where the .srt files are written")
            if showsSummary {
                Text(model.queueSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var saveToMenu: some View {
        Menu {
            Button {
                model.setOutputPlacement(SettingsKey.placementNextToSource)
            } label: {
                if model.outputChoice.placement != SettingsKey.placementFolder {
                    Label("Same Folder as Input Files", systemImage: "checkmark")
                } else {
                    Text("Same Folder as Input Files")
                }
            }
            if !model.outputChoice.recents.isEmpty {
                Divider()
                Section("Recent Folders") {
                    ForEach(model.outputChoice.recents) { recent in
                        Button {
                            model.selectRecentFolder(recent.path)
                        } label: {
                            RecentFolderLabel(
                                recent: recent,
                                selected: model.outputChoice.placement == SettingsKey.placementFolder
                                    && model.outputChoice.folderPath == recent.path
                            )
                        }
                    }
                }
            }
            Divider()
            Button {
                model.chooseOutputFolder()
            } label: {
                HStack {
                    Text("Choose Folder…")
                    Spacer(minLength: 16)
                    Text("⇧⌘O").foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(model.saveToTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 180, maxWidth: 300, alignment: .leading)
        }
        .menuStyle(.button)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.loadURL(from: provider) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                await MainActor.run {
                    model.importURLs(urls)
                }
            }
        }
        return true
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                once.run {
                    continuation.resume(returning: url(from: item))
                }
            }
        }
    }

    /// Pure path parsing. The drop callback is not on the main actor.
    private nonisolated static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
            if let string = String(data: data, encoding: .utf8) {
                return url(fromPathOrFileURL: string)
            }
        }
        if let string = item as? NSString {
            return url(fromPathOrFileURL: string as String)
        }
        return nil
    }

    private nonisolated static func url(fromPathOrFileURL string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("file:") { return URL(string: trimmed) }
        if trimmed.isEmpty { return nil }
        return URL(fileURLWithPath: trimmed)
    }
}

private struct NameCell: View {
    @EnvironmentObject private var model: AppModel
    let item: QueueItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.fileName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                let parent = DisplayPath.parent(item.path, home: NSHomeDirectory())
                if !parent.isEmpty {
                    Text(parent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .help(item.path)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if model.highlightedIDs.contains(item.id) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.28))
            }
        }
    }
}

private struct TracksCell: View {
    let item: QueueItem

    var body: some View {
        let chips = TrackChips.chips(tracks: item.tracks, languageName: Self.languageName)
        let help = TrackChips.columnHelp(tracks: item.tracks, languageName: Self.languageName)
        Group {
            if item.status == .probing {
                Color.clear.frame(height: 18)
            } else if chips.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            } else {
                chipRow(chips)
            }
        }
        .help(help)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipRow(_ chips: [TrackChipModel]) -> some View {
        ViewThatFits(in: .horizontal) {
            chipsHStack(Array(chips.prefix(chips.count)), extra: 0)
            chipsHStack(Array(chips.prefix(2)), extra: max(0, chips.count - 2))
            chipsHStack(Array(chips.prefix(1)), extra: max(0, chips.count - 1))
            PlusChip(count: chips.count)
        }
    }

    private func chipsHStack(_ chips: [TrackChipModel], extra: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(chips) { chip in
                TrackChipView(chip: chip)
            }
            if extra > 0 {
                PlusChip(count: extra)
            }
        }
    }

    private static func languageName(_ code: String) -> String? {
        Locale.current.localizedString(forLanguageCode: code)
    }
}

private struct TrackChipView: View {
    let chip: TrackChipModel

    var body: some View {
        HStack(spacing: 3) {
            if let symbol = chip.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10))
            }
            Text(chip.title)
            if let mark = chip.mark {
                Text("· \(mark)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background {
            if chip.style == .bitmap {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(0.35))
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary)
            }
        }
    }
}

private struct PlusChip: View {
    let count: Int

    var body: some View {
        Text("+\(count)")
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary)
            }
    }
}

private struct StatusCell: View {
    let item: QueueItem
    let runIsActive: Bool

    var body: some View {
        let text = QueueRowText.summary(item.status, runIsActive: runIsActive)
        let help = QueueRowText.help(for: item, languageName: Self.languageName) ?? ""
        HStack(spacing: 6) {
            statusIcon
            statusLabel(text)
        }
        .help(help)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .working:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skippedExists:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
        case .noSubtitles:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .imageSubsOnly:
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .probing, .waiting, .canceled, .skipped:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusLabel(_ text: String) -> some View {
        switch item.status {
        case .working:
            HStack(spacing: 6) {
                if let percent = item.status.progressPercent {
                    ProgressView(value: Double(percent), total: 100)
                        .frame(maxWidth: 72)
                    Text("\(percent)%")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Extracting")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .done:
            Text(text)
                .font(.callout)
                .foregroundStyle(.green)
                .lineLimit(1)
        case .skippedExists:
            Text(text)
                .font(.callout)
                .lineLimit(1)
        case .failed:
            Text(text)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(1)
        default:
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private static func languageName(_ code: String) -> String? {
        Locale.current.localizedString(forLanguageCode: code)
    }
}

private struct OutputCell: View {
    let item: QueueItem

    var body: some View {
        switch OutputColumnBuilder.make(for: item) {
        case .dash:
            Text("—")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .needsOCR:
            Text(OutputColumnBuilder.needsOCRText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .files(first, extra, help):
            HStack(spacing: 4) {
                Text(first)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if extra > 0 {
                    PlusChip(count: extra)
                }
            }
            .help(help)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ActionsCell: View {
    @EnvironmentObject private var model: AppModel
    let item: QueueItem

    var body: some View {
        HStack(spacing: 2) {
            if !item.status.outputPaths.isEmpty {
                IconAction(systemName: "magnifyingglass", help: "Reveal in Finder", label: "Reveal \(item.fileName) in Finder") {
                    model.reveal(ids: [item.id])
                }
            }
            if item.status.canRetry {
                IconAction(systemName: "arrow.clockwise", help: "Retry", label: "Retry \(item.fileName)") {
                    model.retry(ids: [item.id])
                }
            }
            if item.status.canRemove {
                IconAction(systemName: "xmark", help: "Remove from the list. The file on disk is not touched.", label: "Remove \(item.fileName) from the list") {
                    model.remove(ids: [item.id])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct IconAction: View {
    let systemName: String
    let help: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
    }
}

private struct RecentFolderLabel: View {
    let recent: RecentFolderRecord
    let selected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: selected ? "checkmark" : "folder")
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(DisplayPath.folderName(recent.path))
                Text(DisplayPath.abbreviated(recent.path, home: NSHomeDirectory()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct QueueSelectionMenu: View {
    let model: AppModel
    let ids: Set<QueueItem.ID>

    var body: some View {
        let actions = RowActionSet.forSelection(model.items, ids: ids)
        if actions.retry {
            Button("Retry") { model.retry(ids: ids) }
        }
        if actions.showError {
            Button("Show Error…") { model.showError(ids: ids) }
        }
        if (actions.retry || actions.showError) && (actions.reveal || actions.showVideo || actions.openSubtitle || actions.remove) {
            Divider()
        }
        if actions.reveal {
            Button("Reveal Output in Finder") { model.reveal(ids: ids) }
        }
        if actions.showVideo {
            Button("Show Video in Finder") { model.showVideo(ids: ids) }
        }
        if actions.openSubtitle {
            Button("Open Subtitle") { model.openSubtitle(ids: ids) }
        }
        if actions.remove && (actions.reveal || actions.showVideo || actions.openSubtitle || actions.retry || actions.showError) {
            Divider()
        }
        if actions.remove {
            Button("Remove from Queue") { model.remove(ids: ids) }
        }
    }
}

/// Option swaps Clear Processed to Clear All Finished. Delete removes the selection
/// when this window is key and a text field is not editing.
private struct QueueKeyReader: NSViewRepresentable {
    @Binding var optionHeld: Bool
    var onRemove: () -> Void

    func makeNSView(context: Context) -> QueueKeyView {
        let view = QueueKeyView()
        view.onOption = { held in
            if optionHeld != held { optionHeld = held }
        }
        view.onRemove = onRemove
        return view
    }

    func updateNSView(_ nsView: QueueKeyView, context: Context) {
        nsView.onOption = { held in
            if optionHeld != held { optionHeld = held }
        }
        nsView.onRemove = onRemove
    }
}

private final class QueueKeyView: NSView {
    var onOption: (Bool) -> Void = { _ in }
    var onRemove: () -> Void = {}
    private var flagsMonitor: Any?
    private var keyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard flagsMonitor == nil, window != nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.contains(.option)
            DispatchQueue.main.async { self?.onOption(held) }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window?.identifier == QueueWindow.marker else { return event }
            if event.window?.firstResponder is NSTextView { return event }
            let blocked: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            guard event.modifierFlags.intersection(blocked).isEmpty else { return event }
            // Delete (51) and Forward Delete (117).
            guard event.keyCode == 51 || event.keyCode == 117 else { return event }
            DispatchQueue.main.async { self.onRemove() }
            return nil
        }
        let held = NSEvent.modifierFlags.contains(.option)
        DispatchQueue.main.async { [weak self] in self?.onOption(held) }
    }

    deinit {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

/// Tags the queue window so a Dock or Open With drop can tell it from Settings.
private struct QueueWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        QueueWindowClaim()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? QueueWindowClaim)?.claim()
    }
}

private final class QueueWindowClaim: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claim()
    }

    func claim() {
        window?.identifier = QueueWindow.marker
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !done
        done = true
        lock.unlock()
        if shouldRun { body() }
    }
}
