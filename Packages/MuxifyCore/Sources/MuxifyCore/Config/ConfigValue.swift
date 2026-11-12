import Foundation
import Yams

/// A setting's value as a tree, so the Settings window edits a list or a mapping with controls instead of YAML text
/// (ADR 0074).
public indirect enum ConfigValue: Equatable {
    case scalar(String)
    case list([ConfigValue])
    case map([Entry])

    public struct Entry: Equatable {
        public var key: String
        public var value: ConfigValue

        public init(key: String, value: ConfigValue) {
            self.key = key
            self.value = value
        }
    }

    /// Nil for text that is not YAML, or is empty.
    public init?(yaml: String) {
        guard let node = (try? Yams.compose(yaml: yaml)) ?? nil else { return nil }
        self.init(node)
    }

    init(_ node: Node) {
        switch node {
        case .mapping(let mapping): self = .map(mapping.map { Entry(key: $0.key.string ?? "", value: ConfigValue($0.value)) })
        case .sequence(let sequence): self = .list(sequence.map(ConfigValue.init))
        case .scalar(let scalar): self = .scalar(scalar.string)
        case .alias: self = .scalar("")
        }
    }

    /// YAML text, with a list of words on one line, as `[commands]`.
    public var yaml: String {
        ((try? Yams.serialize(node: node, allowUnicode: true)) ?? "").trimmingCharacters(in: .newlines)
    }

    private var node: Node {
        switch self {
        // Quoted when empty, so it stays a string and not a missing value.
        case .scalar(let string): .scalar(Node.Scalar(string, .implicit, string.isEmpty ? .singleQuoted : .any))
        case .list(let items):
            .sequence(Node.Sequence(items.map(\.node), .implicit, items.allSatisfy(\.isScalar) ? .flow : .block))
        case .map(let entries): .mapping(Node.Mapping(entries.map { (Node($0.key), $0.value.node) }, .implicit, .block))
        }
    }

    /// A mapping, or a list with an item that is not a scalar: it takes lines of its own.
    public var isNested: Bool {
        switch self {
        case .scalar: false
        case .map: true
        case .list(let items): !items.allSatisfy(\.isScalar)
        }
    }

    public var isScalar: Bool {
        if case .scalar = self { return true }
        return false
    }

    /// The same shape with nothing filled in: a model for a new item.
    public var blank: ConfigValue {
        switch self {
        case .scalar: .scalar("")
        case .list: .list([])
        case .map(let entries): .map(entries.map { Entry(key: $0.key, value: $0.value.blank) })
        }
    }

    /// This value with each key of `path` that a mapping lacks added as a copy of its first entry.
    func adding(_ path: [ConfigPath]) -> ConfigValue {
        guard let step = path.first else { return self }
        let rest = Array(path.dropFirst())
        switch (self, step) {
        case (.list(var items), .item(let index)) where items.indices.contains(index):
            items[index] = items[index].adding(rest)
            return .list(items)
        case (.map(var entries), .key(let key)):
            if let index = entries.firstIndex(where: { $0.key == key }) {
                entries[index].value = entries[index].value.adding(rest)
            } else if let first = entries.first {
                entries.append(Entry(key: key, value: first.value.adding(rest)))
            }
            return .map(entries)
        default: return self
        }
    }

    /// Whether every key of `path` is there.
    func has(_ path: [ConfigPath]) -> Bool {
        guard let step = path.first else { return true }
        switch (self, step) {
        case (.list(let items), .item(let index)): return items.indices.contains(index) && items[index].has(Array(path.dropFirst()))
        case (.map(let entries), .key(let key)): return entries.first { $0.key == key }?.value.has(Array(path.dropFirst())) ?? false
        default: return false
        }
    }

    /// The values at `path` in every item of each list on the way.
    func models(at path: [ConfigPath]) -> [ConfigValue] {
        guard let step = path.first else { return [self] }
        let rest = Array(path.dropFirst())
        switch (self, step) {
        case (.list(let items), .item): return items.flatMap { $0.models(at: rest) }
        case (.map(let entries), .key(let key)): return entries.first { $0.key == key }?.value.models(at: rest) ?? []
        default: return []
        }
    }

    /// The value at `path`. An item is the one it names, and a key a mapping does not have is its first entry: the
    /// template's model for any item or entry.
    func model(at path: [ConfigPath]) -> ConfigValue? {
        guard let step = path.first else { return self }
        switch (self, step) {
        case (.list(let items), .item(let index)):
            return items.indices.contains(index) ? items[index].model(at: Array(path.dropFirst())) : nil
        case (.map(let entries), .key(let key)):
            return (entries.first { $0.key == key } ?? entries.first)?.value.model(at: Array(path.dropFirst()))
        default: return nil
        }
    }

    /// This value with the one at `path` (found as in `model(at:)`) changed.
    func changing(at path: [ConfigPath], _ change: (ConfigValue) -> ConfigValue) -> ConfigValue {
        guard let step = path.first else { return change(self) }
        let rest = Array(path.dropFirst())
        switch (self, step) {
        case (.list(var items), .item(let index)) where items.indices.contains(index):
            items[index] = items[index].changing(at: rest, change)
            return .list(items)
        case (.map(var entries), .key(let key)) where !entries.isEmpty:
            let index = entries.firstIndex { $0.key == key } ?? 0
            entries[index].value = entries[index].value.changing(at: rest, change)
            return .map(entries)
        default: return self
        }
    }
}

/// A step into a setting's value.
public enum ConfigPath: Hashable {
    case item(Int)
    case key(String)
}

