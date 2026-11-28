import CaptureEngine
import CoreModels
import DesignSystem
import EditorEngine
import EditorUI
import Foundation
import Platform
import RecordingEngine
import RecordingUI
import Settings

/// Stable setting keys used by the app. (A key is also its UserDefaults key: never rename without a migration.)
enum SettingID {
    static let launchAtLogin = "general.launchAtLogin"
    static let startMinimized = "general.startMinimized"
    static let captureSound = "general.captureSound"
    static let soundName = "general.soundName"

    static let autoCopy = "capture.autoCopy"
    static let openEditor = "capture.openEditor"
    static let autoSave = "capture.autoSave"
    static let includeCursor = "capture.includeCursor"
    static let labelDisplays = "capture.labelDisplays"
    static let closeEditorAfterCopy = "capture.closeEditorAfterCopy"
    static let delaySeconds = "capture.delaySeconds"
    static let textCaptureAction = "capture.text.afterCapture"
    static let scrollSpeed = "capture.scrollSpeed"
    static let magnifier = "capture.magnifier"
    static let magnifierZoom = "capture.magnifierZoom"
    static let dimLevel = "capture.dimLevel"
    static let fixedPresets = "capture.fixedPresets"
    static let fixedSizeLast = "capture.fixedSizePx"      // hidden: remembered between captures

    static let saveFolder = "capture.saveFolder"
    static let fileTemplate = "capture.fileTemplate"
    static let format = "capture.format"
    static let jpegQuality = "capture.jpegQuality"

    static let recSource = "recording.defaultSource"
    static let recCountdown = "recording.countdownSeconds"
    static let recCursor = "recording.showCursor"
    static let recControls = "recording.showControls"
    static let recOutline = "recording.showRegionOutline"
    static let recFrameRate = "recording.frameRate"
    static let recCodec = "recording.codec"
    static let recQuality = "recording.quality"
    static let recSharpColor = "recording.sharpColor"
    static let recResolution = "recording.resolution"
    static let recTiming = "recording.frameTiming"
    static let recSystemAudio = "recording.systemAudio"
    static let recExcludeOwnAudio = "recording.excludeOwnAudio"
    static let recMicrophone = "recording.microphone"
    static let recMicrophoneDevice = "recording.microphoneDevice"
    static let recAudioBitrate = "recording.audioBitrate"
    static let recMixAudio = "recording.mixAudio"
    static let recClicks = "recording.highlightClicks"
    static let recClickColor = "recording.clickColor"
    static let recRightClickColor = "recording.rightClickColor"
    static let recClickSize = "recording.clickSize"
    static let recHalo = "recording.pointerHalo"
    static let recHaloColor = "recording.pointerHaloColor"
    static let recHaloSize = "recording.pointerHaloSize"
    static let recHaloStyle = "recording.pointerHaloStyle"
    static let recControlsPosition = "recording.controlsPosition"
    static let recControlsSize = "recording.controlsSize"
    static let recControlsOpacity = "recording.controlsOpacity"
    static let recControlsFileSize = "recording.controlsShowFileSize"
    static let recControlsOrigin = "recording.controlsOrigin"        // hidden: where the controls were dragged
    static let recMenuBarTime = "recording.menuBarTime"
    static let recMenuBarBlink = "recording.menuBarBlink"
    static let recBlinkStyle = "recording.menuBarBlinkStyle"
    static let recBlinkSpeed = "recording.menuBarBlinkSpeed"
    static let recConfirmDiscard = "recording.confirmDiscard"
    static let recExactTrim = "recording.exactTrim"
    static let recLastRegion = "recording.lastRegion"                // hidden: for "Record Last Region"
    static let recordLastRegionHotkey = "hotkey.record.lastRegion"
    static let recKeystrokes = "recording.keystrokes"
    static let recReview = "recording.showReview"
    static let recFormat = "recording.format"
    static let recFolder = "recording.saveFolder"
    static let recTemplate = "recording.fileTemplate"
    static let recGIFRate = "recording.gifFrameRate"
    static let recGIFWidth = "recording.gifWidth"
    static let recMaxMinutes = "recording.maximumMinutes"

