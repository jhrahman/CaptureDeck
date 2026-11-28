import AppKit
import CaptureEngine
import Combine
import Settings
import SwiftUI

/// The floating capture toolbar. Everything about it (visibility, opacity, button size, which buttons)
/// comes from the Settings store and updates live.
@MainActor
final class CapturePanelController {
    private let panel: NSPanel
    private let host: NSHostingView<CapturePanelView>
    private let modes: [any CaptureMode]
    private let store: SettingsStore
    private let run: (String) -> Void
    private let extras: () -> [PanelExtra]
    private let recordButton: () -> PanelExtra
    private var suspended = false
    private var subscription: AnyCancellable?

    /// `onDropImages` receives image files dropped on the panel.
    init(modes: [any CaptureMode], store: SettingsStore, extras: @escaping () -> [PanelExtra],
         recordButton: @escaping () -> PanelExtra, onDropImages: @escaping ([URL]) -> Void, run: @escaping (String) -> Void) {
        self.modes = modes
        self.store = store
        self.run = run
        self.extras = extras
        self.recordButton = recordButton
        host = NSHostingView(rootView: CapturePanelView(modes: modes, buttonSize: .medium, shortcuts: [:], extras: [], run: run))

        panel = NSPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Wrapped so image files can be dropped on the panel to open them in the editor.
        let drop = PanelDropView(content: host, onDrop: onDropImages)
        panel.contentView = drop
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameAutosaveName("CaptureDeckPanel")
        reload()
        if !panel.setFrameUsingName("CaptureDeckPanel") { placeTopCenter() }

        subscription = store.changes
            .filter { $0.hasPrefix("panel.") || $0.hasPrefix("hotkey.") }
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
    }

    var isVisible: Bool { panel.isVisible }

    /// Rebuilds the buttons and applies opacity and visibility from settings.
    private func reload() {
        var shown = modes.filter { store.bool(SettingID.panelShows($0.id)) }
        if shown.isEmpty { shown = modes }                      // never leave an empty panel
        let size = PanelButtonSize(rawValue: store.string(SettingID.panelButtonSize)) ?? .medium
        var shortcuts: [String: String] = [:]
        for mode in modes { shortcuts[mode.id] = store.shortcut(SettingID.hotkey(mode.id))?.displayString }

        host.rootView = CapturePanelView(modes: shown, buttonSize: size, shortcuts: shortcuts,
                                         extras: (store.bool(SettingID.panelShowsRecord) ? [recordButton()] : []) + extras(), run: run)
        let fitting = host.fittingSize
        if panel.frame.size != fitting {
            // Keep the top-left corner where it is while the size changes.
            let top = panel.frame.maxY
            panel.setContentSize(fitting)
            panel.setFrameTopLeftPoint(CGPoint(x: panel.frame.minX, y: top))
        }
        panel.alphaValue = CGFloat(store.double(SettingID.panelOpacity))
        applyVisibility()
    }

    private func applyVisibility() {
        guard !suspended else { return }
        if store.bool(SettingID.panelVisible) { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    /// The show/hide hotkey and menu item. It flips what you actually see (the panel may be hidden by "start minimized"
    /// while the setting still says "show"), then remembers the choice.
    func toggle() {
        let show = !panel.isVisible
        store.set(show, for: SettingID.panelVisible)
        if show { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    /// At launch the panel follows its "show" setting, unless the app was asked to start minimized in the menu bar.
    func showAtLaunch(minimized: Bool) {
        if minimized { panel.orderOut(nil) } else { applyVisibility() }
    }

    /// Hide while a capture runs so the panel is never part of a screenshot.
    func suspend() async {
        guard panel.isVisible else { return }
        suspended = true
        panel.orderOut(nil)
        try? await Task.sleep(nanoseconds: 150_000_000)   // let the window server remove it
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        applyVisibility()
    }

    private func placeTopCenter() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12))
    }
}

/// Hosts the panel's content and accepts image files dropped on it.
@MainActor
private final class PanelDropView: NSView {
    private let onDrop: ([URL]) -> Void

    init(content: NSView, onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init(frame: content.frame)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func imageURLs(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: ["public.image"]]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { imageURLs(sender).isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }
}
