import CaptureEngine
import CoreModels
import DesignSystem
import EditorEngine
import EditorUI
import Foundation
import Platform
import Settings

/// Stable setting keys used by the app. (A key is also its UserDefaults key: never rename without a migration.)
enum SettingID {
    static let captureSound = "general.captureSound"

    static let autoCopy = "capture.autoCopy"
    static let openEditor = "capture.openEditor"
    static let autoSave = "capture.autoSave"
    static let includeCursor = "capture.includeCursor"
    static let delaySeconds = "capture.delaySeconds"
    static let magnifier = "capture.magnifier"
    static let magnifierZoom = "capture.magnifierZoom"
    static let dimLevel = "capture.dimLevel"
    static let fixedPresets = "capture.fixedPresets"
    static let fixedSizeLast = "capture.fixedSizePx"      // hidden: remembered between captures

    static let saveFolder = "capture.saveFolder"
    static let fileTemplate = "capture.fileTemplate"
    static let format = "capture.format"
    static let jpegQuality = "capture.jpegQuality"

    static let togglePanelHotkey = "hotkey.togglePanel"
    static func hotkey(_ modeID: String) -> String { "hotkey.\(modeID)" }

    static let panelVisible = "panel.visible"
    static let panelOpacity = "panel.opacity"
    static let panelButtonSize = "panel.buttonSize"
    static func panelShows(_ modeID: String) -> String { "panel.show.\(modeID)" }

    static let editorAskBeforeDiscard = "editor.askBeforeDiscard"
    static let editorSaveOverwritesOpened = "editor.saveOverwritesOpenedFile"
    static let editorDefaultTool = "editor.defaultTool"
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

    static var defaultSaveFolder: String {
        (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())).appendingPathComponent("CaptureDeck").path
    }

    static func registry(modes: [any CaptureMode]) -> SettingsRegistry {
        var defs: [SettingDefinition] = []

        // General
        defs.append(.init(id: SettingID.captureSound, section: .general, group: "Feedback", title: "Play a sound after each capture",
                          defaultValue: .bool(true), control: .toggle))

        // Capture
        defs += [
            .init(id: SettingID.autoCopy, section: .capture, group: "After capturing", title: "Copy the image to the clipboard",
                  defaultValue: .bool(true), control: .toggle, order: 0),
            .init(id: SettingID.openEditor, section: .capture, group: "After capturing", title: "Open the image in the editor",
                  defaultValue: .bool(true), control: .toggle, order: 1),
            .init(id: SettingID.autoSave, section: .capture, group: "After capturing", title: "Save the image to a file automatically",
                  help: "Folder, file name and format are on the Output tab.", defaultValue: .bool(false), control: .toggle, order: 2),
            .init(id: SettingID.includeCursor, section: .capture, group: "Pointer and timing", title: "Include the mouse pointer",
                  defaultValue: .bool(false), control: .toggle, order: 0),
            .init(id: SettingID.delaySeconds, section: .capture, group: "Pointer and timing", title: "Delay before capturing",
                  help: "Shows a countdown first, so you can open a menu or arrange the screen. 0 = no delay.",
                  defaultValue: .int(0), control: .stepper(0...30, unit: "s"), order: 1),
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
            .init(id: SettingID.saveFolder, section: .output, group: "Auto-save", title: "Save folder",
                  defaultValue: .string(defaultSaveFolder), control: .folder, dependsOn: SettingID.autoSave, order: 0),
            .init(id: SettingID.fileTemplate, section: .output, group: "Auto-save", title: "File name",
                  help: "$Y year, $M month, $D day, $h hour, $m minute, $s second; #### = a counter (0001, 0002…).",
                  defaultValue: .string(FilenameTemplate.defaultTemplate), control: .text(placeholder: FilenameTemplate.defaultTemplate),
                  dependsOn: SettingID.autoSave, order: 1),
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

        // Capture panel
        defs += [
            .init(id: SettingID.panelVisible, section: .panel, group: "Panel", title: "Show the capture panel",
                  defaultValue: .bool(true), control: .toggle, order: 0),
            .init(id: SettingID.panelOpacity, section: .panel, group: "Panel", title: "Opacity",
                  defaultValue: .double(1.0), control: .slider(0.3...1.0, step: 0.05), order: 1),
            .init(id: SettingID.panelButtonSize, section: .panel, group: "Panel", title: "Button size",
                  defaultValue: .string("medium"), control: .choice([.init("small", "Small"), .init("medium", "Medium"), .init("large", "Large")]), order: 2),
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
            .init(id: SettingID.editorShowSelectionSize, section: .editor, group: "Tools", title: "Show the size of the selection",
                  defaultValue: .bool(true), control: .toggle, order: 1),
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
                case .zoom: defs.append(def("Zoom", .int(Int(style.strength)), .stepper(2...8, unit: "×")))
                case .strength: defs.append(def(tool.propertyTitles[.strength] ?? "Strength", .int(Int(style.strength)), .stepper(1...60, unit: "px")))
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