    static let recordHotkey = "hotkey.record.toggle"
    static let recordPauseHotkey = "hotkey.record.pause"
    static func recordSourceHotkey(_ source: String) -> String { "hotkey.record.\(source)" }
    static let panelShowsRecord = "panel.showRecordButton"

    static let togglePanelHotkey = "hotkey.togglePanel"
    static func hotkey(_ modeID: String) -> String { "hotkey.\(modeID)" }

    static let panelVisible = "panel.visible"
    static let panelOpacity = "panel.opacity"
    static let panelButtonSize = "panel.buttonSize"
    static let panelEditorButtons = "panel.showEditorButtons"
    static func panelShows(_ modeID: String) -> String { "panel.show.\(modeID)" }

    static let editorAskBeforeDiscard = "editor.askBeforeDiscard"
    static let editorSaveOverwritesOpened = "editor.saveOverwritesOpenedFile"
    static let editorDefaultTool = "editor.defaultTool"
    static let editorSelectAllOnOpen = "editor.selectAllOnOpen"
    static let editorCropOnDrag = "editor.cropOnDrag"
    static let editorShowSelectionSize = "editor.showSelectionSize"
    static let editorResizeKeepProportions = "editor.resizeKeepProportions"
    static let editorBackgroundFill = "editor.backgroundFill"

    static let appearance = "appearance.preference"

    static let screenRecordingAsked = "state.screenRecordingAsked"
    static let accessibilityAsked = "state.accessibilityAsked"
}

/// Every setting the app has. Hotkey rows and "show on panel" toggles are generated from the registered
/// capture modes, so adding a mode adds its settings without touching this list.
enum AppSettings {
    static let toggleDefault = KeyShortcut.digit(0, [.control, .shift])

