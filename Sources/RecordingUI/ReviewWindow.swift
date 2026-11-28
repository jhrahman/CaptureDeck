import AVKit
import AppKit
import DesignSystem
import RecordingEngine
import SwiftUI
import UniformTypeIdentifiers

/// The window shown after recording: watch it, trim it, choose a format, see the file size, then save or discard.
@MainActor
public final class ReviewWindowController: NSObject, NSWindowDelegate {
    private let model: ReviewModel
    private let folder: URL
    private let player: ReviewPlayer
    private var window: NSWindow?
    private var keyMonitor: Any?
    private let onClosed: (ReviewWindowController) -> Void
    private let onSaved: (URL, Int64) -> Void

    public init(model: ReviewModel, saveFolder: URL, onSaved: @escaping (URL, Int64) -> Void,
                onClosed: @escaping (ReviewWindowController) -> Void) {
        self.model = model
        folder = saveFolder
        self.onSaved = onSaved
        self.onClosed = onClosed
        player = ReviewPlayer(url: model.master)
        super.init()
    }

    public func show() {
        let view = ReviewView(model: model, player: player, folderName: (folder.path as NSString).abbreviatingWithTildeInPath,
                              save: { [weak self] in self?.saveToFolder() }, saveAs: { [weak self] in self?.saveAs() },
                              discard: { [weak self] in self?.window?.performClose(nil) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Review Recording"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.minSize = NSSize(width: 820, height: 580)
        window.center()
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)                            // so the space bar plays, instead of typing in a box
        model.loadThumbnails()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let pressed = event              // local monitors are called on the main thread
            let used = MainActor.assumeIsolated { self?.handle(pressed) == true }
            return used ? nil : event
        }
    }

    /// Space plays and pauses; I and O set the start and end at the playhead; the arrows step through the video.
    /// Keys typed into a text box are left alone.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil else { return false }
        if let text = window.firstResponder as? NSText { return edit(text, with: event) }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let step = event.modifierFlags.contains(.shift) ? 1.0 : 1.0 / 30
        switch event.keyCode {
        case 49: player.toggle(start: model.trimStart, end: model.trimEnd)
        case 123: player.pause(); player.seek(max(0, player.time - step))
        case 124: player.pause(); player.seek(min(model.duration, player.time + step))
        case 34: model.setTrim(start: player.time)               // I
        case 31: model.setTrim(end: player.time)                 // O
        default: return false
        }
        return true
    }

    /// The app's Edit menu is made for pictures, so the usual text shortcuts are applied to the boxes here.
    private func edit(_ text: NSText, with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]) == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": text.selectAll(nil)
        case "c": text.copy(nil)
        case "v": text.paste(nil)
        case "x": text.cut(nil)
        case "z": if event.modifierFlags.contains(.shift) { text.undoManager?.redo() } else { text.undoManager?.undo() }
        default: return false
        }
        return true
    }

    private func saveToFolder() { finishSaving(to: model.freeDestination(in: folder)) }

    private func saveAs() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = model.freeDestination(in: folder).lastPathComponent
        if let type = UTType(filenameExtension: model.format.fileExtension) { panel.allowedContentTypes = [type] }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.finishSaving(to: url)
        }
    }

    private func finishSaving(to url: URL) {
        guard case .ready(let bytes) = model.size else { return }
        player.unload()                                            // let go of the file before it is moved away
        do {
            try model.save(to: url)
            window?.close()
            onSaved(url, bytes)
        } catch {
            player.reload()
            let alert = NSAlert(error: error)
            alert.messageText = "Could not save the recording"
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.isSaved { return true }
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "It has not been saved. This cannot be undone."
        alert.addButton(withTitle: "Keep")
        let discard = alert.addButton(withTitle: "Discard")
        discard.hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            self.player.unload()
            self.model.discard()
            sender.close()
        }
        return false
    }

    public func windowWillClose(_ notification: Notification) {
        player.pause()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.delegate = nil
        window = nil
        onClosed(self)
    }
}

struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var player: ReviewPlayer
    let folderName: String
    let save: () -> Void
    let saveAs: () -> Void
    let discard: () -> Void
    @State private var trimNote: String?

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(player: player.player).frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("\(RecordingControlsModel.clock(model.duration))  ·  \(model.summary)").font(.system(size: 12)).foregroundStyle(.secondary)
                    if let warning = model.warning { Label(warning, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange) }
                }
                trimSection
                HStack(spacing: 10) {
                    TextField("File name", text: $model.name).textFieldStyle(.roundedBorder)
                    Picker("Format", selection: $model.format) {
                        ForEach(model.formats, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(width: 230)
                }
                HStack(spacing: 10) {
                    sizeLabel
                    Spacer()
                    DiscardButton(action: discard)
                    Button("Save As…", action: saveAs).disabled(!isReady)
                    // Not the Return key's button: Return applies a typed time, and must not save and close the window.
                    Button(saveTitle, action: save).buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                        .disabled(!isReady).help("Save to \(folderName) (⌘S)")
                }
            }
            .padding(14)
        }
        .background(Color(Theme.surface))
    }

    private var isReady: Bool { if case .ready = model.size { return true }; return false }
    private var saveTitle: String { if case .ready(let bytes) = model.size { return "Save (\(FileSizeText.text(bytes)))" }; return "Save" }

    @ViewBuilder private var sizeLabel: some View {
        switch model.size {
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(model.progress.map { "Trimming… \(Int($0 * 100))%" } ?? "Calculating file size…").foregroundStyle(.secondary).monospacedDigit()
            }
        case .ready(let bytes):
            VStack(alignment: .leading, spacing: 1) {
                Text("File size: \(FileSizeText.text(bytes))").font(.system(size: 17, weight: .semibold)).monospacedDigit()
                Text("Will be saved to \(folderName)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
        }
    }

    private var trimSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { player.toggle(start: model.trimStart, end: model.trimEnd) } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18, height: 16)
                }
                .help("Play or pause (Space)").accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.isMuted.toggle() } label: {
                    Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 18, height: 16)
                }
                .help(player.isMuted ? "Unmute the preview" : "Mute the preview").accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
                Text("\(Timecode.text(player.time))  /  \(Timecode.text(model.duration))").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Text("←  →  one frame · Shift for one second").font(.caption).foregroundStyle(.secondary)
            }
            TrimTimeline(model: model, player: player)
            HStack(spacing: 10) {
                TimeField(title: "Start", value: model.trimStart, commit: { model.setTrim(start: $0); player.seek(model.trimStart); return model.trimStart },
                          note: { trimNote = $0 })
                Button("Set at Playhead (I)") { model.setTrim(start: player.time); trimNote = nil }.controlSize(.small)
                Spacer(minLength: 4)
                TimeField(title: "End", value: model.trimEnd, commit: { model.setTrim(end: $0); player.seek(model.trimEnd); return model.trimEnd },
                          note: { trimNote = $0 })
                Button("Set at Playhead (O)") { model.setTrim(end: player.time); trimNote = nil }.controlSize(.small)
                Spacer(minLength: 4)
                Text("Keeping \(Timecode.text(model.trimmedDuration))").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Button("Reset") { model.resetTrim(); trimNote = nil }.controlSize(.small).disabled(!model.isTrimmed)
            }
            // This row is always there, so nothing moves under the pointer when trimming starts.
            HStack(spacing: 8) {
                Toggle("Exact cut: remove the trimmed footage completely", isOn: $model.exactTrim).toggleStyle(.checkbox).font(.system(size: 12))
                    .disabled(!model.isTrimmed || model.format == .gif)
                if let trimNote {
                    Text(trimNote).font(.caption).foregroundStyle(.orange)
                } else if model.format == .gif {
                    Text("A GIF only ever holds the part you keep.").font(.caption).foregroundStyle(.secondary)
                } else if !model.exactTrim {
                    Label("The cut footage stays hidden inside the file and can be recovered.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Re-encodes the part you keep.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(height: 20)
        }
    }
}

/// Turns red under the pointer, so it is clear what it does before it is pressed. (It still asks before deleting.)
struct DiscardButton: View {
    let action: () -> Void
    @State var hovering = false

    var body: some View {
        Button(role: .destructive, action: action) {
            Label("Discard…", systemImage: hovering ? "trash.fill" : "trash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Color.white : ControlsView.dangerRed)
                .padding(.horizontal, 12).frame(height: 24)
        }
        .buttonStyle(Look(hovering: hovering))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Delete this recording without saving it")
    }

    private struct Look: ButtonStyle {
        let hovering: Bool
        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            configuration.label
                .background(shape.fill(hovering ? ControlsView.dangerRed : ControlsView.dangerRed.opacity(0.14)))
                .overlay(shape.strokeBorder(ControlsView.dangerRed.opacity(hovering ? 1 : 0.45)))
                .shadow(color: ControlsView.dangerRed.opacity(hovering ? 0.5 : 0), radius: 5)
                .brightness(configuration.isPressed ? -0.16 : 0)
                .scaleEffect(configuration.isPressed ? 0.95 : (hovering ? 1.04 : 1))
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none                       // the one timeline below does this job
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}
