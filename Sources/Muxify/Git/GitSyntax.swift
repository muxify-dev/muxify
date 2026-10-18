import Foundation
import MuxifyCore

/// What a piece of code is, for basic syntax highlighting.
enum SyntaxToken: Equatable {
    case keyword, type, string, number, comment, attribute, key
}

/// A comment or string still open at the end of a line.
struct SyntaxState: Equatable {
    fileprivate var closing: [UInt16]?
    fileprivate var token = SyntaxToken.comment
}

/// Enough of a language to color its keywords, types, strings, numbers and
/// comments line by line. Not a parser: a diff shows lines out of context
/// anyway.
struct SyntaxLanguage {
    var keywords: Set<String> = []
    var keywordsIgnoreCase = false
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)?
    var quotes: Set<UInt16> = [Self.doubleQuote]
    /// Strings that may span lines, like Swift's and Python's `"""`.
    var multilineQuotes: [String] = []
    /// Capitalized names are types, as in Swift, Go or Java.
    var capitalizedTypes = true
    /// `@name` (and `$name` in a shell) is an attribute, decorator or variable.
    var attributePrefixes: Set<UInt16> = [Self.at]
    /// `#if` and `#include` at the start of a line.
    var preprocessor = false
    /// A name or string before one of these is a key, as in YAML and JSON.
    var keySeparators: Set<UInt16> = []
    /// Characters besides letters, digits and `_` allowed in names.
    var nameExtras: Set<UInt16> = []
    /// `<tag` and `</tag` in HTML and XML.
    var tags = false
    /// Markdown's `# Heading` lines.
    var headings = false

    /// By the file's extension or name; nil for files shown without colors.
    static func forPath(_ path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        if let language = byName[name] { return language }
        return byExtension[ext]
    }

    // MARK: Tokens

    /// The colored ranges of `line`, from `start`. Overlong lines, such as
    /// minified code, stay plain.
    func tokens(in line: [UInt16], from start: Int = 0, state: inout SyntaxState) -> [(range: NSRange, token: SyntaxToken)] {
        var result: [(range: NSRange, token: SyntaxToken)] = []
        let count = line.count
        guard count - start <= 1_000 else { return [] }
        func add(_ from: Int, _ to: Int, _ token: SyntaxToken) {
            if to > from { result.append((NSRange(location: from, length: to - from), token)) }
        }
        var index = start
        if let closing = state.closing {
            let (end, found) = Self.find(closing, in: line, from: index)
            add(index, end, state.token)
            if !found { return result }
            state.closing = nil
            index = end
        }
        let firstWord = line[index...].firstIndex { $0 != Self.space && $0 != Self.tab } ?? count
        if headings, firstWord < count, line[firstWord] == Self.hash {
            add(firstWord, count, .keyword)
            return result
        }
        if preprocessor, firstWord < count, line[firstWord] == Self.hash {
            var end = firstWord + 1
            while end < count, Self.isNameCharacter(line[end]) { end += 1 }
            add(firstWord, end, .attribute)
            index = end
        }
        while index < count {
            let character = line[index]
            if character == Self.space || character == Self.tab {
                index += 1
                continue
            }
            if lineComments.contains(where: { Self.matches($0, in: line, at: index) }) {
                add(index, count, .comment)
                return result
            }
            if let (open, close) = blockComment, Self.matches(open, in: line, at: index) {
                let closing = Array(close.utf16)
                let (end, found) = Self.find(closing, in: line, from: index + open.utf16.count)
                add(index, end, .comment)
                if !found {
                    state = SyntaxState(closing: closing, token: .comment)
                    return result
                }
                index = end
                continue
            }
            if let quote = multilineQuotes.first(where: { Self.matches($0, in: line, at: index) }) {
                let closing = Array(quote.utf16)
                let (end, found) = Self.find(closing, in: line, from: index + closing.count)
                add(index, end, .string)
                if !found {
                    state = SyntaxState(closing: closing, token: .string)
                    return result
                }
                index = end
                continue
            }
            if quotes.contains(character) {
                var end = index + 1
                while end < count {
                    if line[end] == Self.backslash { end += 2; continue }
                    end += 1
                    if line[end - 1] == character { break }
                }
                end = min(end, count)
                add(index, end, isKey(before: end, in: line) ? .key : .string)
                index = end
                continue
            }
            if Self.isDigit(character), index == 0 || !isName(line[index - 1]) {
                var end = index + 1
                while end < count, Self.isNameCharacter(line[end]) || line[end] == Self.dot { end += 1 }
                add(index, end, .number)
                index = end
                continue
            }
            if attributePrefixes.contains(character), index + 1 < count, Self.isNameStart(line[index + 1]) {
                var end = index + 2
                while end < count, isName(line[end]) { end += 1 }
                add(index, end, .attribute)
                index = end
                continue
            }
            if tags, character == Self.less {
                var nameStart = index + 1
                if nameStart < count, line[nameStart] == Self.slash { nameStart += 1 }
                var end = nameStart
                while end < count, isName(line[end]) || line[end] == Self.colon { end += 1 }
                add(nameStart, end, .keyword)
                index = max(end, index + 1)
                continue
            }
            if Self.isNameStart(character) {
                var end = index + 1
                while end < count, isName(line[end]) { end += 1 }
                let word = String(decoding: line[index..<end], as: UTF16.self)
                if keywords.contains(keywordsIgnoreCase ? word.lowercased() : word) {
                    add(index, end, .keyword)
                } else if isKey(before: end, in: line) {
                    add(index, end, .key)
                } else if capitalizedTypes, Self.isUppercase(character) {
                    add(index, end, .type)
                }
                index = end
                continue
            }
            index += 1
        }
        return result
    }

    private func isName(_ character: UInt16) -> Bool {
        Self.isNameCharacter(character) || nameExtras.contains(character)
    }

    private func isKey(before end: Int, in line: [UInt16]) -> Bool {
        guard !keySeparators.isEmpty else { return false }
        var next = end
        while next < line.count, line[next] == Self.space { next += 1 }
        return next < line.count && keySeparators.contains(line[next])
    }

    private static func matches(_ text: String, in line: [UInt16], at index: Int) -> Bool {
        var position = index
        for unit in text.utf16 {
            guard position < line.count, line[position] == unit else { return false }
            position += 1
        }
        return true
    }

    /// Where `closing` ends, or the end of the line when it isn't there.
    private static func find(_ closing: [UInt16], in line: [UInt16], from start: Int) -> (end: Int, found: Bool) {
        var index = start
        while index + closing.count <= line.count {
            if line[index] == backslash, closing.first != backslash { index += 2; continue }
            if Array(line[index..<index + closing.count]) == closing { return (index + closing.count, true) }
            index += 1
        }
        return (line.count, false)
    }

    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isUppercase(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
    private static func isNameStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
    private static func isNameCharacter(_ c: UInt16) -> Bool { isNameStart(c) || isDigit(c) }

    static let space: UInt16 = 32, tab: UInt16 = 9, hash: UInt16 = 35, backslash: UInt16 = 92, dot: UInt16 = 46
    static let doubleQuote: UInt16 = 34, singleQuote: UInt16 = 39, backtick: UInt16 = 96, at: UInt16 = 64
    static let dollar: UInt16 = 36, less: UInt16 = 60, slash: UInt16 = 47, colon: UInt16 = 58, equals: UInt16 = 61, dash: UInt16 = 45

    // MARK: Languages

    private static func words(_ list: String) -> Set<String> {
        Set(list.split(separator: " ").map(String.init))
    }

    static let swift = SyntaxLanguage(
        keywords: words("""
        actor any as associatedtype async await break case catch class continue convenience default defer deinit do \
        dynamic else enum extension fallthrough false fileprivate final for func get guard if import in indirect init \
        inout internal is lazy let mutating nil nonisolated nonmutating open operator override private protocol public \
        repeat required rethrows return self Self set some static struct subscript super switch throw throws true try \
        typealias unowned var weak where while willSet didSet
        """),
        lineComments: ["//"], blockComment: ("/*", "*/"), multilineQuotes: ["\"\"\""], preprocessor: true
    )

    static let cFamily = SyntaxLanguage(
        keywords: words("""
        auto bool break case catch char class const constexpr continue default delete do double else enum explicit \
        extern false float for friend goto if inline int long namespace new noexcept nullptr NULL operator private \
        protected public register return short signed sizeof static struct switch template this throw true try typedef \
        typename union unsigned using virtual void volatile while self super nil YES NO id instancetype
        """),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: [doubleQuote, singleQuote], preprocessor: true
    )

    static let javaScript = SyntaxLanguage(
        keywords: words("""
        abstract as async await break case catch class const constructor continue debugger declare default delete do \
        else enum export extends false finally for from function get if implements import in instanceof interface \
        keyof let namespace new null of private protected public readonly return set static super switch this throw \
        true try type typeof undefined var void while with yield
        """),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: [doubleQuote, singleQuote, backtick]
    )

    static let jvm = SyntaxLanguage(
        keywords: words("""
        abstract as assert async await boolean break byte case catch char class companion const continue data default \
        do double else enum extends false final finally float for fun if implements import in instanceof int interface \
        internal is lateinit long namespace new null object open override package private protected public readonly \
        return sealed short static string super suspend switch synchronized this throw throws true try using val var \
        void volatile when while
        """),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: [doubleQuote, singleQuote], multilineQuotes: ["\"\"\""]
    )

    static let go = SyntaxLanguage(
        keywords: words("""
        break case chan const continue default defer else fallthrough false for func go goto if import interface iota \
        map nil package range return select struct switch true type var
        """),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: [doubleQuote, singleQuote, backtick]
    )

    static let rust = SyntaxLanguage(
        keywords: words("""
        as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move \
        mut pub ref return self Self static struct super trait true type unsafe use where while
        """),
        lineComments: ["//"], blockComment: ("/*", "*/"), attributePrefixes: [hash]
    )

    static let python = SyntaxLanguage(
        keywords: words("""
        and as assert async await break case class continue def del elif else except False finally for from global if \
        import in is lambda match None nonlocal not or pass raise return self True try while with yield
        """),
        lineComments: ["#"], quotes: [doubleQuote, singleQuote], multilineQuotes: ["\"\"\"", "'''"]
    )

    static let ruby = SyntaxLanguage(
        keywords: words("""
        alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or \
        private protected public redo require rescue retry return self super then true undef unless until when while yield
        """),
        lineComments: ["#"], quotes: [doubleQuote, singleQuote]
    )

    static let shell = SyntaxLanguage(
        keywords: words("""
        alias begin break case continue declare do done elif else end esac exit export fi for function if in local \
        readonly return set shift source then trap unset until while
        """),
        lineComments: ["#"], quotes: [doubleQuote, singleQuote], capitalizedTypes: false, attributePrefixes: [dollar]
    )

    static let yaml = SyntaxLanguage(
        keywords: words("true false null yes no on off"),
        lineComments: ["#"], quotes: [doubleQuote, singleQuote], capitalizedTypes: false, attributePrefixes: [],
        keySeparators: [colon], nameExtras: [dash, dot]
    )

    static let toml = SyntaxLanguage(
        keywords: words("true false"),
        lineComments: ["#", ";"], quotes: [doubleQuote, singleQuote], multilineQuotes: ["\"\"\""],
        capitalizedTypes: false, attributePrefixes: [], keySeparators: [equals], nameExtras: [dash, dot]
    )

    static let json = SyntaxLanguage(
        keywords: words("true false null"), lineComments: ["//"], capitalizedTypes: false, attributePrefixes: [],
        keySeparators: [colon]
    )

    static let markup = SyntaxLanguage(
        blockComment: ("<!--", "-->"), quotes: [doubleQuote, singleQuote], capitalizedTypes: false,
        attributePrefixes: [], nameExtras: [dash], tags: true
    )

    static let css = SyntaxLanguage(
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: [doubleQuote, singleQuote], capitalizedTypes: false,
        attributePrefixes: [at, dollar], keySeparators: [colon], nameExtras: [dash]
    )

    static let markdown = SyntaxLanguage(quotes: [backtick], capitalizedTypes: false, attributePrefixes: [], headings: true)

    static let sql = SyntaxLanguage(
        keywords: words("""
        add all alter and as asc begin by case check column commit constraint create default delete desc distinct drop \
        else end exists foreign from group having if in index inner insert into is join key left like limit not null on \
        or order outer primary references returning right rollback select set table then union unique update using \
        values view when where with
        """),
        keywordsIgnoreCase: true, lineComments: ["--"], blockComment: ("/*", "*/"), quotes: [doubleQuote, singleQuote],
        capitalizedTypes: false
    )

    static let lua = SyntaxLanguage(
        keywords: words("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"),
        lineComments: ["--"], blockComment: ("--[[", "]]"), quotes: [doubleQuote, singleQuote], capitalizedTypes: false
    )

    static let make = SyntaxLanguage(
        keywords: words("ifeq ifneq ifdef ifndef else endif include define endef export"),
        lineComments: ["#"], quotes: [doubleQuote, singleQuote], capitalizedTypes: false, attributePrefixes: [dollar]
    )

    static let dockerfile = SyntaxLanguage(
        keywords: words("FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS"),
        lineComments: ["#"], quotes: [doubleQuote, singleQuote], capitalizedTypes: false, attributePrefixes: [dollar]
    )

    private static let byExtension: [String: SyntaxLanguage] = {
        var table: [String: SyntaxLanguage] = [:]
        let groups: [(SyntaxLanguage, String)] = [
            (swift, "swift"),
            (cFamily, "c h cc cpp cxx hpp hh hxx m mm metal"),
            (javaScript, "js jsx mjs cjs ts tsx mts cts vue svelte php"),
            (jvm, "java kt kts scala cs dart groovy gradle"),
            (go, "go"),
            (rust, "rs"),
            (python, "py pyi"),
            (ruby, "rb rake gemspec podspec"),
            (shell, "sh bash zsh fish ksh"),
            (yaml, "yml yaml"),
            (toml, "toml ini cfg conf editorconfig gitconfig properties"),
            (json, "json jsonc json5"),
            (markup, "html htm xml plist svg xib storyboard entitlements"),
            (css, "css scss sass less"),
            (markdown, "md markdown"),
            (sql, "sql"),
            (lua, "lua"),
            (make, "mk"),
        ]
        for (language, extensions) in groups {
            for ext in extensions.split(separator: " ") { table[String(ext)] = language }
        }
        return table
    }()

    private static let byName: [String: SyntaxLanguage] = [
        "Makefile": make, "makefile": make, "GNUmakefile": make,
        "Dockerfile": dockerfile, "Containerfile": dockerfile,
        "Gemfile": ruby, "Rakefile": ruby, "Podfile": ruby, "Fastfile": ruby, "Brewfile": ruby,
        ".zshrc": shell, ".bashrc": shell, ".profile": shell, ".zprofile": shell, ".bash_profile": shell,
        ".gitignore": shell, ".gitconfig": toml,
    ]
}