    static var defaultRecordingFolder: String {
        (FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())).appendingPathComponent("CaptureDeck").path
    }

    static let defaultRecordingTemplate = "Recording $Y-$M-$D at $h.$m.$s"

    private static func recordingDefinitions() -> [SettingDefinition] {
        func choice(_ pairs: [(String, String)]) -> SettingDefinition.Control { .choice(pairs.map { .init($0.0, $0.1) }) }
        func row(_ id: String, _ group: String, _ title: String, _ value: SettingValue, _ control: SettingDefinition.Control,
                 _ order: Int, help: String? = nil, dependsOn: String? = nil) -> SettingDefinition {
            .init(id: id, section: .recording, group: group, title: title, help: help, defaultValue: value, control: control,
                  dependsOn: dependsOn, order: order)
        }
        let capture = "What to record", menuBar = "Menu bar" + SettingsHeading.liveSuffix
        let controls = "Floating controls" + SettingsHeading.liveSuffix, video = "Video"
        let audio = "Audio", pointer = "Mouse pointer, clicks and keys", saving = "Saving"
        return [
            row(SettingID.recSource, capture, "The Record shortcut records", .string(RecordingSourceKind.display.rawValue),
                choice(RecordingSourceKind.allCases.map { ($0.rawValue, $0.title) }), 0),
            row(SettingID.recCountdown, capture, "Countdown before recording", .int(3), .stepper(0...10, unit: "s"), 1),
            row(SettingID.recOutline, capture, "Outline the recorded region", .bool(true), .toggle, 4, help: "The outline is not part of the video."),
            row(SettingID.recMaxMinutes, capture, "Stop automatically after", .string("0"),
                choice([("0", "No limit"), ("1", "1 minute"), ("5", "5 minutes"), ("15", "15 minutes"), ("30", "30 minutes"), ("60", "1 hour"), ("120", "2 hours")]), 5),

            row(SettingID.recMenuBarTime, menuBar, "Show the recording time in the menu bar", .bool(true), .toggle, 0,
                help: "The elapsed time beside the menu bar icon, not counting pauses."),
            row(SettingID.recMenuBarBlink, menuBar, "Blink the red dot while recording", .bool(true), .toggle, 1,
                help: "Only the dot in the icon blinks. It holds still, as pause bars, while paused."),
            row(SettingID.recBlinkStyle, menuBar, "Blink style", .string(BlinkStyle.smooth.rawValue),
                choice(BlinkStyle.allCases.map { ($0.rawValue, $0.title) }), 2, dependsOn: SettingID.recMenuBarBlink),
            row(SettingID.recBlinkSpeed, menuBar, "Blink speed", .string("1.4"),
                choice([("2.2", "Slow"), ("1.4", "Normal"), ("0.9", "Fast")]), 3, dependsOn: SettingID.recMenuBarBlink),
            row(SettingID.recControls, controls, "Show the floating controls", .bool(true), .toggle, 0,
                help: "They never appear in the video. If off, use the shortcuts or the menu bar icon. Takes effect from the next recording."),
            row(SettingID.recControlsPosition, controls, "Position", .string(ControlsPosition.bottomLeft.rawValue),
                choice(ControlsPosition.allCases.map { ($0.rawValue, $0.title) }), 1,
                help: "You can also drag the controls at any time. To keep them where you drag them, choose \"Where I last dragged them\". Sitting beside the Dock needs the Accessibility permission; without it they sit just above it.",
                dependsOn: SettingID.recControls),
            row(SettingID.recControlsSize, controls, "Size", .string(ControlsSize.compact.rawValue),
                choice(ControlsSize.allCases.map { ($0.rawValue, $0.title) }), 2, dependsOn: SettingID.recControls),
            row(SettingID.recControlsOpacity, controls, "Opacity", .double(1), .slider(0.4...1, step: 0.05), 3, dependsOn: SettingID.recControls),
            row(SettingID.recControlsFileSize, controls, "Show the file size while recording", .bool(true), .toggle, 4, dependsOn: SettingID.recControls),
            row(SettingID.recConfirmDiscard, controls, "Discard and Start Over need a second click", .bool(true), .toggle, 5,
                help: "Guards against losing a recording with one slip.", dependsOn: SettingID.recControls),

            .init(id: SettingID.recControlsOrigin, section: .recording, title: "Controls position", defaultValue: .string(""), control: .hidden),
            .init(id: SettingID.recLastRegion, section: .recording, title: "Last recorded region", defaultValue: .string(""), control: .hidden),

            row(SettingID.recFrameRate, video, "Frame rate", .string("60"), choice(FrameRate.allCases.map { (String($0.rawValue), $0.title) }), 0,
                help: "24 film, 25 and 50 PAL video, 30 and 60 for the web. A screen cannot give more frames than its refresh rate."),
            row(SettingID.recCodec, video, "Video codec", .string(VideoCodec.hevc.rawValue), choice(VideoCodec.allCases.map { ($0.rawValue, $0.title) }), 1,
                help: "ProRes is saved as MOV and can use several gigabytes a minute."),
            row(SettingID.recQuality, video, "Quality (HEVC and H.264)", .string(VideoQuality.high.rawValue),
                choice(VideoQuality.allCases.map { ($0.rawValue, $0.title) }), 2,
                help: "The encoder spends bits only where the picture needs them, so a still screen stays small."),
            row(SettingID.recSharpColor, video, "Sharper colored text (HEVC 10-bit 4:2:2)", .bool(false), .toggle, 3,
                help: "Keeps more color detail in colored text and thin lines, with larger files. This Mac can decode it, but many browsers, Windows PCs and phones may not."),
            row(SettingID.recResolution, video, "Resolution", .string(ResolutionScale.native.rawValue),
                choice(ResolutionScale.allCases.map { ($0.rawValue, $0.title) }), 4),
            row(SettingID.recTiming, video, "Frame timing", .string(FrameTiming.variable.rawValue),
                choice(FrameTiming.allCases.map { ($0.rawValue, $0.title) }), 5,
                help: "Variable stores a frame when the screen changes. Constant writes every frame at the chosen rate, which some video editors expect."),

            row(SettingID.recSystemAudio, audio, "Record the Mac's sound", .bool(true), .toggle, 0),
            row(SettingID.recExcludeOwnAudio, audio, "Leave out CaptureDeck's own sounds", .bool(true), .toggle, 1, dependsOn: SettingID.recSystemAudio),
            row(SettingID.recMicrophone, audio, "Record the microphone", .bool(false), .toggle, 2,
                help: "macOS asks for permission the first time. Use headphones, or the microphone also picks up your speakers."),
            row(SettingID.recMicrophoneDevice, audio, "Microphone", .string(""),
                choice([("", "System default")] + Microphone.available().map { ($0.id, $0.name) }), 3, dependsOn: SettingID.recMicrophone),
            row(SettingID.recAudioBitrate, audio, "Audio quality (AAC)", .string("160000"),
                choice([("96000", "96 kbps"), ("128000", "128 kbps"), ("160000", "160 kbps"), ("192000", "192 kbps"), ("256000", "256 kbps"), ("320000", "320 kbps")]), 4),
            row(SettingID.recMixAudio, audio, "Combine the Mac's sound and microphone into one track", .bool(true), .toggle, 5,
                help: "Many players play only the first track. Turn off to keep two tracks for editing."),

            row(SettingID.recCursor, pointer, "Record the mouse pointer", .bool(true), .toggle, 0, help: "Takes effect from the next recording."),
            row(SettingID.recHalo, pointer, "Show a circle around the pointer", .bool(false), .toggle, 1,
                help: "Helps viewers follow the mouse. For window recordings, turn on a highlight before you start."),
            row(SettingID.recHaloColor, pointer, "Circle color", .string("#FFD60A59"), .color, 2,
                help: "The color's transparency sets how strong the filled circle looks.", dependsOn: SettingID.recHalo),
            row(SettingID.recHaloSize, pointer, "Circle size", .string("44"),
                choice([("28", "Small"), ("44", "Medium"), ("64", "Large"), ("88", "Extra large")]), 3, dependsOn: SettingID.recHalo),
            row(SettingID.recHaloStyle, pointer, "Circle style", .string(HaloStyle.filled.rawValue),
                choice(HaloStyle.allCases.map { ($0.rawValue, $0.title) }), 4, dependsOn: SettingID.recHalo),
            row(SettingID.recClicks, pointer, "Animate mouse clicks", .bool(false), .toggle, 5),
            row(SettingID.recClickColor, pointer, "Left click color", .string("#FFD60AFF"), .color, 6, dependsOn: SettingID.recClicks),
            row(SettingID.recRightClickColor, pointer, "Right click color", .string("#0A84FFFF"), .color, 7, dependsOn: SettingID.recClicks),
            row(SettingID.recClickSize, pointer, "Click animation size", .string("48"),
                choice([("32", "Small"), ("48", "Medium"), ("68", "Large"), ("96", "Extra large")]), 8, dependsOn: SettingID.recClicks),
            row(SettingID.recKeystrokes, pointer, "Show pressed keys", .string(KeystrokeMode.off.rawValue),
                choice(KeystrokeMode.allCases.map { ($0.rawValue, $0.title) }), 9,
                help: "Needs the Accessibility permission. Nothing is shown while a password field is active, but \"Every key\" records anything else you type."),

            row(SettingID.recReview, saving, "Review before saving", .bool(true), .toggle, 0,
                help: "Watch, trim, pick a format and see the file size before saving. Off: save straight to the folder."),
            row(SettingID.recFormat, saving, "File format", .string(ExportFormat.mp4.rawValue), choice(ExportFormat.allCases.map { ($0.rawValue, $0.title) }), 1),
            row(SettingID.recFolder, saving, "Save recordings to", .string(defaultRecordingFolder), .folder, 2),
            row(SettingID.recTemplate, saving, "File name", .string(defaultRecordingTemplate), .text(placeholder: defaultRecordingTemplate), 3,
                help: "$Y year, $M month, $D day, $h hour, $m minute, $s second; #### = a counter."),
            row(SettingID.recExactTrim, saving, "Trimming removes the cut footage completely", .bool(true), .toggle, 6,
                help: "On: the part you keep is re-encoded at maximum quality, starts on exactly the chosen frame, and holds nothing else. Off: faster and lossless, but the cut footage stays hidden in the file."),
            row(SettingID.recGIFRate, saving, "GIF frame rate", .string("12"), choice(["8", "10", "12", "15", "20", "25"].map { ($0, "\($0) fps") }), 4),
            row(SettingID.recGIFWidth, saving, "GIF maximum width", .string("960"), choice(["480", "640", "960", "1280", "1920"].map { ($0, "\($0) px") }), 5),
        ]
    }

    static var defaultSaveFolder: String {
        (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())).appendingPathComponent("CaptureDeck").path
    }

    static func registry(modes: [any CaptureMode]) -> SettingsRegistry {
        var defs: [SettingDefinition] = []

        // General
        defs += [
            .init(id: SettingID.launchAtLogin, section: .general, group: "Startup", title: "Start CaptureDeck when I log in",
                  help: "Adds CaptureDeck to your Login Items. macOS may ask you to approve it in System Settings > General > Login Items.",
                  defaultValue: .bool(false), control: .toggle, order: 0),
            .init(id: SettingID.startMinimized, section: .general, group: "Startup", title: "Start minimized in the menu bar",
                  help: "Opens with only the menu bar icon. The capture panel stays hidden until you show it (from the menu bar icon or its hotkey).",
                  defaultValue: .bool(false), control: .toggle, order: 1),
            .init(id: SettingID.captureSound, section: .general, group: "Feedback", title: "Play a sound after each capture",
                  defaultValue: .bool(true), control: .toggle, order: 0),
            .init(id: SettingID.soundName, section: .general, group: "Feedback", title: "Capture sound",
                  help: "You hear the new sound once when you press Apply.",
                  defaultValue: .string("Pop"),
                  control: .choice(["Pop", "Tink", "Glass", "Ping", "Purr", "Bottle"].map { .init($0, $0) }),
                  dependsOn: SettingID.captureSound, order: 1),
        ]

        // Capture
        defs += [
            .init(id: SettingID.autoCopy, section: .capture, group: "After capturing", title: "Copy the image to the clipboard",
                  defaultValue: .bool(true), control: .toggle, order: 0),
            .init(id: SettingID.openEditor, section: .capture, group: "After capturing", title: "Open the image in the editor",
                  defaultValue: .bool(true), control: .toggle, order: 1),
            .init(id: SettingID.autoSave, section: .capture, group: "After capturing", title: "Save the image to a file automatically",
                  help: "Folder, file name and format are on the Output page.", defaultValue: .bool(false), control: .toggle, order: 2),
            .init(id: SettingID.includeCursor, section: .capture, group: "Pointer and timing", title: "Include the mouse pointer",
                  defaultValue: .bool(false), control: .toggle, order: 0),
            .init(id: SettingID.labelDisplays, section: .capture, group: "Multiple displays", title: "Label each display in All Displays captures",
                  help: "Sets the displays apart on a dark glass backdrop with a \"Screen 1\", \"Screen 2\" label under each one. The screenshots themselves are not drawn on. Turn off to get the displays joined edge to edge.",
                  defaultValue: .bool(true), control: .toggle, order: 0),
            .init(id: SettingID.closeEditorAfterCopy, section: .capture, group: "Editor", title: "Close the editor after copying",
                  help: "Clicking Copy in the editor puts the image on the clipboard and closes the editor window.",
                  defaultValue: .bool(false), control: .toggle, order: 0),
            .init(id: SettingID.delaySeconds, section: .capture, group: "Pointer and timing", title: "Delay before capturing",
                  help: "Shows a countdown first, so you can open a menu or arrange the screen. 0 = no delay.",
                  defaultValue: .int(0), control: .stepper(0...30, unit: "s"), order: 1),
            .init(id: SettingID.scrollSpeed, section: .capture, group: "Scrolling capture", title: "Scrolling speed",
                  help: "How fast the window glides during a scrolling capture. Slower is gentler to watch and gives pages more time to load; faster finishes sooner.",
                  defaultValue: .string(ScrollSpeed.medium.rawValue),
                  control: .choice(ScrollSpeed.allCases.map { .init($0.rawValue, $0.title) }), order: 0),
            .init(id: SettingID.textCaptureAction, section: .capture, group: "Capture Text (OCR)", title: "After capturing text",
                  help: "Language, line breaks and spelling are on the Editor page, under Text recognition. They apply here too.",
                  defaultValue: .string(TextCaptureAction.copy.rawValue),
                  control: .choice(TextCaptureAction.allCases.map { .init($0.rawValue, $0.title) }), order: 0),
            .init(id: SettingID.magnifier, section: .capture, group: "Region selection", title: "Show the magnifier",
                  defaultValue: .bool(true), control: .toggle, order: 0),
            .init(id: SettingID.magnifierZoom, section: .capture, group: "Region selection", title: "Magnifier zoom",
                  defaultValue: .string("8"), control: .choice([.init("4", "4×"), .init("8", "8×"), .init("12", "12×"), .init("16", "16×")]),
                  dependsOn: SettingID.magnifier, order: 1),
            .init(id: SettingID.dimLevel, section: .capture, group: "Region selection", title: "Dim the screen outside the selection",
                  defaultValue: .double(0.4), control: .slider(0...0.8, step: 0.05), order: 2),
            .init(id: SettingID.fixedPresets, section: .capture, group: "Fixed size", title: "Preset sizes (pixels)",
                  help: "Shown when you right-click in fixed-size capture. Separate sizes with commas, e.g. 640x480, 1280x720.",
                  defaultValue: .string(FixedSizeText.format(FixedSizeCaptureMode.defaultPresets)), control: .sizeList),
            .init(id: SettingID.fixedSizeLast, section: .capture, title: "Last fixed size", defaultValue: .string(""), control: .hidden),
        ]

        // Output
        defs += [
            .init(id: SettingID.saveFolder, section: .output, group: "Save location", title: "Save folder",
                  help: "Where automatic saving puts files, and where the editor's Save dialog opens.",
                  defaultValue: .string(defaultSaveFolder), control: .folder, order: 0),
            .init(id: SettingID.fileTemplate, section: .output, group: "Save location", title: "File name",
                  help: "Names new captures (the editor title and Save dialog too). $Y year, $M month, $D day, $h hour, $m minute, $s second; #### = a counter (0001, 0002…).",
                  defaultValue: .string(FilenameTemplate.defaultTemplate), control: .text(placeholder: FilenameTemplate.defaultTemplate),
                  order: 1),
            .init(id: SettingID.format, section: .output, group: "Format", title: "Image format",
                  defaultValue: .string("png"), control: .choice([.init("png", "PNG"), .init("jpeg", "JPEG"), .init("tiff", "TIFF")]), order: 0),
            .init(id: SettingID.jpegQuality, section: .output, group: "Format", title: "JPEG quality",
                  defaultValue: .double(0.9), control: .slider(0.3...1.0, step: 0.05), order: 1),
        ]

        // Hotkeys: one per capture mode, generated from the modes.
        for (index, mode) in modes.enumerated() {
            defs.append(.init(id: SettingID.hotkey(mode.id), section: .hotkeys, group: "Capture", title: mode.title,
                              defaultValue: .shortcut(mode.defaultShortcut), control: .shortcut, order: index))
        }
        defs.append(.init(id: SettingID.togglePanelHotkey, section: .hotkeys, group: "Capture panel", title: "Show / hide the capture panel",
                          help: "Click a shortcut, then press the new keys. Delete clears it; Esc cancels.",
                          defaultValue: .shortcut(toggleDefault), control: .shortcut))

        defs += recordingDefinitions()

        // Recording hotkeys.
        defs += [
            .init(id: SettingID.recordHotkey, section: .hotkeys, group: "Screen recording", title: "Start / stop recording",
                  defaultValue: .shortcut(KeyShortcut(keyCode: 0x0F, modifiers: [.control, .shift], keyLabel: "R")), control: .shortcut, order: 0),
            .init(id: SettingID.recordPauseHotkey, section: .hotkeys, group: "Screen recording", title: "Pause / resume recording",
                  defaultValue: .shortcut(KeyShortcut(keyCode: 0x23, modifiers: [.control, .shift], keyLabel: "P")), control: .shortcut, order: 1),
        ]
        defs.append(.init(id: SettingID.recordLastRegionHotkey, section: .hotkeys, group: "Screen recording", title: "Record Last Region",
                          defaultValue: .shortcut(nil), control: .shortcut, order: 9))
        for (index, source) in RecordingSourceKind.allCases.enumerated() {
            defs.append(.init(id: SettingID.recordSourceHotkey(source.rawValue), section: .hotkeys, group: "Screen recording", title: source.menuTitle,
                              defaultValue: .shortcut(nil), control: .shortcut, order: 2 + index))
        }
        defs.append(.init(id: SettingID.panelShowsRecord, section: .panel, group: "Panel", title: "Show the Record button",
                          defaultValue: .bool(true), control: .toggle, order: 4))

        // Capture panel
        defs += [
            .init(id: SettingID.panelVisible, section: .panel, group: "Panel", title: "Show the capture panel",
                  defaultValue: .bool(true), control: .toggle, order: 0),
            .init(id: SettingID.panelOpacity, section: .panel, group: "Panel", title: "Opacity",
                  defaultValue: .double(1.0), control: .slider(0.3...1.0, step: 0.05), order: 1),
            .init(id: SettingID.panelButtonSize, section: .panel, group: "Panel", title: "Button size",
                  defaultValue: .string("medium"), control: .choice([.init("small", "Small"), .init("medium", "Medium"), .init("large", "Large")]), order: 2),
            .init(id: SettingID.panelEditorButtons, section: .panel, group: "Panel", title: "Show the “Open image” and “Edit clipboard image” buttons",
                  help: "You can also drop an image file on the panel to edit it.", defaultValue: .bool(true), control: .toggle, order: 3),
        ]
        for (index, mode) in modes.enumerated() {
            defs.append(.init(id: SettingID.panelShows(mode.id), section: .panel, group: "Buttons shown", title: mode.title,
                              defaultValue: .bool(true), control: .toggle, order: index))
        }

        // Editor
        defs += [
            .init(id: SettingID.editorAskBeforeDiscard, section: .editor, group: "Closing and saving", title: "Ask before closing an image with unsaved changes",
                  defaultValue: .bool(true), control: .toggle, order: 0),
            .init(id: SettingID.editorSaveOverwritesOpened, section: .editor, group: "Closing and saving",
                  title: "Save writes back to files opened from disk",
                  help: "Off: Save asks where to save, so an opened file is never overwritten by accident.",
                  defaultValue: .bool(false), control: .toggle, order: 1),
        ]

        defs += [
            .init(id: SettingID.editorDefaultTool, section: .editor, group: "Tools", title: "Tool selected when an image opens",
                  defaultValue: .string(EditorToolRegistry.defaultToolID),
                  control: .choice(EditorToolRegistry.descriptors.map { .init($0.id, $0.title) }), order: 0),
            .init(id: SettingID.editorSelectAllOnOpen, section: .editor, group: "Tools", title: "Start with the whole picture selected",
                  help: "With the Rectangle Select tool, a new picture opens fully selected, with handles on every corner and edge to drag.",
                  defaultValue: .bool(true), control: .toggle, order: 1),
            .init(id: SettingID.editorCropOnDrag, section: .editor, group: "Tools", title: "Crop when I let go of a dragged edge or corner",
                  help: "Drag any edge or corner of the selected picture inward to crop it at once, without the Crop button. Undo brings it back.",
                  defaultValue: .bool(true), control: .toggle, order: 2),
            .init(id: SettingID.editorShowSelectionSize, section: .editor, group: "Tools", title: "Show the size of the selection",
                  defaultValue: .bool(true), control: .toggle, order: 3),
        ]

        let recognition = "Text recognition (OCR)"
        let languages = TextReadingOptions.supportedLanguages().map { code in
            SettingDefinition.Choice(code, Locale.current.localizedString(forIdentifier: code) ?? code)
        }
        defs += [
            .init(id: TextReadingSetting.language, section: .editor, group: recognition, title: "Language",
                  help: "Automatic suits most pictures. Choose a language if its text is misread.",
                  defaultValue: .string(""), control: .choice([.init("", "Automatic")] + languages), order: 0),
            .init(id: TextReadingSetting.keepsLineBreaks, section: .editor, group: recognition, title: "Keep line breaks",
                  help: "On: copied text has the same lines as the picture. Off: the lines of each paragraph are joined.",
                  defaultValue: .bool(true), control: .toggle, order: 1),
            .init(id: TextReadingSetting.correctsSpelling, section: .editor, group: recognition, title: "Correct spelling",
                  help: "Helps with ordinary writing. Leave off for code, names and numbers, which it can \"correct\" wrongly.",
                  defaultValue: .bool(false), control: .toggle, order: 2),
        ]

        defs += [
            .init(id: SettingID.editorResizeKeepProportions, section: .editor, group: "Image size", title: "Keep proportions when resizing",
                  help: "The starting state of the checkbox in the Resize dialog.", defaultValue: .bool(true), control: .toggle, order: 0),
            .init(id: SettingID.editorBackgroundFill, section: .editor, group: "Image size", title: "Fill color for new areas",
                  help: "Used by Canvas Size and Rotate by Angle for the space they add. Set the opacity to 0 for transparent.",
                  defaultValue: .string("#FFFFFFFF"), control: .color, order: 1),
        ]

        // Draw tools: every drawing tool's remembered look, generated from the tool list so a new tool
        // gets its settings without touching this file.
        for tool in EditorToolRegistry.descriptors where tool.kind == .draw {
            for (index, property) in tool.styleProperties.enumerated() {
                let id = ToolStyleSetting.id(tool, property)
                let style = tool.defaultStyle
                func def(_ title: String, _ value: SettingValue, _ control: SettingDefinition.Control) -> SettingDefinition {
                    .init(id: id, section: .drawing, group: tool.title, title: title, defaultValue: value, control: control, order: index)
                }
                switch property {
                case .stroke: defs.append(def(tool.propertyTitles[.stroke].map { "\($0) color" } ?? "Color", .string(style.strokeColor.hex), .color))
                case .fill: defs.append(def(tool.propertyTitles[.fill].map { "\($0) color" } ?? "Fill color", .string(style.fillColor.hex), .color))
                case .width: defs.append(def(tool.propertyTitles[.width] ?? "Line width", .int(Int(style.lineWidth)), .stepper(0...100, unit: "px")))
                case .fontName:
                    defs.append(def("Font", .string(style.fontName), .choice(TextFonts.common.map { .init($0, $0) })))
                case .fontSize: defs.append(def("Size", .int(Int(style.fontSize)), .stepper(4...400, unit: "px")))
                case .startHead, .endHead:
                    let value = property == .endHead ? style.endHead : style.startHead
                    defs.append(def(tool.propertyTitles[property].map { "\($0) style" } ?? "End style", .string(value.rawValue),
                                    .choice(ArrowHeadStyle.allCases.map { .init($0.rawValue, $0.title) })))
                case .textColor: defs.append(def(tool.propertyTitles[.textColor].map { "\($0) color" } ?? "Text color", .string(style.textColor.hex), .color))
                case .zoom: defs.append(def("Zoom", .int(Int(style.strength)), .stepper(2...8, unit: "×")))
                case .strength: defs.append(def(tool.propertyTitles[.strength] ?? "Strength", .int(Int(style.strength)), .stepper(1...60, unit: "px")))
                case .redaction:
                    defs.append(def(tool.propertyTitles[.redaction] ?? "Hide with", .string(style.redaction.rawValue),
                                    .choice(RedactionMode.allCases.map { .init($0.rawValue, $0.title) })))
                case .bold: defs.append(def("Bold", .bool(style.bold), .toggle))
                case .italic: defs.append(def("Italic", .bool(style.italic), .toggle))
                case .alignment:
                    defs.append(def("Alignment", .string(style.alignment.rawValue), .choice(TextAlignment.allCases.map { .init($0.rawValue, $0.rawValue.capitalized) })))
                case .opacity: defs.append(def("Opacity", .double(style.opacity), .slider(0.05...1, step: 0.05)))
                case .dash:
                    defs.append(def("Line style", .string(style.dash.rawValue),
                                    .choice(DashStyle.allCases.map { .init($0.rawValue, $0.rawValue.capitalized) })))
                case .cornerRadius: defs.append(def("Corner radius", .int(Int(style.cornerRadius)), .stepper(0...200, unit: "px")))
                }
            }
        }

        // Appearance
        defs.append(.init(id: SettingID.appearance, section: .appearance, group: "Theme", title: "Theme",
                          help: "System follows macOS and switches automatically between light and dark.",
                          defaultValue: .string("system"),
                          control: .choice(AppearancePreference.allCases.map { .init($0.rawValue, $0.title) })))

        // Remembered state (not shown)
        defs += [
            .init(id: SettingID.screenRecordingAsked, section: .advanced, title: "Asked for Screen Recording", defaultValue: .bool(false), control: .hidden),
            .init(id: SettingID.accessibilityAsked, section: .advanced, title: "Asked for Accessibility", defaultValue: .bool(false), control: .hidden),
        ]
        return SettingsRegistry(defs)
    }
}
