import AppKit
import CoreModels
import DesignSystem
import Settings
import SwiftUI

/// The Settings window content: one tab per section, each tab generated from the registry.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @AppStorage("settings.selectedTab") private var selectedTab = SettingsSection.general.id
    @State private var confirmResetAll = false
    /// Short message shown after Apply / Revert, so there is always feedback that something happened.
    @State private var feedback: Feedback?
    @State private var clearFeedback: DispatchWorkItem?

    struct Feedback { let text: String; let good: Bool }

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
            HStack(spacing: 10) {
                Button("Reset All Settings…") { confirmResetAll = true }
                Text(AppInfo.nameAndVersion).font(.caption).foregroundStyle(.secondary).padding(.leading, 6)
                Spacer()
                status
                Button("Revert") { revert() }
                    .disabled(!store.hasPending)
                    .help("Throw away the changes you have not applied")
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.hasPending)
                    .help("Save the changes and start using them")
            }
            .padding(12)
            .glassBar()
            .glassEdge(.top)
        }
        .glassWindow()
        .frame(minWidth: 680, minHeight: 540)
        .confirmationDialog("Reset every setting to its default?", isPresented: $confirmResetAll) {
            Button("Reset All Settings", role: .destructive) {
                store.resetDraftAll()
                show(store.hasPending ? Feedback(text: "Defaults ready: press Apply to save them", good: false)
                                      : Feedback(text: "Everything is already at its default", good: true))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The defaults are staged. Press Apply to save them.")
        }
    }

    @ViewBuilder private var status: some View {
        if store.hasPending {
            Label("\(store.pending.count) unsaved \(store.pending.count == 1 ? "change" : "changes")", systemImage: "circle.fill")
                .labelStyle(.titleAndIcon).font(.callout).foregroundStyle(.orange)
        } else if let feedback {
            Label(feedback.text, systemImage: feedback.good ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.callout).foregroundStyle(feedback.good ? Color.green : Color.secondary)
                .transition(.opacity)
        } else {
            Text("No unsaved changes").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func apply() {
        let count = store.applyPending().count
        show(Feedback(text: "\(count) \(count == 1 ? "setting" : "settings") saved and applied", good: true))
    }

    private func revert() {
        store.discardPending()
        show(Feedback(text: "Changes discarded", good: false))
    }

    /// Shows a message for a few seconds and tells VoiceOver.
    private func show(_ message: Feedback) {
        withAnimation { feedback = message }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message.text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        clearFeedback?.cancel()
        let work = DispatchWorkItem { withAnimation { feedback = nil } }
        clearFeedback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
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
            .scrollContentBackground(.hidden)         // let the window's glass show between the cards
            HStack {
                Spacer()
                Button("Reset This Tab") { store.resetDraft(section: section) }
                    .disabled(definitions.allSatisfy { store.isDraftDefault($0.id) })
            }
            .padding([.horizontal, .bottom], 12)
        }
    }
}

private struct SettingRow: View {
    @ObservedObject var store: SettingsStore
    let definition: SettingDefinition

    var body: some View {
        let enabled = definition.dependsOn.map { store.draftBool($0) } ?? true
        HStack(alignment: .top, spacing: 6) {
            // A small dot marks every row changed since the last Apply.
            Circle().fill(store.isPending(definition.id) ? Color.orange : Color.clear).frame(width: 7, height: 7).padding(.top, 6)
                .help(store.isPending(definition.id) ? "Changed: press Apply to save" : "")
            VStack(alignment: .leading, spacing: 3) {
                control
                if let help = definition.help {
                    Text(help).font(.caption).foregroundStyle(.secondary)
                }
                if let note = store.notes[definition.id] {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .disabled(!enabled)
    }

    private var id: String { definition.id }

    @ViewBuilder private var control: some View {
        switch definition.control {
        case .toggle:
            Toggle(definition.title, isOn: Binding(get: { store.draftBool(id) }, set: { store.setDraft($0, for: id) }))

        case .stepper(let range, let unit):
            Stepper(value: Binding(get: { store.draftInt(id) }, set: { store.setDraft($0, for: id) }), in: range) {
                HStack {
                    Text(definition.title)
                    Spacer()
                    Text(unit.map { "\(store.draftInt(id)) \($0)" } ?? "\(store.draftInt(id))").foregroundStyle(.secondary).monospacedDigit()
                }
            }

        case .slider(let range, let step):
            LabeledContent(definition.title) {
                HStack {
                    Slider(value: Binding(get: { store.draftDouble(id) }, set: { store.setDraft($0, for: id) }), in: range, step: step)
                        .frame(width: 180)
                    Text("\(Int((store.draftDouble(id) * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }

        case .choice(let choices):
            Picker(definition.title, selection: Binding(get: { store.draftString(id) }, set: { store.setDraft($0, for: id) })) {
                ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
            }

        case .text(let placeholder):
            LabeledContent(definition.title) {
                TextField(placeholder ?? "", text: Binding(get: { store.draftString(id) }, set: { store.setDraft($0, for: id) }))
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }

        case .sizeList:
            LabeledContent(definition.title) {
                TextField("640x480, 1280x720", text: Binding(get: { store.draftString(id) }, set: { store.setDraft($0, for: id) }))
                    .textFieldStyle(.roundedBorder).frame(width: 300)
            }

        case .folder:
            LabeledContent(definition.title) {
                HStack {
                    Text(abbreviated(store.draftString(id))).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).frame(maxWidth: 220, alignment: .trailing)
                    Button("Choose…") { chooseFolder() }
                }
            }

        case .color:
            ColorPicker(definition.title, selection: Binding(
                get: { Self.swiftUIColor(from: store.draftString(id)) },
                set: { store.setDraft(Self.hex(from: $0), for: id) }), supportsOpacity: true)

        case .shortcut:
            LabeledContent(definition.title) {
                HStack {
                    ShortcutRecorder(shortcut: store.draftShortcut(id)) { commitShortcut($0) }
                        .frame(width: 150, height: 24)
                    Button { store.setNote(nil, for: id); store.resetDraft(id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Restore the default shortcut")
                        .disabled(store.isDraftDefault(id))
                }
            }

        case .hidden:
            EmptyView()
        }
    }

    private static func swiftUIColor(from hex: String) -> Color {
        let c = RGBAColor(hex: hex) ?? .white
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    private static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return RGBAColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent).hex
    }

    private func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: (store.draftString(id) as NSString).expandingTildeInPath)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { store.setDraft(url.path, for: id) }
    }

    /// Applies a recorded shortcut unless another CaptureDeck action already uses it.
    private func commitShortcut(_ shortcut: KeyShortcut?) {
        guard let shortcut else {
            store.setNote(nil, for: id)
            store.setDraft(nil as KeyShortcut?, for: id)
            return
        }
        let assignments: [ShortcutAssignment] = store.registry.definitions.compactMap { d in
            guard case .shortcut = d.control, let s = store.draftShortcut(d.id) else { return nil }
            return ShortcutAssignment(id: d.id, title: d.title, shortcut: s)
        }
        let conflict = ShortcutConflicts.check(shortcut, for: id, among: assignments)
        if let conflict, conflict.blocksChange {
            store.setNote(conflict.message + " Choose a different shortcut.", for: id)
            NSSound.beep()
            return
        }
        store.setNote(conflict?.message, for: id)     // a system-shortcut warning; the app may replace it with a registration error
        store.setDraft(shortcut, for: id)
    }
}