/// What a value inside a setting takes, found from the template and from the reader's problems.
public struct ConfigShape: Equatable {
    /// The template's value there: the model for a new item or entry.
    public var model: ConfigValue?
    /// The words a scalar, or each word of a list, takes, when they are a fixed list.
    public var choices: [String] = []
    /// The keys a mapping knows, for its Add menu. Empty when its keys are the user's own, as Tag names.
    public var keys: [String] = []
    public var userKeys = false
    /// A key trigger, such as `cmd+shift+p`.
    public var isTrigger = false
}

extension ConfigSetting {
    /// The setting's template value as a tree.
    public var templateTree: ConfigValue? { ConfigValue(yaml: templateValue) }

    /// What the value at `path` inside this setting takes. An item of a list is like the template's first item.
    public func shape(at path: [ConfigPath]) -> ConfigShape {
        let key = id + "|" + path.map { step in
            switch step {
            case .item: "[]"
            case .key(let name): "." + name
            }
        }.joined()
        if let cached = ConfigShapeCache.shapes[key] { return cached }
        let shape = findShape(at: path)
        ConfigShapeCache.shapes[key] = shape
        return shape
    }

    private func findShape(at path: [ConfigPath]) -> ConfigShape {
        guard let tree = templateTree else { return ConfigShape() }
        // A key the template does not have, as `move` in pick_lists or a Tag name of the user's own, goes in as a copy
        // of its first entry, so the probes ask the reader about that very key.
        let steps = resolve(path, in: tree)
        let template = tree.adding(steps)
        var shape = ConfigShape(model: template.model(at: steps))
        switch shape.model {
        case .scalar(let string)?:
            shape.isTrigger = string.contains("+") && (try? KeyTrigger(string)) != nil
            if string != "true" && string != "false" {
                shape.choices = probeChoices(template.changing(at: steps) { _ in .scalar("zzprobe") })
            }
        case .list(let items)?:
            if items.first?.isScalar == true {
                shape.choices = probeChoices(template.changing(at: steps + [.item(0)]) { _ in .scalar("zzprobe") })
            }
        case .map?:
            let entries = template.models(at: steps).flatMap { model -> [ConfigValue.Entry] in
                if case .map(let entries) = model { return entries }
                return []
            }
            let probe = template.changing(at: steps) { value in
                guard case .map(var entries) = value else { return value }
                entries.append(.init(key: "zzprobe", value: entries.first?.value ?? .scalar("x")))
                return .map(entries)
            }
            let problems = load(probe)
            if problems.contains(where: { $0.message.contains("unknown") }) {
                var keys = entries.map(\.key) + commentedKeys(of: entries.map(\.key))
                keys += problems.lazy.compactMap { Self.expectedWords(in: $0.message) }.first ?? []
                shape.keys = keys.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            } else {
                shape.userKeys = true
            }
        case nil: break
        }
        return shape
    }

    /// `path` in the template: an item is the first one that has the rest of the path.
    private func resolve(_ path: [ConfigPath], in template: ConfigValue) -> [ConfigPath] {
        guard let step = path.first else { return [] }
        let rest = Array(path.dropFirst())
        switch (template, step) {
        case (.list(let items), .item):
            let index = items.indices.first { items[$0].has(rest) } ?? 0
            return [.item(index)] + (items.indices.contains(index) ? resolve(rest, in: items[index]) : rest)
        case (.map(let entries), .key(let key)):
            guard let entry = entries.first(where: { $0.key == key }) ?? entries.first else { return path }
            return [.key(key)] + resolve(rest, in: entry.value)
        default: return path
        }
    }

    /// The keys a template comments out next to `keys`, such as `# port: 22` in a Remote Environment.
    private func commentedKeys(of keys: [String]) -> [String] {
        // The template's lines of this setting, with the comments after its last value.
        let template = ConfigText(Config.templateYAML)
        guard let first = keys.first, let entry = template.find(path) else { return [] }
        let lines = template.lines[(entry.line + 1)...].prefix { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty || ConfigText.indent(line) > entry.indent
        }
        guard let line = lines.first(where: { $0.range(of: "^[ -]*\(first):", options: .regularExpression) != nil }) else { return [] }
        let indent = line.prefix { $0 == " " || $0 == "-" }.count
        return lines.compactMap { line in
            guard let match = line.range(of: "^ {\(indent)}# ([a-z_]+):", options: .regularExpression) else { return nil }
            return String(line[match].dropFirst(indent + 2).dropLast())
        }
    }

    private func load(_ value: ConfigValue) -> [ConfigProblem] {
        var text = ConfigText("")
        text.set(path, to: value.yaml, block: true)
        return Config.probe(text).problems
    }

    private func probeChoices(_ value: ConfigValue) -> [String] {
        load(value).lazy.compactMap { Self.expectedWords(in: $0.message) }.first ?? []
    }

    /// The words of a problem that ends `expected a, b or c`. Nil when the list holds anything else, as `a boolean`.
    static func expectedWords(in message: String) -> [String]? {
        guard let range = message.range(of: "expected ", options: .backwards) else { return nil }
        let words = message[range.upperBound...].replacingOccurrences(of: " or ", with: ", ").components(separatedBy: ", ")
        guard !words.isEmpty,
              words.allSatisfy({ $0.range(of: #"^[a-z0-9_%-]+$"#, options: .regularExpression) != nil }) else { return nil }
        return words
    }
}

/// The Settings window asks for shapes on the main thread only.
private enum ConfigShapeCache {
    nonisolated(unsafe) static var shapes: [String: ConfigShape] = [:]
}
