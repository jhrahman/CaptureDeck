import AppKit
import CoreModels
import DesignSystem
import Settings
import SwiftUI

/// The Settings window content: the brand's sidebar with one entry per section, and that section's page beside it.
/// Everything on the pages is generated from the registry.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @AppStorage("settings.selectedTab") private var selectedTab = SettingsSection.general.id
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var confirmResetAll = false
    /// Short message shown after Apply / Revert, so there is always feedback that something happened.
    @State private var feedback: Feedback?
    @State private var clearFeedback: DispatchWorkItem?

    struct Feedback { let text: String; let good: Bool }

    static let sidebarWidth: CGFloat = 214

    private var section: SettingsSection {
        store.registry.sections.first { $0.id == selectedTab } ?? store.registry.sections.first ?? .general
    }
    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(store: store, selected: section.id, search: $search, searchFocused: $searchFocused,
                            select: { selectedTab = $0; search = ""; searchFocused = false }, resetAll: { confirmResetAll = true })
                .frame(width: Self.sidebarWidth)
            VStack(spacing: 0) {
                if isSearching {
                    SearchPage(store: store, query: search)
                } else {
                    SectionPage(store: store, section: section).id(section.id)       // each page starts at its top
                }
                footer
            }
            .background(Color(Brand.page))
        }
        .ignoresSafeArea()
        .tint(Color(Theme.accent))
        .glassWindow()
        .frame(minWidth: 820, minHeight: 580)
        .background {
            Button("Search Settings") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
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

    private var footer: some View {
        HStack(spacing: 10) {
            status
            Spacer()
            Button("Revert") { revert() }
                .neutralButton()
                .disabled(!store.hasPending)
                .help("Throw away the changes you have not applied")
            Button("Apply") { apply() }
                .buttonStyle(.borderedProminent)
                // Return applies, except while searching, where it must not save anything by surprise.
                .keyboardShortcut(searchFocused ? nil : .defaultAction)
                .disabled(!store.hasPending)
                .help("Save the changes and start using them")
        }
        .controlSize(.large)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color(store.hasPending ? Theme.accent : .clear).opacity(0.08))
        .background(Color(Brand.bar))
        .glassEdge(.top)
    }

    @ViewBuilder private var status: some View {
        if store.hasPending {
            Label("\(store.pending.count) unsaved \(store.pending.count == 1 ? "change" : "changes")", systemImage: "circle.fill")
                .labelStyle(.titleAndIcon).font(.callout.weight(.medium)).foregroundStyle(.orange)
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

private extension View {
    /// An ordinary button, free of the window's red tint.
    func neutralButton() -> some View { tint(Color(nsColor: .labelColor)) }
}

/// A navy column, the same in light and dark mode: the logo, a search box and the pages.
private struct SettingsSidebar: View {
    @ObservedObject var store: SettingsStore
    let selected: String
    @Binding var search: String
    var searchFocused: FocusState<Bool>.Binding
    let select: (String) -> Void
    let resetAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark().frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("CaptureDeck").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    Text("Settings").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.top, 44).padding(.horizontal, 16).padding(.bottom, 16)      // below the window's close buttons

            searchBox.padding(.horizontal, 12).padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(store.registry.sections) { section in
                        SidebarRow(section: section, selected: section.id == selected && search.isEmpty,
                                   changes: store.registry.definitions(in: section).filter { store.isPending($0.id) }.count) {
                            select(section.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            VStack(alignment: .leading, spacing: 6) {
                Button(action: resetAll) {
                    Label("Reset All Settings…", systemImage: "arrow.counterclockwise").font(.system(size: 11.5))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
                Text(AppInfo.nameAndVersion).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity)
        .background(Color(Brand.navy).opacity(0.94))
        .background(GlassBackground(material: .sidebar))
        .environment(\.colorScheme, .dark)
    }

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            TextField("Search settings", text: $search)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(.white)
                .focused(searchFocused)
                .onExitCommand { search = "" }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.55)) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(searchFocused.wrappedValue ? Color(Brand.recordRed) : Color.white.opacity(0.12)))
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    /// How many settings on the page are changed and not applied.
    let changes: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol).font(.system(size: 13, weight: .medium)).frame(width: 20)
                Text(section.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if changes > 0 {
                    Text("\(changes)").font(.system(size: 10, weight: .bold)).monospacedDigit().foregroundStyle(.black)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange))
                        .help("\(changes) not applied yet")
                }
            }
            .foregroundStyle(Color.white.opacity(selected ? 1 : 0.82))
            .padding(.horizontal, 9).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color(Brand.recordRed) : Color.white.opacity(hovering ? 0.10 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A page's title with a line about it, and a button that stages the defaults for just this page.
private struct PageHeader<Accessory: View>: View {
    let symbol: String
    let title: String
    let summary: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(Brand.navy)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader)
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
        .padding(.horizontal, 22).padding(.top, 30).padding(.bottom, 14)
        .glassEdge(.bottom)
    }
}

