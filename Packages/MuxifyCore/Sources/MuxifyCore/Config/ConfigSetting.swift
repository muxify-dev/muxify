import Foundation

/// A setting the Settings window lists: a key of the uncommented `Config.template` (ADR 0074).
public struct ConfigSetting: Identifiable, Equatable {
    public let path: [String]
    public var id: String { path.joined(separator: ".") }
    /// The comments about the key in the template.
    public let help: String
    /// The template's value as YAML text.
    public let templateValue: String
    /// The template's value is what the key gives when it is not set. Otherwise it is an example.
    public let isDefault: Bool
    /// The values the key takes, when they are a fixed list of words.
    public var choices: [String] = []

    /// A value of several lines: a list, or a mapping of the user's own keys.
    public var isBlock: Bool { templateValue.contains("\n") || templateValue.hasPrefix("- ") }
    public var isBool: Bool { templateValue == "true" || templateValue == "false" }
}

extension Config {
    /// The template without the `#` of its setting lines: YAML that sets every setting.
    public static var templateYAML: String {
        let lines = template.components(separatedBy: "\n")
        let start = lines.firstIndex { $0.range(of: #"^# [a-z_]+:"#, options: .regularExpression) != nil } ?? 0
        return lines[start...].map { line in
            line == "#" ? "" : line.hasPrefix("# ") ? String(line.dropFirst(2)) : line
        }.joined(separator: "\n")
    }

    /// Every setting of the template, in its order.
    public static let settings: [ConfigSetting] = settings(in: ConfigText(templateYAML), under: [])

    /// Reads `text` as a Config of its own. Every other file it names, such as a Config Override, is there and empty.
    static func probe(_ text: ConfigText) -> Config {
        (try? load(path: "/settings.yaml") { $0 == "/settings.yaml" ? text.text : "" }.get()) ?? Config()
    }

    private static func settings(in template: ConfigText, under path: [String]) -> [ConfigSetting] {
        template.children(of: path).flatMap { name, entry -> [ConfigSetting] in
            let keyPath = path + [name]
            var value = template.value(at: keyPath) ?? ""
            var help = help(of: entry, in: template)
            // Comments that open a block value are about the whole setting.
            var valueLines = value.components(separatedBy: "\n")
            while valueLines.count > 1, valueLines[0].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                help += (help.isEmpty ? "" : "\n") + valueLines.removeFirst().drop { $0 == " " || $0 == "#" }
            }
            value = valueLines.joined(separator: "\n")
            if entry.inline.isEmpty, let first = template.children(of: keyPath).first, isGroup(keyPath, sample: first.name,
                                                                                              in: template) {
                return settings(in: template, under: keyPath)
            }
            var alone = ConfigText("")
            alone.set(keyPath, to: value)
            let loaded = probe(alone)
            var setting = ConfigSetting(path: keyPath, help: help, templateValue: value,
                                        isDefault: loaded.problems.isEmpty && loaded == Config())
            if !setting.isBlock, !setting.isBool { setting.choices = choices(keyPath) }
            return [setting]
        }
    }

    /// The words the reader expects when the key has a value it does not take, if they are a fixed list.
    private static func choices(_ path: [String]) -> [String] {
        var probe = ConfigText("")
        probe.set(path, to: "zzprobe")
        return Self.probe(probe).problems.lazy.compactMap { ConfigSetting.expectedWords(in: $0.message) }.first ?? []
    }

    /// A mapping is a group of settings when the reader rejects a key it does not know there. A mapping of the user's
    /// own keys, such as `topics.tags`, takes any key.
    private static func isGroup(_ path: [String], sample: String, in template: ConfigText) -> Bool {
        var probe = ConfigText("")
        probe.set(path + ["zzprobe"], to: template.value(at: path + [sample]) ?? "")
        return Self.probe(probe).problems.contains { $0.message.contains("unknown") }
    }

    /// The comment lines right above the key, and a comment after its value.
    private static func help(of entry: ConfigText.Entry, in template: ConfigText) -> String {
        var lines: [String] = []
        var index = entry.line - 1
        while index >= 0 {
            let trimmed = template.lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { break }
            lines.insert(trimmed.dropFirst().trimmingCharacters(in: .whitespaces), at: 0)
            index -= 1
        }
        let line = template.lines[entry.line]
        if let key = ConfigText.key(of: line) {
            let inline = ConfigText.inlineValue(of: key.rest)
            let after = key.rest.trimmingCharacters(in: .whitespaces).dropFirst(inline.count)
                .trimmingCharacters(in: .whitespaces)
            if after.hasPrefix("#") { lines.append(after.dropFirst().trimmingCharacters(in: .whitespaces)) }
        }
        return lines.joined(separator: "\n")
    }
}
