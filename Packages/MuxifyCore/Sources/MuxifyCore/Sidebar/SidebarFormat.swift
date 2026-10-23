import Foundation

/// A parsed plain-text Format. Config owns parsing; rendering only evaluates the expression tree.
public struct SidebarFormat: Equatable {
    public enum Variable: String, CaseIterable {
        case topic_title, topic_pinned_flag, topic_dormant_flag, topic_tags, tag_count, tag
        case session_count, window_count, pane_count, agent_count, agents_working, agents_unread
        case session_name, session_base_name, branch
        case window_index, window_name, window_title, window_panes, window_zoomed_flag, tab_count
        case pane_index, pane_label, pane_title, pane_current_command, pane_current_path, pane_active_flag
        case agent_kind, agent_status, agent_unread_flag, agent_group
        case loop_index, loop_first_flag, loop_last_flag
    }

    public enum Loop: String { case sessions = "S", windows = "W", panes = "P", tags = "T" }

    public struct Context {
        public var values: [Variable: String]
        public var loops: [Loop: [Context]]

        public init(values: [Variable: String] = [:], loops: [Loop: [Context]] = [:]) {
            self.values = values
            self.loops = loops
        }

        /// Each child of `loop`, with its place in the loop.
        fileprivate func children(of loop: Loop) -> [Context] {
            let children = loops[loop] ?? []
            return children.enumerated().map { index, child in
                var child = child
                child.values[.loop_index] = String(index)
                child.values[.loop_first_flag] = index == 0 ? "1" : "0"
                child.values[.loop_last_flag] = index == children.count - 1 ? "1" : "0"
                return child
            }
        }
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    fileprivate indirect enum Scalar: Equatable {
        case text(String)
        case variable(Variable)
        case sequence([Scalar])
        case conditional(Scalar, Scalar, Scalar)
        case equal(Scalar, Scalar, negated: Bool)
        case truncate(Int, Scalar)
        case basename(Scalar)
        case loop(Loop, Scalar)

        func evaluate(_ context: Context) -> String {
            switch self {
            case .text(let text): return text
            case .variable(let variable): return context.values[variable] ?? ""
            case .sequence(let parts): return parts.map { $0.evaluate(context) }.joined()
            case .conditional(let condition, let yes, let no):
                let value = condition.evaluate(context)
                return (value.isEmpty || value == "0" ? no : yes).evaluate(context)
            case .equal(let left, let right, let negated):
                return (left.evaluate(context) == right.evaluate(context)) != negated ? "1" : "0"
            case .truncate(let count, let expression):
                let value = expression.evaluate(context)
                return count >= 0 ? String(value.prefix(count)) : String(value.suffix(-count))
            case .basename(let expression):
                let value = expression.evaluate(context)
                return value.split(separator: "/").last.map(String.init) ?? value
            case .loop(let loop, let expression):
                return context.children(of: loop).map(expression.evaluate).joined()
            }
        }

        /// One item for each pass of a `T` loop, with the Tag's place in the loop. Text outside a `T` loop gives no item.
        func tagItems(_ context: Context) -> [SidebarTagsFormat.Item] {
            switch self {
            case .text, .variable, .equal, .truncate, .basename: return []
            case .sequence(let parts): return parts.flatMap { $0.tagItems(context) }
            case .conditional(let condition, let yes, let no):
                let value = condition.evaluate(context)
                return (value.isEmpty || value == "0" ? no : yes).tagItems(context)
            case .loop(.tags, let body):
                return context.children(of: .tags).enumerated().map { SidebarTagsFormat.Item(index: $0.offset, text: body.evaluate($0.element)) }
            case .loop(let loop, let body):
                return context.children(of: loop).flatMap(body.tagItems)
            }
        }
    }