/// A heading and a card holding its settings, one per row.
private struct SettingsCard: View {
    @ObservedObject var store: SettingsStore
    let title: String
    var isLive = false
    let definitions: [SettingDefinition]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !title.isEmpty {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color(Theme.accent)).frame(width: 3, height: 13)
                    Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    if isLive {
                        Text("LIVE").font(.system(size: 9, weight: .heavy)).foregroundStyle(Color(Theme.accent))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().strokeBorder(Color(Theme.accent).opacity(0.6)))
                            .help("These also take effect in the middle of a recording, when you press Apply.")
                            .accessibilityLabel("Applies while recording")
                    }
                }
                .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                ForEach(Array(definitions.enumerated()), id: \.element.id) { index, definition in
                    if index > 0 { Rectangle().fill(Color(Brand.divider)).frame(height: 1).padding(.leading, 14) }
                    SettingRow(store: store, definition: definition)
                }
            }
            .background(Color(Brand.card))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(Brand.cardBorder)))
        }
    }
}

/// The settings of one section, grouped under headings, in the order they were registered.
private func grouped(_ definitions: [SettingDefinition]) -> [(group: String, definitions: [SettingDefinition])] {
    let groups = Dictionary(grouping: definitions, by: { $0.group ?? "" })
    let headings = definitions.reduce(into: [String]()) { if !$0.contains($1.group ?? "") { $0.append($1.group ?? "") } }
    return headings.map { ($0, (groups[$0] ?? []).sorted { $0.order < $1.order }) }
}

private struct SectionPage: View {
    @ObservedObject var store: SettingsStore
    let section: SettingsSection

