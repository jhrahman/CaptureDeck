import AppKit
import CoreModels
import Settings
import SwiftUI

/// The Settings window content: one tab per section, each tab generated from the registry.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @AppStorage("settings.selectedTab") private var selectedTab = SettingsSection.general.id
    @State private var confirmResetAll = false

    var body: some View {
        let sections = store.registry.sections
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                ForEach(sections) { section in
                    SectionTab(store: store, section: section)
                        .tabItem { Label(section.title, systemImage: section.symbol) }
                        .tag(section.id)
                }
            }
            Divider()
            HStack {
                Button("Reset All Settings…") { confirmResetAll = true }
                Spacer()
                Text("Changes apply immediately.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(minWidth: 620, minHeight: 540)
        .confirmationDialog("Reset every setting to its default?", isPresented: $confirmResetAll) {
            Button("Reset All Settings", role: .destructive) { store.resetAll() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct SectionTab: View {
    @ObservedObject var store: SettingsStore
    let section: SettingsSection

    var body: some View {
        let definitions = store.registry.definitions(in: section)
        // Keep the order they were registered in, grouped under optional headings.
        let groups = Dictionary(grouping: definitions, by: { $0.group ?? "" })
        let headings = definitions.reduce(into: [String]()) { if !$0.contains($1.group ?? "") { $0.append($1.group ?? "") } }
        VStack(spacing: 0) {
            Form {
                ForEach(headings, id: \.self) { heading in
                    Section(heading) {
                        ForEach((groups[heading] ?? []).sorted { $0.order < $1.order }) { definition in
                            SettingRow(store: store, definition: definition)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Reset This Tab") { store.reset(section: section) }
                    .disabled(definitions.allSatisfy { store.isDefault($0.id) })
            }
            .padding([.horizontal, .bottom], 12)
        }
    }
}

private struct SettingRow: View {
    @ObservedObject var store: SettingsStore
    let definition: SettingDefinition

    var body: some View {
        let enabled = definition.dependsOn.map { store.bool($0) } ?? true
        VStack(alignment: .leading, spacing: 3) {
            control
            if let help = definition.help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
            if let note = store.notes[definition.id] {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
        .disabled(!enabled)
    }

    private var id: String { definition.id }

    @ViewBuilder private var control: some View {
        switch definition.control {
        case .toggle:
            Toggle(definition.title, isOn: Binding(get: { store.bool(id) }, set: { store.set($0, for: id) }))

        case .stepper(let range, let unit):
            Stepper(value: Binding(get: { store.int(id) }, set: { store.set($0, for: id) }), in: range) {
                HStack {
                    Text(definition.title)
                    Spacer()
                    Text(unit.map { "\(store.int(id)) \($0)" } ?? "\(store.int(id))").foregroundStyle(.secondary).monospacedDigit()
                }
            }

        case .slider(let range, let step):
            LabeledContent(definition.title) {
                HStack {
                    Slider(value: Binding(get: { store.double(id) }, set: { store.set($0, for: id) }), in: range, step: step)
                        .frame(width: 180)
                    Text("\(Int((store.double(id) * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }

        case .choice(let choices):
            Picker(definition.title, selection: Binding(get: { store.string(id) }, set: { store.set($0, for: id) })) {
                ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
            }

        case .text(let placeholder):
            LabeledContent(definition.title) {
                TextField(placeholder ?? "", text: Binding(get: { store.string(id) }, set: { store.set($0, for: id) }))
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }

        case .sizeList:
            LabeledContent(definition.title) {
                TextField("640x480, 1280x720", text: Binding(get: { store.string(id) }, set: { store.set($0, for: id) }))
                    .textFieldStyle(.roundedBorder).frame(width: 300)
            }

        case .folder:
            LabeledContent(definition.title) {
                HStack {
                    Text(abbreviated(store.string(id))).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).frame(maxWidth: 220, alignment: .trailing)
                    Button("Choose…") { chooseFolder() }
                }
            }

        case .shortcut:
            LabeledContent(definition.title) {
                HStack {
                    ShortcutRecorder(shortcut: store.shortcut(id)) { commitShortcut($0) }
                        .frame(width: 150, height: 24)
                    Button { store.setNote(nil, for: id); store.reset(id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Restore the default shortcut")
                        .disabled(store.isDefault(id))
                }
            }

        case .hidden:
            EmptyView()
        }
    }

    private func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: (store.string(id) as NSString).expandingTildeInPath)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { store.set(url.path, for: id) }
    }

    /// Applies a recorded shortcut unless another CaptureDeck action already uses it.
    private func commitShortcut(_ shortcut: KeyShortcut?) {
        guard let shortcut else {
            store.setNote(nil, for: id)
            store.set(nil as KeyShortcut?, for: id)
            return
        }
        let assignments: [ShortcutAssignment] = store.registry.definitions.compactMap { d in
            guard case .shortcut = d.control, let s = store.shortcut(d.id) else { return nil }
            return ShortcutAssignment(id: d.id, title: d.title, shortcut: s)
        }
        let conflict = ShortcutConflicts.check(shortcut, for: id, among: assignments)
        if let conflict, conflict.blocksChange {
            store.setNote(conflict.message + " Choose a different shortcut.", for: id)
            NSSound.beep()
            return
        }
        store.setNote(conflict?.message, for: id)     // a system-shortcut warning; the app may replace it with a registration error
        store.set(shortcut, for: id)
    }
}
