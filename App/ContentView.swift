import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MP4SubRipCore

/// The single queue window: a drop screen when empty, the queue otherwise.
/// Drop handling, the window marker, and the Settings button are copied from PGS2SRT.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.banners.isEmpty {
                bannerList
            }
            // No rows left, including after Clear Finished or the last remove, is the drop screen (PGS2SRT #8).
            if model.items.isEmpty {
                emptyDrop
            } else {
                queueList
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
        .toolbar {
            // Every toolbar button is also in the menu bar (AppCommands). Test each one (PGS2SRT #7).
            ToolbarItemGroup {
                Button("Add Files") { model.showOpenPanel() }
                    .help("Add Files (⌘O)")
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
                Button("Cancel All") { model.cancelAll() }
                    .disabled(!model.commands.flags.isRunning)
                Button("Clear Finished") { model.clearFinished() }
                    .disabled(!model.commands.flags.canClearFinished)
                // macOS 14+: SettingsLink. The old showSettingsWindow: action does nothing (PGS2SRT #7).
                SettingsLink {
                    Text("Settings…")
                }
            }
        }
        .background {
            QueueWindowMarker().allowsHitTesting(false)
            WindowEvents(name: "Queue").allowsHitTesting(false)
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

    private var queueList: some View {
        List(model.items) { item in
            QueueRow(item: item)
        }
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

/// One queue row. The ✕ shows only on finished rows, and only on hover (PGS2SRT #8).
/// PGS2SRT later replaced .onHover with an AppKit tracking view, because scrolling
/// moves rows under a still pointer and .onHover misses it. Swap that in if needed.
private struct QueueRow: View {
    @EnvironmentObject private var model: AppModel
    let item: QueueItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                Text((item.path as NSString).deletingLastPathComponent)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                status
            }
            Spacer()
            if item.status.offersErrorDetail {
                Button("Show Error…") { model.showError(item) }
            }
            if case .done = item.status {
                Button("Reveal in Finder") { model.reveal(item) }
            }
            if item.status.isWorking || (item.status == .waiting && model.commands.flags.isRunning) {
                Button("Cancel") { model.cancel(id: item.id) }
            }
            if item.status.isRemovable {
                Button {
                    model.remove(id: item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Remove from the list. The file on disk is not touched.")
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel("Remove \(item.fileName) from the list")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background {
            if model.highlightedIDs.contains(item.id) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.28))
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if item.status.offersErrorDetail {
                Button("Show Error…") { model.showError(item) }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case let .working(completed, total):
            VStack(alignment: .leading, spacing: 2) {
                Text(item.status.summary).font(.callout)
                if total > 0 {
                    ProgressView(value: Double(completed), total: Double(total)) {
                        Text("\(completed)/\(total)").font(.caption).monospacedDigit()
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        case .failed:
            Text(item.status.summary)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(3)
                .help(item.status.detail ?? "")
        case .skipped:
            Text(item.status.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .help(item.status.detail ?? "")
        case .done:
            Text(item.status.summary).font(.callout).foregroundStyle(.green)
        case .waiting, .canceled:
            Text(item.status.summary).font(.callout).foregroundStyle(.secondary)
        }
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
