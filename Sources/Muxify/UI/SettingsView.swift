import AppKit
import SwiftUI
import MuxifyCore

/// Settings (⌘,): every setting of `Config.template`, with the local Config's values, saved into its file (ADR 0074).
struct SettingsView: View {
    @Bindable var model: SettingsModel
    /// The section shown last, as other Settings windows keep their tab.
    @AppStorage("settingsSection") private var storedSection = ""
    private var section: String { Self.sections.contains(storedSection) ? storedSection : Self.sections[0] }
    @State private var query = ""

    private static let sections: [String] = Config.settings.reduce(into: []) { sections, setting in
        if sections.last != setting.path[0] { sections.append(setting.path[0]) }
    }

    private var shown: [ConfigSetting] {
        guard query.isEmpty else {
            return Config.settings.filter { $0.id.localizedCaseInsensitiveContains(query)
                || $0.help.localizedCaseInsensitiveContains(query) }
        }
        return Config.settings.filter { $0.path[0] == section }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SettingsSearchField(text: $query, prompt: "Search")
                    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                // A fixed list: every section is always there to pick.
                List(Self.sections, id: \.self, selection: Binding(get: { query.isEmpty ? section : nil },
                                                                   set: { if let new = $0 { storedSection = new; query = "" } })) {
                    Text($0).accessibilityIdentifier("settings-section-\($0)")
                }
                .listStyle(.sidebar)
            }
            .frame(width: 200)
            Divider()
            VStack(spacing: 0) {
                if !model.otherProblems.isEmpty || model.saveError != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.otherProblems, id: \.description) { Text($0.description) }
                        if let error = model.saveError { Text(error) }
                    }
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    Divider()
                }
                Form {
                    ForEach(shown) { setting in
                        SettingRow(field: model.field(setting), model: model, showsSection: !query.isEmpty)
                    }
                }
                .formStyle(.grouped)
                Divider()
                SettingsActions(model: model)
            }
        }
        .navigationTitle(query.isEmpty ? "Settings: \(section)" : "Settings")
        .frame(minWidth: 820, idealWidth: 960, minHeight: 540, idealHeight: 700)
        .background(AppWindowRegistration { window in
            // Settings closes; it neither minimizes nor zooms.
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        })
        .onAppear { model.revertIfUnchanged() }
        .onChange(of: model.configStore.config) { model.revertIfUnchanged() }
    }
}

/// The Config's path and the window's buttons, under the settings.
private struct SettingsActions: View {
    @Bindable var model: SettingsModel

