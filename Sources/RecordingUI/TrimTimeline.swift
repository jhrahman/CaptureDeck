import AppKit
import SwiftUI

/// One timeline for the whole recording: a strip of its pictures, a handle at each end of the part that will be saved, and
/// the playhead. Drag a handle to trim; click or drag anywhere else to move through the video.
struct TrimTimeline: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var player: ReviewPlayer
    @State private var dragging: TimelineGeometry.Target?
    /// Where inside the handle it was grabbed, so it does not jump to the pointer.
    @State private var grabOffset: CGFloat = 0

    private let height: CGFloat = 52

    var body: some View {
        GeometryReader { proxy in
            let geometry = TimelineGeometry(width: proxy.size.width, duration: model.duration)
            let startX = geometry.x(model.trimStart), endX = geometry.x(model.trimEnd)
            ZStack(alignment: .topLeading) {
                filmstrip
                    .frame(width: max(proxy.size.width - 2 * TimelineGeometry.inset, 1), height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .offset(x: TimelineGeometry.inset)
                // What will be cut away is darkened.
                Rectangle().fill(Color.black.opacity(0.65))
                    .frame(width: max(0, startX - TimelineGeometry.inset), height: height).offset(x: TimelineGeometry.inset)
                Rectangle().fill(Color.black.opacity(0.65))
                    .frame(width: max(0, proxy.size.width - TimelineGeometry.inset - endX), height: height).offset(x: endX)
                Rectangle().strokeBorder(Color.yellow, lineWidth: 2.5)
                    .frame(width: max(endX - startX, 1), height: height).offset(x: startX)
                handle("chevron.compact.left", leading: true).offset(x: startX - 12)
                handle("chevron.compact.right", leading: false).offset(x: endX)
                playhead.offset(x: geometry.x(player.time) - 5, y: -4)
            }
            .frame(width: proxy.size.width, height: height, alignment: .topLeading)      // the whole width can be pressed
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in drag(value, geometry) }
                .onEnded { _ in dragging = nil })
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Trim timeline, \(Timecode.text(model.trimStart)) to \(Timecode.text(model.trimEnd))")
    }

    private func drag(_ value: DragGesture.Value, _ geometry: TimelineGeometry) {
        if dragging == nil {
            let target = geometry.target(at: value.startLocation.x, start: model.trimStart, end: model.trimEnd)
            dragging = target
            grabOffset = target == .start ? value.startLocation.x - geometry.x(model.trimStart)
                : target == .end ? value.startLocation.x - geometry.x(model.trimEnd) : 0
            player.pause()
        }
        let time = geometry.time(value.location.x - grabOffset)
        switch dragging {
        case .start: model.setTrim(start: time); player.seek(model.trimStart)
        case .end: model.setTrim(end: time); player.seek(model.trimEnd)
        default: player.seek(time)
        }
    }

    @ViewBuilder private var filmstrip: some View {
        if model.thumbnails.isEmpty {
            Color.primary.opacity(0.12)
        } else {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: proxy.size.width / CGFloat(model.thumbnails.count), height: proxy.size.height)
                            .clipped()
                    }
                }
            }
        }
    }

    private func handle(_ symbol: String, leading: Bool) -> some View {
        ZStack {
            UnevenEnd(leading: leading).fill(Color.yellow)
            Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
        }
        .frame(width: 12, height: height)
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private var playhead: some View {
        VStack(spacing: 0) {
            Circle().fill(Color.white).frame(width: 10, height: 10)
            Rectangle().fill(Color.white).frame(width: 2, height: height - 2)
        }
        .frame(width: 10)
        .shadow(color: .black.opacity(0.6), radius: 1.5)
        .allowsHitTesting(false)
    }

    /// A rectangle rounded on its outer side only.
    private struct UnevenEnd: Shape {
        let leading: Bool
        func path(in rect: CGRect) -> Path {
            var path = Path(roundedRect: rect, cornerRadius: 5)
            path.addRect(CGRect(x: leading ? rect.midX : rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height))
            return path
        }
    }
}

/// A box for typing a time. Return, or leaving the box, applies it; text that is not a time is put back.
struct TimeField: View {
    let title: String
    let value: Double
    /// Returns the time actually set (it is kept inside the video and apart from the other end).
    let commit: (Double) -> Double
    let note: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("0:00.00", text: $text)
                .textFieldStyle(.roundedBorder).font(.system(size: 12).monospacedDigit()).frame(width: 82)
                .focused($focused)
                .onSubmit(apply)
                .help("Type a time such as 12.5, 1:30 or 1:02:03.25, then press Return")
                .accessibilityLabel("\(title) time")
        }
        .onAppear { text = Timecode.text(value) }
        .onChange(of: value) { text = Timecode.text($0) }
        .onChange(of: focused) { if !$0 { apply() } }
    }

    private func apply() {
        guard text != Timecode.text(value) else { return }
        guard let typed = Timecode.seconds(from: text) else {
            note("“\(text)” is not a time. Use a form like 12.5 or 1:30.")
            NSSound.beep()
            text = Timecode.text(value)
            return
        }
        let result = commit(typed)
        text = Timecode.text(result)
        note(abs(result - typed) > 0.005 ? "\(title) was set to \(Timecode.text(result)), the closest time allowed." : nil)
    }
}
