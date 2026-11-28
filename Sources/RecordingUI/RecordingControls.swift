import AppKit
import RecordingEngine
import SwiftUI

/// What the floating recording controls show.
@MainActor
public final class RecordingControlsModel: ObservableObject {
    @Published public var elapsed = 0.0
    @Published public var bytes: Int64 = 0
    @Published public var isPaused = false
    @Published public var isFinishing = false
    @Published public var hasMicrophone = false
    @Published public var isMicrophoneMuted = false
    @Published public var microphoneLevel: Float = 0
    @Published public var droppedFrames = 0
    @Published var confirmingDiscard = false
    @Published var confirmingRestart = false
    @Published public var style = ControlsStyle()

    public var onPauseResume: () -> Void = {}
    public var onStop: () -> Void = {}
    public var onDiscard: () -> Void = {}
    public var onRestart: () -> Void = {}
    public var onToggleMicrophone: () -> Void = {}

    public init() {}

    /// Discarding and restarting take two clicks, so a slip cannot lose a recording. (A dialog would end up in the video.)
    func discardPressed() { confirm(\.confirmingDiscard, then: onDiscard) }
    func restartPressed() { confirm(\.confirmingRestart, then: onRestart) }

    /// How long the second click is waited for.
    static let confirmSeconds = 3.0
    private var expiry: Task<Void, Never>?

    private func confirm(_ flag: ReferenceWritableKeyPath<RecordingControlsModel, Bool>, then action: () -> Void) {
        if !style.confirmsDiscard || self[keyPath: flag] {
            self[keyPath: flag] = false
            expiry?.cancel()
            action()
            return
        }
        confirmingDiscard = false                          // only one question at a time
        confirmingRestart = false
        self[keyPath: flag] = true
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.confirmSeconds * 1_000_000_000))
            if !Task.isCancelled { self?[keyPath: flag] = false }
        }
    }

    /// "04:07" or "1:02:33".
    public static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// The floating panel with the timer, Pause, Stop, Restart and Discard. It is left out of the recording.
@MainActor
public final class RecordingControlsPanel {
    private let panel: NSPanel
    private let host: NSHostingView<ControlsView>
    private let model: RecordingControlsModel
    private var area = NSRect.zero
    private var dock: NSRect?
    private var customOrigin: NSPoint?
    private var placing = false
    private var observer: NSObjectProtocol?
    /// Called when the user drags the controls somewhere else.
    public var onDragged: ((NSPoint) -> Void)?

    public init(model: RecordingControlsModel) {
        self.model = model
        host = FirstMouseHostingView(rootView: ControlsView(model: model))
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = host
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.placing, self.panel.isVisible, NSEvent.pressedMouseButtons & 1 == 1 else { return }
                self.customOrigin = self.panel.frame.origin
                self.onDragged?(self.panel.frame.origin)
            }
        }
    }

    public var windowID: CGWindowID { CGWindowID(max(panel.windowNumber, 0)) }
    public var frame: NSRect { panel.frame }

    /// Shows the panel on the screen that holds `area` (Cocoa coordinates), where the model's style says.
    public func show(near area: NSRect, dock: NSRect?, customOrigin: NSPoint?) {
        self.area = area
        self.dock = dock
        self.customOrigin = customOrigin
        place()
        panel.orderFrontRegardless()
    }

    /// Applies a new size, place or opacity. The window stays the same one, so it stays out of the recording.
    public func apply(_ style: ControlsStyle) {
        model.style = style
        place()
        DispatchQueue.main.async { [weak self] in self?.place() }          // once SwiftUI has laid the new size out
    }

    private func place() {
        placing = true
        defer { placing = false }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(area) } ?? NSScreen.main
        let full = screen?.frame ?? area
        let origin = model.style.position.origin(for: size, screen: full, visible: screen?.visibleFrame ?? full, dock: dock, custom: customOrigin)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = CGFloat(min(max(model.style.opacity, 0.3), 1))
    }

    public func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        panel.orderOut(nil)
    }
}

