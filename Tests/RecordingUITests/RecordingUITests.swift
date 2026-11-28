import AVFoundation
import AVKit
import AppKit
import RecordingEngine
import SwiftUI
import Testing
@testable import RecordingUI

struct KeystrokeTextTests {
    private func show(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], _ mode: KeystrokeMode = .shortcuts) -> String? {
        KeystrokeText.describe(keyCode: code, characters: characters, modifiers: flags, mode: mode)
    }

    /// The privacy promise of the default mode: what you type is never put in the video.
    @Test func ordinaryTypingIsNeverShownInShortcutsMode() {
        #expect(show(0, "a") == nil)
        #expect(show(0, "A", .shift) == nil)
        #expect(show(18, "!", .shift) == nil)
        #expect(show(49, " ") == nil)
        #expect(show(51, "\u{7F}") == nil)
    }

    @Test func shortcutsAndSpecialKeysAreShown() {
        #expect(show(8, "c", .command) == "⌘C")
        #expect(show(1, "s", [.command, .shift]) == "⇧⌘S")
        #expect(show(53, "\u{1B}") == "esc")
        #expect(show(36, "\r") == "↩")
        #expect(show(123, "\u{F702}", .command) == "⌘←")
    }

    @Test func everyKeyModeShowsTypingAndOffShowsNothing() {
        #expect(show(0, "a", [], .all) == "a")
        #expect(show(49, " ", [], .all) == "Space")
        #expect(show(8, "c", .command, .off) == nil)
    }
}

/// A short real movie with two audio tracks, made with the engine's writer.
private func makeRecording(seconds: Double = 3) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("capturedeck-ui-\(UUID().uuidString).mov")
    let writer = try MovieWriter(url: url, configuration: RecordingConfiguration(), width: 640, height: 360, audioSources: [])
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    for frame in 0..<Int(seconds * 20) {
        CVPixelBufferLockBaseAddress(buffer!, [])
        memset(CVPixelBufferGetBaseAddress(buffer!)!, Int32(40 + frame % 150), CVPixelBufferGetBytesPerRow(buffer!) * 360)
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        writer.appendVideo(buffer!, at: CMTime(value: CMTimeValue(1000 * 20 + frame), timescale: 20))
        try await Task.sleep(nanoseconds: 12_000_000)
    }
    _ = try await writer.finish(at: CMTime(value: CMTimeValue(1000 * 20 + Int(seconds * 20)), timescale: 20))
    return url
}

@MainActor
@Suite(.serialized)
struct ReviewModelTests {
    private func model(_ master: URL) -> ReviewModel {
        ReviewModel(master: master, duration: 3, summary: "640 × 360 · 60 fps · HEVC", warning: nil, name: "Demo", format: .mp4,
                    formats: [.mp4, .mov, .gif], gifOptions: GIFOptions(frameRate: 8, maximumWidth: 320), mixesAudio: true, audioBitrate: 128_000,
                    workFolder: FileManager.default.temporaryDirectory.appendingPathComponent("capturedeck-ui-work-\(UUID().uuidString)"))
    }

    private func readyBytes(_ model: ReviewModel) async throws -> Int64 {
        await model.waitUntilPrepared()
        guard case .ready(let bytes) = model.size else { throw RecordingError.export("not ready: \(model.size)") }
        return bytes
    }

    /// The promise of the review screen: the size shown is the size of the file that gets saved.
    @Test func theSizeShownIsTheSizeOfTheSavedFile() async throws {
        let master = try await makeRecording()
        let model = model(master)
        let shown = try await readyBytes(model)
        #expect(shown > 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capturedeck-ui-saved-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = model.freeDestination(in: folder)
        #expect(destination.lastPathComponent == "Demo.mp4")
        try model.save(to: destination)
        #expect(FileSizeText.size(of: destination) == shown)
        #expect(model.isSaved && !FileManager.default.fileExists(atPath: master.path))      // temporary files are gone
        #expect(model.freeDestination(in: folder).lastPathComponent == "Demo 2.mp4")        // never overwrites by itself
    }

    @Test func trimmingAndChangingFormatUpdateTheSize() async throws {
        let model = model(try await makeRecording())
        defer { model.discard() }
        let whole = try await readyBytes(model)
        model.setTrim(start: 1, end: 2)
        #expect(model.size == .preparing && abs(model.trimmedDuration - 1) < 0.001)
        #expect(try await readyBytes(model) != whole)
        model.format = .gif
        #expect(model.size == .preparing)
        #expect(try await readyBytes(model) > 0)
    }

