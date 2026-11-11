import Foundation
import Observation
import MuxifyCore

/// One setting's value in the draft. Each row watches only its own field, so typing redraws one row.
@MainActor @Observable
final class SettingField {
    let setting: ConfigSetting
    /// The value in the draft as YAML text; nil when the key is not set.
    fileprivate(set) var value: String?
    fileprivate(set) var problems: [ConfigProblem] = []
    /// The change could not go into the file's text.
    fileprivate(set) var refused = false

    init(_ setting: ConfigSetting) { self.setting = setting }
}

/// The Settings window's draft of the local Config (ADR 0074). Unsaved changes stay when the window closes.
@MainActor @Observable
final class SettingsModel {
    let configStore: ConfigStore
    /// The file as last read or saved.
    private(set) var saved = ConfigText("")
    /// `saved` with the window's changes.
    private(set) var draft = ConfigText("")
    /// The problems no listed setting shows, such as an unknown section.
    private(set) var otherProblems: [ConfigProblem] = []
    private(set) var hasSyntaxError = false
    private(set) var saveError: String?
    @ObservationIgnored let fields: [String: SettingField] =
        Dictionary(uniqueKeysWithValues: Config.settings.map { ($0.id, SettingField($0)) })

    @ObservationIgnored private var check: Task<Void, Never>?
    /// Read on the main thread once, so a check off it does not ask AppKit.
    nonisolated(unsafe) private static let fontFamilies = SidebarTypography.fontFamilies

    init(configStore: ConfigStore) {
        self.configStore = configStore
        revert()
    }

    var path: String { configStore.path }
    var hasChanges: Bool { draft != saved }

    func field(_ setting: ConfigSetting) -> SettingField { fields[setting.id]! }

    /// An empty value removes the key, so the setting takes its default.
    func set(_ setting: ConfigSetting, to value: String) {
        let field = field(setting)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let refused: Bool
        if trimmed.isEmpty {
            draft.remove(setting.path)
            refused = false
        } else {
            refused = !draft.set(setting.path, to: setting.isBlock ? value.trimmingCharacters(in: .newlines) : trimmed,
                                 block: setting.isBlock)
        }
        if field.refused != refused { field.refused = refused }
        // Removing the last key of a section can remove the section, which changes no other listed value.
        let new = draft.value(at: setting.path)
        if field.value != new { field.value = new }
        scheduleCheck()
    }

    func reset(_ setting: ConfigSetting) {
        set(setting, to: "")
    }

    /// Removes every listed setting from the draft. The file changes only on Save.
    func loadDefaults() {
        Config.settings.forEach { draft.remove($0.path) }
        refreshFields()
        scheduleCheck()
    }

    func revert() {
        saved = ConfigText((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
        draft = saved
        saveError = nil
        refreshFields()
        checkNow()
    }

    /// Takes a change made outside the window, unless the window has changes of its own.
    func revertIfUnchanged() {
        if !hasChanges { revert() }
    }

    /// Checks the draft first, so a syntax error typed just now is never saved.
    func save() {
        checkNow()
        guard !hasSyntaxError else { return }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try draft.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            saveError = "Cannot save \(path): \(error.localizedDescription)"
            return
        }
        saved = draft
        saveError = nil
        configStore.reload()
    }

    /// Checks the draft now. A typed change waits for a pause, and the check runs off the main thread, so typing
    /// stays smooth.
    func checkNow() {
        check?.cancel()
        apply(Self.check(draft, path: path))
    }

    private func scheduleCheck() {
        check?.cancel()
        let draft = draft
        let path = path
        check = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result = await Task.detached { Self.check(draft, path: path) }.value
            guard !Task.isCancelled else { return }
            self?.apply(result)
        }
    }

    private struct Result {
        var problems: [String: [ConfigProblem]] = [:]
        var other: [ConfigProblem] = []
        var syntaxError = false
    }

    private func refreshFields() {
        for field in fields.values {
            let value = draft.value(at: field.setting.path)
            if field.value != value { field.value = value }
            if field.refused { field.refused = false }
        }
    }

    private func apply(_ result: Result) {
        for field in fields.values {
            let problems = result.problems[field.setting.id] ?? []
            if field.problems != problems { field.problems = problems }
        }
        if otherProblems != result.other { otherProblems = result.other }
        if hasSyntaxError != result.syntaxError { hasSyntaxError = result.syntaxError }
    }

    nonisolated private static func check(_ draft: ConfigText, path: String) -> Result {
        let text = draft.text
        let families = fontFamilies
        var result = Result()
        let found: [ConfigProblem]
        switch Config.load(path: path, fontFamilies: { families },
                           read: { $0 == path ? text : try? String(contentsOfFile: $0, encoding: .utf8) }) {
        case .success(let config): found = config.problems
        case .failure(let error):
            found = [error.problem]
            result.syntaxError = true
        }
        guard !found.isEmpty else { return result }
        let ranges = Config.settings.compactMap { setting in draft.lineRange(of: setting.path).map { (setting.id, $0) } }
        for problem in found {
            if let id = ranges.first(where: { $0.1.contains(problem.line) })?.0 {
                result.problems[id, default: []].append(problem)
            } else {
                result.other.append(problem)
            }
        }
        return result
    }
}