/// Buttons in a panel that is not the active window must work on the first click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct ControlsView: View {
    @ObservedObject var model: RecordingControlsModel

    private var size: ControlsSize { model.style.size }
    private var regular: Bool { size == .regular }
    private var side: CGFloat { regular ? 28 : 24 }
    private var height: CGFloat { regular ? 48 : 36 }

    var body: some View {
        HStack(spacing: regular ? 8 : 5) {
            Circle().fill(model.isPaused ? Color.yellow : Color.red).frame(width: 8, height: 8)
            readout
            if size != .mini, model.hasMicrophone {
                button(model.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill", nil,
                       model.isMicrophoneMuted ? "Unmute the microphone" : "Mute the microphone",
                       tint: model.isMicrophoneMuted ? .orange : nil, action: model.onToggleMicrophone)
                LevelMeter(level: model.microphoneLevel, height: side - 6)
            }
            button(model.isPaused ? "play.fill" : "pause.fill", regular ? (model.isPaused ? "Resume" : "Pause") : nil,
                   model.isPaused ? "Resume recording" : "Pause recording", width: regular ? 86 : nil, action: model.onPauseResume)
            button("stop.fill", regular ? "Stop" : nil, "Stop and review the recording", tint: .red, filled: true, action: model.onStop)
            if size != .mini {
                let twice = model.style.confirmsDiscard ? " (click twice)" : ""
                button("arrow.counterclockwise", nil, model.confirmingRestart ? "Click again to start over" : "Start over" + twice,
                       tint: model.confirmingRestart ? .orange : nil, filled: model.confirmingRestart, hoverColor: .orange,
                       waiting: model.confirmingRestart, effect: .spin, action: model.restartPressed)
                button(model.confirmingDiscard ? "trash.fill" : "trash", nil,
                       model.confirmingDiscard ? "Click again to discard" : "Throw this recording away" + twice,
                       tint: model.confirmingDiscard ? Self.dangerRed : nil, filled: model.confirmingDiscard, hoverColor: Self.dangerRed,
                       waiting: model.confirmingDiscard, effect: .shake, action: model.discardPressed)
            }
        }
        .disabled(model.isFinishing)
        .padding(.horizontal, regular ? 12 : 9)
        .frame(height: height)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: regular ? 13 : 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: regular ? 13 : 11, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }

    /// The time, with the file size (or a problem) under it. A fixed width, so the buttons never move as numbers change.
    private var readout: some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(RecordingControlsModel.clock(model.elapsed)).font(.system(size: regular ? 14 : 12.5, weight: .semibold)).monospacedDigit()
            if let status {
                Text(status).font(.system(size: regular ? 10 : 9, weight: asking ? .bold : .regular)).foregroundStyle(statusColor)
                    .monospacedDigit().lineLimit(1)
            }
        }
        .frame(width: model.elapsed >= 3600 ? 62 : (regular ? 66 : 54), alignment: .leading)
    }

    static let dangerRed = Color(red: 0.93, green: 0.23, blue: 0.22)

    private var status: String? {
        if model.isFinishing { return "Finishing…" }
        if model.confirmingDiscard { return "Discard?" }
        if model.confirmingRestart { return "Restart?" }
        if model.droppedFrames > 0 { return "\(model.droppedFrames) dropped" }
        if size == .mini { return nil }
        if model.isPaused { return "Paused" }
        return model.style.showsFileSize ? FileSizeText.text(model.bytes) : nil
    }

    private var asking: Bool { model.confirmingDiscard || model.confirmingRestart }
    private var statusColor: Color {
        if model.confirmingDiscard { return Self.dangerRed }
        return model.confirmingRestart || model.droppedFrames > 0 ? .orange : .secondary
    }

    private func button(_ symbol: String, _ title: String?, _ help: String, tint: Color? = nil, filled: Bool = false,
                        hoverColor: Color? = nil, width: CGFloat? = nil, waiting: Bool = false, effect: HoverEffect = .none,
                        action: @escaping () -> Void) -> some View {
        HoverButton(symbol: symbol, title: title, help: help, tint: tint, filled: filled, hoverColor: hoverColor, side: side,
                    width: width, waiting: waiting, effect: effect, action: action)
    }
}

private struct LevelMeter: View {
    let level: Float
    let height: CGFloat
    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(Color.primary.opacity(0.15))
            Capsule().fill(level > 0.9 ? Color.orange : Color.green).frame(height: max(2, height * CGFloat(level)))
        }
        .frame(width: 4, height: height)
        .accessibilityLabel("Microphone level")
    }
}

/// What a button's icon does when the pointer arrives on it.
private enum HoverEffect { case none, shake, spin }

/// A button that lights up under the pointer, also while another app is the active one, and sinks when pressed.
private struct HoverButton: View {
    let symbol: String
    let title: String?
    let help: String
    let tint: Color?
    var filled = false
    /// What the button fills with under the pointer: red for Discard, so it is clear before the click what it does.
    var hoverColor: Color?
    let side: CGFloat
    var width: CGFloat?
    /// Waiting for a second click: a bar drains to show how long.
    var waiting = false
    var effect = HoverEffect.none
    let action: () -> Void
    @State private var hovering = false
    @State private var wiggle = 0.0

    private var colored: Bool { filled || (hovering && hoverColor != nil) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).rotationEffect(.degrees(wiggle))
                if let title { Text(title).font(.system(size: 11.5, weight: .semibold)) }
            }
            .foregroundStyle(colored ? Color.white : (tint ?? Color.primary))
            .padding(.horizontal, title == nil ? 0 : 9)
            .frame(width: width ?? (title == nil ? side + 2 : nil), height: side)
            .background(shape.fill(filled ? (tint ?? .accentColor)
                                   : (hovering ? (hoverColor ?? Color.primary.opacity(0.24)) : Color.primary.opacity(0.1))))
            .overlay(alignment: .bottom) { if waiting { DrainingBar() } }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(hovering ? 0.55 : 0.1)))
            .brightness(hovering && filled ? 0.1 : 0)
        }
        .buttonStyle(PressStyle())
        .shadow(color: (hoverColor ?? tint ?? .clear).opacity(hovering || waiting ? 0.6 : 0), radius: 5)
        .scaleEffect(hovering ? 1.08 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: filled)
        .background(HoverTracker { inside in
            hovering = inside
            if inside { play() }
        })
        .help(help).accessibilityLabel(help)
    }

    private func play() {
        switch effect {
        case .none: break
        case .spin:
            withAnimation(.easeInOut(duration: 0.4)) { wiggle -= 360 }
        case .shake:                                     // the lid rattles once
            withAnimation(.easeInOut(duration: 0.07).repeatCount(5, autoreverses: true)) { wiggle = 14 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { withAnimation(.easeOut(duration: 0.08)) { wiggle = 0 } }
        }
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.88 : 1).brightness(configuration.isPressed ? -0.18 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Empties from left to right over the time the second click is waited for.
private struct DrainingBar: View {
    @State private var left: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in Rectangle().fill(Color.white.opacity(0.9)).frame(width: proxy.size.width * left) }
            .frame(height: 3)
            .onAppear { withAnimation(.linear(duration: RecordingControlsModel.confirmSeconds)) { left = 0 } }
    }
}

private struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Sensor { Sensor() }
    func updateNSView(_ view: Sensor, context: Context) { view.onChange = onChange }

    final class Sensor: NSView {
        var onChange: (Bool) -> Void = { _ in }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
    }
}
