import AppKit

/// The main menu bar shown while an editor is open. Window-level actions have no explicit target,
/// so they go to the key editor window's controller through the responder chain.
@MainActor
enum EditorMenu {
    static func build(store: EditorStore) -> NSMenu {
        let main = NSMenu()

        func add(_ title: String, to menu: NSMenu, action: Selector?, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            menu.addItem(item)
        }
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }

        let app = submenu("CaptureDeck")
        add("Settings…", to: app, action: #selector(EditorStore.showSettings(_:)), key: ",", target: store)
        app.addItem(.separator())
        add("Quit CaptureDeck", to: app, action: #selector(NSApplication.terminate(_:)), key: "q")

        let file = submenu("File")
        add("Open…", to: file, action: #selector(EditorStore.openDocument(_:)), key: "o", target: store)
        file.addItem(.separator())
        add("Close Tab", to: file, action: #selector(NSWindow.performClose(_:)), key: "w")
        add("Save", to: file, action: Selector(("saveDocument:")), key: "s")
        add("Save As…", to: file, action: Selector(("saveDocumentAs:")), key: "s", modifiers: [.command, .shift])

        let edit = submenu("Edit")
        add("Undo", to: edit, action: Selector(("performUndo:")), key: "z")
        add("Redo", to: edit, action: Selector(("performRedo:")), key: "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add("Select All", to: edit, action: Selector(("selectEverything:")), key: "a")
        add("Deselect", to: edit, action: Selector(("deselect:")), key: "d")
        edit.addItem(.separator())
        add("Copy Image", to: edit, action: Selector(("copyImage:")), key: "c")
        add("Duplicate Selection to New Tab", to: edit, action: Selector(("duplicateSelection:")), key: "d", modifiers: [.command, .shift])
        add("Paste as New Tab", to: edit, action: #selector(EditorStore.pasteAsNewTab(_:)), key: "v", target: store)

        let image = submenu("Image")
        add("Crop to Selection", to: image, action: Selector(("cropToSelection:")), key: "k")
        add("Delete Selected Area", to: image, action: Selector(("deleteSelectedArea:")), key: "")
        add("Fill Selected Area with Picked Color", to: image, action: Selector(("fillSelectedArea:")), key: "")
        image.addItem(.separator())
        add("Rotate Right", to: image, action: Selector(("rotateRight:")), key: "r")
        add("Rotate Left", to: image, action: Selector(("rotateLeft:")), key: "l")
        add("Rotate by Angle…", to: image, action: Selector(("rotateImageByAngle:")))
        image.addItem(.separator())
        add("Flip Horizontal", to: image, action: Selector(("flipHorizontal:")))
        add("Flip Vertical", to: image, action: Selector(("flipVertical:")))
        image.addItem(.separator())
        add("Resize Image…", to: image, action: Selector(("resizeImage:")), key: "r", modifiers: [.command, .shift])
        add("Canvas Size…", to: image, action: Selector(("canvasSize:")), key: "c", modifiers: [.command, .shift])
        // Quick resizes (Ctrl+Cmd+1 to 4).
        for (index, percent) in [25, 50, 75, 200].enumerated() {
            let item = NSMenuItem(title: "Resize to \(percent)%", action: Selector(("resizeByPercent:")), keyEquivalent: String(index + 1))
            item.keyEquivalentModifierMask = [.control, .command]
            item.tag = percent
            image.addItem(item)
        }

        let object = submenu("Object")
        add("Duplicate", to: object, action: Selector(("duplicateObjects:")), key: "j")
        add("Delete", to: object, action: Selector(("deleteObjects:")), key: String(UnicodeScalar(NSBackspaceCharacter)!), modifiers: [])
        object.addItem(.separator())
        add("Bring to Front", to: object, action: Selector(("bringObjectsToFront:")), key: "]", modifiers: [.command, .option])
        add("Send to Back", to: object, action: Selector(("sendObjectsToBack:")), key: "[", modifiers: [.command, .option])

        // Tools: generated from the tool registry, with each tool's single-key shortcut shown.
        let tools = submenu("Tools")
        for descriptor in EditorToolRegistry.descriptors {
            let item = NSMenuItem(title: "\(descriptor.title)  (\(descriptor.key.uppercased()))", action: Selector(("chooseTool:")), keyEquivalent: "")
            item.representedObject = descriptor.id
            item.image = ToolIcons.image(for: descriptor, pointSize: 13)
            tools.addItem(item)
        }

        let view = submenu("View")
        add("Zoom In", to: view, action: Selector(("zoomIn:")), key: "=")
        add("Zoom Out", to: view, action: Selector(("zoomOut:")), key: "-")
        add("Fit to Window", to: view, action: Selector(("zoomFit:")), key: "9")
        add("Actual Size", to: view, action: Selector(("zoomActual:")), key: "0")

        let window = submenu("Window")
        add("Minimize", to: window, action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        window.addItem(.separator())
        add("Show Next Tab", to: window, action: #selector(NSWindow.selectNextTab(_:)), key: "\t", modifiers: [.control])
        add("Show Previous Tab", to: window, action: #selector(NSWindow.selectPreviousTab(_:)), key: "\t", modifiers: [.control, .shift])
        add("Move Tab to New Window", to: window, action: #selector(NSWindow.moveTabToNewWindow(_:)))
        NSApp.windowsMenu = window

        return main
    }
}