    var body: some View {
        HStack(spacing: 8) {
            Text((model.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            Button { model.configStore.openInEditor() } label: { Label("Open in Editor", systemImage: "square.and.pencil") }
                .help("Open the Config file in its editor")
            Button("Load Defaults") { model.loadDefaults() }
                .help("Remove every setting from the form. The file changes on Save.")
            Button("Revert") { model.revert() }
                .help("Discard the changes")
                .disabled(!model.hasChanges)
            Button("Save") { model.save() }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasChanges || model.hasSyntaxError)
                .accessibilityIdentifier("settings-save")
        }
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
        .buttonBorderShape(.roundedRectangle)
        .controlSize(.large)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

private struct SettingRow: View {
    let field: SettingField
    let model: SettingsModel
    let showsSection: Bool
    /// A list or mapping shows its YAML text in place of its controls.
    @State private var showsYAML = false

    private var setting: ConfigSetting { field.setting }
    private var value: String? { field.value }
    /// The key under its section, or the whole key when it is the section itself, as `command_palettes`.
    private var label: String {
        setting.path.count == 1 || showsSection ? setting.id : setting.path.dropFirst().joined(separator: ".")
    }
    private var prompt: String { setting.isDefault ? setting.templateValue : "e.g. \(setting.templateValue)" }
    private var isToggle: Bool { setting.isBool && (value == nil || value == "true" || value == "false") }
    /// A value the Config set outside the list keeps a text field, so it shows as written.
    private var isMenu: Bool { !setting.choices.isEmpty && (value.map(setting.choices.contains) ?? true) }
    private var isKeybinding: Bool { setting.path.first == "keybindings" }
    /// The value as a tree, for the controls of a list or a mapping. Nil when its text is not YAML.
    private var tree: ConfigValue? {
        guard let value else { return emptyTree }
        return ConfigValue(yaml: value)
    }
    private var emptyTree: ConfigValue? {
        switch setting.templateTree {
        case .map?: .map([])
        case .list?: .list([])
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(.body, design: .monospaced))
                if value != nil {
                    Text("Set").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                    Button("Reset") { model.reset(setting) }.buttonStyle(.link).font(.caption)
                }
                Spacer()
                if setting.isBlock {
                    Toggle("YAML", isOn: $showsYAML).toggleStyle(.button).controlSize(.small)
                        .help("Edit the value as YAML text")
                } else if isToggle {
                    Toggle(label, isOn: Binding(get: { (value ?? setting.templateValue) == "true" },
                                                set: { model.set(setting, to: $0 ? "true" : "false") }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityIdentifier("settings-toggle-\(setting.id)")
                } else if isMenu {
                    ChoiceMenu(label: label, choices: setting.choices, value: value,
                               fallback: setting.isDefault ? setting.templateValue : nil) { model.set(setting, to: $0) }
                        .accessibilityIdentifier("settings-menu-\(setting.id)")
                } else {
                    HStack(spacing: 6) {
                        DraftField(value: value, prompt: prompt) { model.set(setting, to: $0) }
                            .frame(maxWidth: 260)
                            .accessibilityIdentifier("settings-field-\(setting.id)")
                        if isKeybinding { KeyRecorder { model.set(setting, to: $0) } }
                    }
                }
            }
            if setting.isBlock {
                if !showsYAML, let tree {
                    ValueEditor(setting: setting, path: [], value: tree) { model.set(setting, to: $0.yaml) }
                    if value == nil {
                        Button("Use Example", systemImage: "doc.on.doc") { model.set(setting, to: setting.templateValue) }
                            .controlSize(.small)
                            .help("Fill in the template's example, to change from there")
                    }
                } else {
                    DraftEditor(value: value, prompt: prompt) { model.set(setting, to: $0) }
                        .accessibilityIdentifier("settings-block-\(setting.id)")
                }
            }
            if !setting.help.isEmpty { HelpText(text: setting.help) }
            if field.refused {
                Text("Its section is written on one line in the file. Change it in the editor.")
                    .font(.callout).foregroundStyle(.red)
            }
            ForEach(field.problems, id: \.description) { problem in
                Text("Line \(problem.line): \(problem.message)").font(.callout).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The controls of a list or a mapping inside a setting, built from the shape its template and the reader give.
private struct ValueEditor: View {
    let setting: ConfigSetting
    let path: [ConfigPath]
    let value: ConfigValue
    let change: (ConfigValue) -> Void

    private var shape: ConfigShape { setting.shape(at: path) }

    var body: some View {
        switch value {
        case .scalar(let text): ScalarEditor(shape: shape, text: text) { change(.scalar($0)) }
        case .list(let items):
            if items.allSatisfy(\.isScalar), itemModel.map(\.isScalar) ?? true {
                WordList(choices: setting.shape(at: path + [.item(0)]).choices,
                         words: items.compactMap { if case .scalar(let word) = $0 { word } else { nil } }) { change(.list($0.map(ConfigValue.scalar))) }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 8) {
                            ValueEditor(setting: setting, path: path + [.item(index)], value: item) { new in
                                var items = items
                                items[index] = new
                                change(.list(items))
                            }
                            Spacer(minLength: 0)
                            RemoveButton { change(.list(items.enumerated().filter { $0.offset != index }.map(\.element))) }
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button("Add Item", systemImage: "plus") { change(.list(items + [(itemModel ?? .scalar("")).blank])) }
                        .controlSize(.small)
                }
            }
        case .map(let entries):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    let editor = ValueEditor(setting: setting, path: path + [.key(entry.key)], value: entry.value) { new in
                        var entries = entries
                        entries[index].value = new
                        change(.map(entries))
                    }
                    let remove = RemoveButton { change(.map(entries.enumerated().filter { $0.offset != index }.map(\.element))) }
                    // A mapping or a list of items goes under its key; a value of one line stays beside it.
                    if entry.value.isNested {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                key(entry, at: index, in: entries)
                                Spacer()
                                remove
                            }
                            editor.padding(.leading, 16)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            key(entry, at: index, in: entries)
                            editor
                            Spacer(minLength: 0)
                            remove
                        }
                    }
                }
                addEntry(entries)
            }
        }
    }

    @ViewBuilder private func key(_ entry: ConfigValue.Entry, at index: Int, in entries: [ConfigValue.Entry]) -> some View {
        if shape.userKeys {
            DraftField(value: entry.key, prompt: "name") { key in
                var entries = entries
                entries[index].key = key
                change(.map(entries))
            }
            .frame(width: 140)
        } else {
            Text(entry.key).font(.system(.callout, design: .monospaced)).frame(minWidth: 110, alignment: .leading)
        }
    }

    /// The template's model of an item of this list.
    private var itemModel: ConfigValue? { setting.shape(at: path + [.item(0)]).model }

    @ViewBuilder private func addEntry(_ entries: [ConfigValue.Entry]) -> some View {
        if shape.userKeys {
            Button("Add", systemImage: "plus") {
                let model = setting.shape(at: path + [.key("")]).model ?? .scalar("")
                change(.map(entries + [.init(key: "", value: model.blank)]))
            }
            .controlSize(.small)
        } else {
            let missing = shape.keys.filter { key in !entries.contains { $0.key == key } }
            if !missing.isEmpty {
                Menu("Add Field") {
                    ForEach(missing, id: \.self) { key in
                        Button(key) {
                            let model = setting.shape(at: path + [.key(key)]).model ?? .scalar("")
                            change(.map(entries + [.init(key: key, value: model.blank)]))
                        }
                    }
                }
                .controlSize(.small).fixedSize()
            }
        }
    }
}

/// One value: a menu for a fixed list, a switch for a boolean, else a text field, with a recorder for a key trigger.
private struct ScalarEditor: View {
    let shape: ConfigShape
    let text: String
    let change: (String) -> Void

    var body: some View {
        if !shape.choices.isEmpty, text.isEmpty || shape.choices.contains(text) {
            ChoiceMenu(label: "", choices: shape.choices, value: text.isEmpty ? nil : text, fallback: nil, change: change)
        } else if case .scalar(let model)? = shape.model, model == "true" || model == "false", text == "true" || text == "false" {
            Toggle("", isOn: Binding(get: { text == "true" }, set: { change($0 ? "true" : "false") }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        } else {
            HStack(spacing: 6) {
                DraftField(value: text, prompt: shapePrompt, change: change)
                if shape.isTrigger { KeyRecorder(record: change) }
            }
        }
    }

    private var shapePrompt: String {
        if case .scalar(let model)? = shape.model { return model }
        return ""
    }
}

/// A list of words, as `sources: [topics, sessions]`: each word removes with its ×, and Add offers the rest.
private struct WordList: View {
    let choices: [String]
    let words: [String]
    let change: ([String]) -> Void
    @State private var custom = ""

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Button { change(words.enumerated().filter { $0.offset != index }.map(\.element)) } label: {
                    HStack(spacing: 3) {
                        Text(word).font(.system(.callout, design: .monospaced))
                        Image(systemName: "xmark").font(.caption2)
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Remove \(word)")
            }
            let rest = choices.filter { !words.contains($0) }
            if choices.isEmpty {
                TextField("Add", text: $custom).frame(width: 120).controlSize(.small)
                    .onSubmit {
                        let word = custom.trimmingCharacters(in: .whitespaces)
                        if !word.isEmpty { change(words + [word]) }
                        custom = ""
                    }
            } else if !rest.isEmpty {
                Menu {
                    ForEach(rest, id: \.self) { word in Button(word) { change(words + [word]) } }
                } label: { Image(systemName: "plus") }
                .menuIndicator(.hidden).controlSize(.small).fixedSize()
                .help("Add a value")
            }
        }
    }
}

/// The system search field, small, over the section list.
private struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("settings-search")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            text.wrappedValue = (note.object as? NSSearchField)?.stringValue ?? ""
        }
    }
}