    @Test func trimCannotCrossItself() async throws {
        let model = model(try await makeRecording())
        defer { model.discard() }
        model.setTrim(start: 99)
        #expect(model.trimStart == 2.5 && model.trimEnd == 3)
        model.setTrim(end: -5)
        #expect(model.trimEnd == 3)
        model.resetTrim()
        #expect(!model.isTrimmed)
    }

    @Test func exactTrimIsTheDefaultAndCanBeTurnedOff() async throws {
        let model = model(try await makeRecording())
        defer { model.discard() }
        #expect(model.exactTrim)
        model.setTrim(start: 1.3, end: 2.3)
        _ = try await readyBytes(model)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capturedeck-ui-exact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        model.exactTrim = false
        #expect(model.size == .preparing)                                    // the file is made again the other way
        _ = try await readyBytes(model)
        model.exactTrim = true
        let shown = try await readyBytes(model)
        let destination = model.freeDestination(in: folder)
        try model.save(to: destination)
        #expect(FileSizeText.size(of: destination) == shown)
        #expect(abs(try await AVURLAsset(url: destination).load(.duration).seconds - 1) < 0.06)
    }

    @Test func discardingDeletesTheRecording() async throws {
        let master = try await makeRecording(seconds: 1)
        let model = model(master)
        model.discard()
        #expect(!FileManager.default.fileExists(atPath: master.path))
    }

    @Test func theWindowsRender() async throws {
        let master = try await makeRecording()
        let model = model(master)
        defer { model.discard() }
        _ = try await readyBytes(model)
        let player = ReviewPlayer(url: master)
        model.loadThumbnails()
        for _ in 0..<100 where model.thumbnails.count < 14 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(model.thumbnails.count == 14)
        model.setTrim(start: 0.8, end: 2.3)
        _ = try await readyBytes(model)
        player.seek(1.4)
        func review() -> ReviewView { ReviewView(model: model, player: player, folderName: "~/Movies/CaptureDeck", save: {}, saveAs: {}, discard: {}) }
        try snapshot(review(), width: 920, height: 680, name: "review")
        try snapshot(review(), width: 820, height: 580, name: "review-smallest")

        for size in ControlsSize.allCases {
            let controls = RecordingControlsModel()
            controls.hasMicrophone = true
            controls.elapsed = 247
            controls.bytes = 38_400_000
            controls.microphoneLevel = 0.6
            controls.style.size = size
            let fitting = NSHostingView(rootView: ControlsView(model: controls)).fittingSize
            try snapshot(ControlsView(model: controls), width: fitting.width, height: fitting.height, name: "controls-\(size.rawValue)")
            print("CONTROLS \(size.rawValue) \(Int(fitting.width))x\(Int(fitting.height))")
        }
    }

    private func snapshot(_ view: some View, width: CGFloat, height: CGFloat, name: String) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["UX_PNG_DIR"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}

struct ControlsTextTests {
    @MainActor @Test func theClockReadsMinutesThenHours() {
        #expect(RecordingControlsModel.clock(247) == "04:07")
        #expect(RecordingControlsModel.clock(3753) == "1:02:33")
    }
}

struct TimecodeTests {
    @Test func timesAreShownWithHundredths() {
        #expect(Timecode.text(0) == "0:00.00")
        #expect(Timecode.text(65.254) == "1:05.25")
        #expect(Timecode.text(59.999) == "1:00.00")
        #expect(Timecode.text(3723.5) == "1:02:03.50")
    }

    @Test func typedTimesAreRead() {
        #expect(Timecode.seconds(from: "90") == 90)
        #expect(Timecode.seconds(from: " 12.5 ") == 12.5)
        #expect(Timecode.seconds(from: "12,5") == 12.5)
        #expect(Timecode.seconds(from: "1:30.25") == 90.25)
        #expect(Timecode.seconds(from: "1:02:03") == 3723)
        for value in [0.0, 7.31, 125.07, 4000.99] { #expect(abs(Timecode.seconds(from: Timecode.text(value))! - value) < 0.001) }
    }

    @Test func nonsenseIsRefused() {
        for text in ["", "abc", "-3", "1:75", "1:2:3:4", "1.5:00", ":30", "5:", ".", "1e3", "inf"] {
            #expect(Timecode.seconds(from: text) == nil, "\(text)")
        }
    }
}

struct TimelineGeometryTests {
    private let geometry = TimelineGeometry(width: 824, duration: 100)