    fileprivate indirect enum Expression: Equatable {
        case scalar(Scalar)
        case currentAppIcon
        case symbol(String)
        case sequence([Expression])
        case conditional(Scalar, Expression, Expression)
        case loop(Loop, Expression)

        func scalar() throws -> Scalar {
            switch self {
            case .scalar(let value): return value
            case .sequence(let parts): return try .sequence(parts.map { try $0.scalar() })
            case .conditional(let condition, let yes, let no):
                return try .conditional(condition, yes.scalar(), no.scalar())
            case .loop(let loop, let body): return try .loop(loop, body.scalar())
            case .currentAppIcon, .symbol:
                throw Failure(description: "icons are allowed only in Window left and right output, not in text operands")
            }
        }

        func evaluate(_ context: Context) -> [SidebarPart] {
            switch self {
            case .scalar(let value): return [.text(value.evaluate(context))]
            case .currentAppIcon: return [.currentAppIcon]
            case .symbol(let name): return [.symbol(name)]
            case .sequence(let parts): return parts.flatMap { $0.evaluate(context) }
            case .conditional(let condition, let yes, let no):
                let value = condition.evaluate(context)
                return (value.isEmpty || value == "0" ? no : yes).evaluate(context)
            case .loop(let loop, let body):
                return context.children(of: loop).flatMap(body.evaluate)
            }
        }

        var symbolNames: [String] {
            switch self {
            case .symbol(let name): return [name]
            case .sequence(let parts): return parts.flatMap(\.symbolNames)
            case .conditional(_, let yes, let no): return yes.symbolNames + no.symbolNames
            case .loop(_, let body): return body.symbolNames
            case .scalar, .currentAppIcon: return []
            }
        }
    }

    public let source: String
    private let expression: Scalar

    public init(_ source: String) throws {
        self.source = source
        expression = try Parser.parse(source).scalar()
    }

    public func expand(in context: Context) -> String { expression.evaluate(context) }

    fileprivate enum Parser {
        static func parse(_ source: String, depth: Int = 0) throws -> Expression {
            guard depth < 64 else { throw Failure(description: "Format nesting is too deep") }
            let chars = Array(source)
            var index = 0
            var text = ""
            var parts: [Expression] = []
            while index < chars.count {
                guard chars[index] == "#", index + 1 < chars.count else {
                    text.append(chars[index]); index += 1; continue
                }
                switch chars[index + 1] {
                case "[": throw Failure(description: "#[ is reserved for styles")
                case ",", "#", "}":
                    text.append(chars[index + 1]); index += 2
                case "{":
                    if !text.isEmpty { parts.append(.scalar(.text(text))); text = "" }
                    let start = index + 2
                    index = start
                    var nesting = 1
                    while index < chars.count {
                        if chars[index] == "#", index + 1 < chars.count {
                            if chars[index + 1] == "{" { nesting += 1 }
                            if ["{", "#", ",", "}"].contains(chars[index + 1]) { index += 2; continue }
                        }
                        if chars[index] == "}" {
                            nesting -= 1
                            if nesting == 0 { break }
                        }
                        index += 1
                    }
                    guard nesting == 0 else { throw Failure(description: "unclosed #{") }
                    parts.append(try inner(String(chars[start..<index]), depth: depth + 1))
                    index += 1
                default:
                    text.append(chars[index]); index += 1
                }
            }
            if !text.isEmpty { parts.append(.scalar(.text(text))) }
            return .sequence(parts)
        }

        static func value(_ source: String, depth: Int) throws -> Expression {
            if source.contains("#{") { return try parse(source, depth: depth) }
            let name = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let variable = Variable(rawValue: name) else {
                throw Failure(description: "unknown variable \"\(name)\"")
            }
            return .scalar(.variable(variable))
        }

        static func inner(_ source: String, depth: Int) throws -> Expression {
            if source == "current_app_icon" { return .currentAppIcon }
            if source.hasPrefix("symbol:") {
                let name = String(source.dropFirst(7))
                guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }) else {
                    throw Failure(description: "symbol needs a literal SF Symbol name")
                }
                return .symbol(name)
            }
            if source.hasPrefix("?") {
                let parts = split(String(source.dropFirst()))
                guard parts.count == 3 else { throw Failure(description: "conditional needs condition, yes and no") }
                return try .conditional(value(parts[0], depth: depth).scalar(), parse(parts[1], depth: depth), parse(parts[2], depth: depth))
            }
            if source.hasPrefix("==:") || source.hasPrefix("!=:") {
                let parts = split(String(source.dropFirst(3)))
                guard parts.count == 2 else { throw Failure(description: "comparison needs two operands") }
                return try .scalar(.equal(parse(parts[0], depth: depth).scalar(), parse(parts[1], depth: depth).scalar(), negated: source.hasPrefix("!")))
            }
            if source.hasPrefix("="), let colon = source.firstIndex(of: ":") {
                guard let count = Int(source[source.index(after: source.startIndex)..<colon]), count != Int.min else {
                    throw Failure(description: "truncation needs a character count")
                }
                return try .scalar(.truncate(count, value(String(source[source.index(after: colon)...]), depth: depth).scalar()))
            }
            if source.hasPrefix("b:") { return try .scalar(.basename(value(String(source.dropFirst(2)), depth: depth).scalar())) }
            if source.count >= 2, source.dropFirst().first == ":", let loop = Loop(rawValue: String(source.prefix(1))) {
                return try .loop(loop, parse(String(source.dropFirst(2)), depth: depth))
            }
            return try value(source, depth: depth)
        }