    var body: some View {
        let definitions = store.registry.definitions(in: section)
        VStack(spacing: 0) {
            PageHeader(symbol: section.symbol, title: section.title, summary: section.summary) {
                Button("Reset This Page") { store.resetDraft(section: section) }
                    .neutralButton()
                    .disabled(definitions.allSatisfy { store.isDraftDefault($0.id) })
                    .help("Put this page's settings back to their defaults (then press Apply)")
            }
            ScrollView {
                VStack(spacing: 18) {
                    ForEach(grouped(definitions), id: \.group) { entry in
                        let heading = SettingsHeading(entry.group)
                        SettingsCard(store: store, title: heading.title, isLive: heading.isLive, definitions: entry.definitions)
                    }
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 22).padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Matches from every page, each card named after where it lives.
private struct SearchPage: View {
    @ObservedObject var store: SettingsStore
    let query: String

    var body: some View {
        let matches = SettingsSearch.matches(query, in: store.registry)
        VStack(spacing: 0) {
            PageHeader(symbol: "magnifyingglass", title: "Search",
                       summary: matches.isEmpty ? "Nothing matches “\(query)”" : "\(matches.count) \(matches.count == 1 ? "setting" : "settings") found") {
                EmptyView()
            }
            ScrollView {
                VStack(spacing: 18) {
                    ForEach(store.registry.sections) { section in
                        ForEach(grouped(matches.filter { $0.section == section }), id: \.group) { entry in
                            let heading = SettingsHeading(entry.group)
                            SettingsCard(store: store, title: heading.title.isEmpty ? section.title : "\(section.title)  ›  \(heading.title)",
                                         isLive: heading.isLive, definitions: entry.definitions)
                        }
                    }
                    if matches.isEmpty {
                        Text("Try a shorter word, such as “sound”, “color” or “folder”.").font(.callout).foregroundStyle(.secondary).padding(.top, 30)
                    }
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 22).padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct SettingRow: View {
    @ObservedObject var store: SettingsStore
    let definition: SettingDefinition

    var body: some View {
        let enabled = definition.dependsOn.map { store.draftBool($0) } ?? true
        let changed = store.isPending(definition.id)
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(definition.title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    // Marks a row changed since the last Apply.
                    if changed {
                        Circle().fill(Color.orange).frame(width: 7, height: 7).help("Changed: press Apply to save")
                            .accessibilityLabel("Changed, not applied yet")
                    }
                }
                if let help = definition.help {
                    Text(help).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let note = store.notes[definition.id] {
                    Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            control
        }
        // A setting that depends on a switch sits a step in from it.
        .padding(.leading, definition.dependsOn == nil ? 0 : 18)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 42)
        .background(changed ? Color.orange.opacity(0.07) : .clear)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }

    private var id: String { definition.id }

    /// Every control carries its setting's name for VoiceOver; the visible name is the row's own text.
    @ViewBuilder private var control: some View {
        switch definition.control {
        case .toggle:
            Toggle(definition.title, isOn: Binding(get: { store.draftBool(id) }, set: { store.setDraft($0, for: id) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)

        case .stepper(let range, let unit):
            HStack(spacing: 8) {
                Text(unit.map { "\(store.draftInt(id)) \($0)" } ?? "\(store.draftInt(id))").monospacedDigit().fixedSize()
                Stepper(definition.title, value: Binding(get: { store.draftInt(id) }, set: { store.setDraft($0, for: id) }), in: range)
                    .labelsHidden()
            }

        case .slider(let range, let step):
            HStack(spacing: 8) {
                Slider(value: Binding(get: { store.draftDouble(id) }, set: { store.setDraft($0, for: id) }), in: range) { editing in
                    // Snapped when let go, which avoids a row of tick marks under the track.
                    if !editing { store.setDraft((store.draftDouble(id) / step).rounded() * step, for: id) }
                }
                .frame(width: 160).accessibilityLabel(definition.title)
                Text("\(Int((store.draftDouble(id) * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit().frame(width: 40, alignment: .trailing)
            }

        case .choice(let choices):
            Picker(definition.title, selection: Binding(get: { store.draftString(id) }, set: { store.setDraft($0, for: id) })) {
                ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
            }
            .labelsHidden().fixedSize()

        case .text(let placeholder):
            TextField(placeholder ?? "", text: Binding(get: { store.draftString(id) }, set: { store.setDraft($0, for: id) }))
                .textFieldStyle(.roundedBorder).frame(width: 240).accessibilityLabel(definition.title)

        case .sizeList:
            TextField("640x480, 1280x720", text: Binding(get: { store.draftString(id) }, set: { store.setDraft($0, for: id) }))
                .textFieldStyle(.roundedBorder).frame(width: 250).accessibilityLabel(definition.title)

        case .folder:
            HStack(spacing: 8) {
                Label(abbreviated(store.draftString(id)), systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).frame(minWidth: 170, maxWidth: 230, alignment: .trailing)
                    .help(store.draftString(id))
                Button("Choose…") { chooseFolder() }.neutralButton()
            }

        case .color:
            ColorPicker(definition.title, selection: Binding(
                get: { Self.swiftUIColor(from: store.draftString(id)) },
                set: { store.setDraft(Self.hex(from: $0), for: id) }), supportsOpacity: true)
                .labelsHidden()

        case .shortcut:
            HStack(spacing: 6) {
                ShortcutRecorder(shortcut: store.draftShortcut(id)) { commitShortcut($0) }
                    .frame(width: 150, height: 26)
                Button { store.setNote(nil, for: id); store.resetDraft(id) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Restore the default shortcut")
                    .accessibilityLabel("Restore the default shortcut for \(definition.title)")
                    .opacity(store.isDraftDefault(id) ? 0 : 1)
                    .disabled(store.isDraftDefault(id))
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