    @Test func timesAndPositionsMatchAndStayInside() {
        #expect(geometry.x(0) == 12 && geometry.x(100) == 812 && geometry.x(50) == 412)
        #expect(geometry.time(412) == 50)
        #expect(geometry.time(-40) == 0 && geometry.time(5000) == 100)
    }

    @Test func theHandlesAreGrabbedAndEverywhereElseMovesThePlayhead() {
        #expect(geometry.target(at: geometry.x(20) - 8, start: 20, end: 80) == .start)
        #expect(geometry.target(at: geometry.x(80) + 8, start: 20, end: 80) == .end)
        #expect(geometry.target(at: geometry.x(50), start: 20, end: 80) == .playhead)
        #expect(geometry.target(at: geometry.x(5), start: 20, end: 80) == .playhead)
        // Even half a second apart on a long recording, each handle can still be taken from its own side.
        #expect(geometry.target(at: geometry.x(50) - 8, start: 50, end: 50.5) == .start)
        #expect(geometry.target(at: geometry.x(50.5) + 8, start: 50, end: 50.5) == .end)
    }
}

struct ControlsPositionTests {
    private let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private let visible = NSRect(x: 0, y: 80, width: 1920, height: 975)
    private let dock = NSRect(x: 460, y: 6, width: 1000, height: 68)
    private let size = NSSize(width: 250, height: 36)

    @Test func bottomLeftSitsInTheDocksRowBesideIt() {
        let origin = ControlsPosition.bottomLeft.origin(for: size, screen: screen, visible: visible, dock: dock)
        #expect(origin.x == 6 && origin.y == dock.midY - 18)
        #expect(!NSRect(origin: origin, size: size).intersects(dock))
        let right = ControlsPosition.bottomRight.origin(for: size, screen: screen, visible: visible, dock: dock)
        #expect(right.x == 1920 - 256 && !NSRect(origin: right, size: size).intersects(dock))
    }

    @Test func withNoRoomBesideTheDockOrAnUnknownDockItSitsJustAboveIt() {
        let wide = NSRect(x: 150, y: 6, width: 1620, height: 68)
        for known in [wide, nil] {
            let origin = ControlsPosition.bottomLeft.origin(for: size, screen: screen, visible: visible, dock: known)
            #expect(origin == NSPoint(x: 10, y: 90))
        }
        // A Dock on the side is not a row to sit in; the visible area already leaves it out.
        let side = ControlsPosition.bottomLeft.origin(for: size, screen: screen, visible: NSRect(x: 70, y: 0, width: 1850, height: 1055),
                                                      dock: NSRect(x: 4, y: 200, width: 62, height: 700))
        #expect(side == NSPoint(x: 80, y: 10))
    }

    @Test func everyPositionStaysOnTheScreenAndADraggedOneIsKeptThere() {
        for position in ControlsPosition.allCases {
            let origin = position.origin(for: size, screen: screen, visible: visible, dock: dock, custom: NSPoint(x: 5000, y: -300))
            #expect(screen.contains(NSRect(origin: origin, size: size)), "\(position)")
        }
        #expect(ControlsPosition.custom.origin(for: size, screen: screen, visible: visible, dock: dock, custom: NSPoint(x: 700, y: 500)) == NSPoint(x: 700, y: 500))
    }
}

@MainActor
struct PointerHaloTests {
    @Test func theCircleSitsOnThePointerAndCanBeChangedWhileRecording() throws {
        let screen = try #require(NSScreen.screens.first)
        var hidden = NSRect.zero
        let halo = PointerHalo(color: .yellow, diameter: 40, style: .filled)
        let overlay = InputHighlightOverlay(screen: screen, options: HighlightOptions(halo: halo), area: { screen.frame }, ignoring: { hidden })
        defer { overlay.stop() }
        #expect(overlay.haloFrame == nil)                                    // nothing until it starts
        overlay.start()
        let point = NSPoint(x: screen.frame.minX + 300, y: screen.frame.minY + 200)
        overlay.moveHalo(to: point)
        #expect(overlay.haloFrame == CGRect(x: 280, y: 180, width: 40, height: 40))
        hidden = NSRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)     // over our own controls
        overlay.moveHalo(to: point)
        #expect(overlay.haloFrame == .null)
        hidden = .zero
        overlay.update(HighlightOptions(halo: PointerHalo(color: .red, diameter: 80, style: .ring)))
        overlay.moveHalo(to: point)
        #expect(overlay.haloFrame == CGRect(x: 260, y: 160, width: 80, height: 80))
        overlay.update(HighlightOptions())
        #expect(overlay.haloFrame == nil)
    }
}