        static func split(_ source: String) -> [String] {
            let chars = Array(source)
            var parts: [String] = []
            var start = 0
            var index = 0
            var depth = 0
            while index < chars.count {
                if chars[index] == "#", index + 1 < chars.count {
                    if chars[index + 1] == "{" { depth += 1 }
                    if ["{", "#", ",", "}"].contains(chars[index + 1]) { index += 2; continue }
                }
                if chars[index] == "}" { depth -= 1 }
                if chars[index] == ",", depth == 0 {
                    parts.append(String(chars[start..<index])); start = index + 1
                }
                index += 1
            }
            parts.append(String(chars[start...]))
            return parts
        }
    }
}

public enum SidebarPart: Equatable {
    case text(String)
    case currentAppIcon
    case symbol(String)
}

/// A Window part Format keeps images separate from expanded variable text.
public struct SidebarPartFormat: Equatable {
    public let source: String
    private let expression: SidebarFormat.Expression

    public init(_ source: String) throws {
        self.source = source
        expression = try SidebarFormat.Parser.parse(source)
    }

    var symbolNames: [String] { expression.symbolNames }

    public func expand(in context: SidebarFormat.Context) -> [SidebarPart] {
        var result: [SidebarPart] = []
        for part in expression.evaluate(context) {
            if case .text(let text) = part {
                guard !text.isEmpty else { continue }
                if case .text(let previous) = result.last {
                    result[result.count - 1] = .text(previous + text)
                    continue
                }
            }
            result.append(part)
        }
        return result
    }
}

/// `sidebar.formats.topic.tags`: what each Tag of a Topic card says. Each pass of the `T` loop is one Tag Mark's
/// hover text or one chip; Muxify draws the "+N" itself, so the Format stays the same in every `tag_placement`.
public struct SidebarTagsFormat: Equatable {
    /// `index` is the Tag's place among the Topic's Tags, in the order of the `T` loop.
    public struct Item: Equatable {
        public let index: Int
        public let text: String
    }

    public let source: String
    private let expression: SidebarFormat.Scalar

    public init(_ source: String) throws {
        self.source = source
        expression = try SidebarFormat.Parser.parse(source).scalar()
    }

    /// An item with no text shows no Tag, so a Format can leave out some Tags.
    public func items(in context: SidebarFormat.Context) -> [Item] {
        expression.tagItems(context).filter { !$0.text.isEmpty }
    }
}