/// A setting's comments from the template. Long ones, such as the notes over the first keybinding, show three
/// lines until More.
private struct HelpText: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        let long = text.components(separatedBy: "\n").count > 3
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.callout).foregroundStyle(.secondary)
                .lineLimit(long && !expanded ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
            if long {
                Button(expanded ? "Less" : "More") { expanded.toggle() }.buttonStyle(.link).font(.callout)
            }
        }
    }
}

private struct ChoiceMenu: View {
    let label: String
    let choices: [String]
    let value: String?
    /// What shows while the value is not set.
    let fallback: String?
    let change: (String) -> Void

    var body: some View {
        Picker(label, selection: Binding(get: { value ?? fallback ?? "" }, set: change)) {
            if value == nil && fallback == nil { Text("Not set").tag("") }
            ForEach(choices, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden().fixedSize()
    }
}

private struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("Remove")
    }
}

/// A text field that keeps what is typed, spaces included, and takes a new value from outside only when it differs.
private struct DraftField: View {
    let value: String?
    let prompt: String
    let change: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .fixedSize(horizontal: false, vertical: true)
            .font(.system(.body, design: .monospaced))
            .onAppear { text = value ?? "" }
            .onChange(of: text) { _, new in if new != (value ?? "") { change(new) } }
            .onChange(of: value) { _, new in
                if (new ?? "") != text.trimmingCharacters(in: .whitespaces) { text = new ?? "" }
            }
    }
}

/// YAML text of several lines, kept as typed, so Return and a trailing new line stay.
private struct DraftEditor: View {
    let value: String?
    let prompt: String
    let change: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.callout, design: .monospaced))
            .frame(minHeight: CGFloat(max(3, (text.isEmpty ? prompt : text).components(separatedBy: "\n").count + 1)) * 17)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt).font(.system(.callout, design: .monospaced)).foregroundStyle(.tertiary)
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .onAppear { text = value ?? "" }
            .onChange(of: text) { _, new in if new != (value ?? "") { change(new) } }
            .onChange(of: value) { _, new in
                if (new ?? "") != text.trimmingCharacters(in: .newlines) { text = new ?? "" }
            }
    }
}

/// Records the next key the user presses as a trigger, spelled as the Config spells it. Escape alone cancels.
private struct KeyRecorder: View {
    let record: (String) -> Void
    @State private var monitor: Any?

    var body: some View {
        Button {
            monitor == nil ? start() : stop()
        } label: {
            Label(monitor == nil ? "Record" : "Press Keys…", systemImage: monitor == nil ? "record.circle" : "keyboard")
        }
        .controlSize(.small)
        .help("Record a key with its modifiers")
        .onDisappear(perform: stop)
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stop() }
            guard let trigger = KeyTrigger(event) else { return nil }
            if trigger.modifiers.isEmpty, trigger.key == .special(.escape) { return nil }
            record(trigger.spelling)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
