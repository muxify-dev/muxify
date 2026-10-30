import Foundation

/// A project's Worktree setup: its `.worktree.json`, in the format of the user's `worktree` script, so one file
/// serves both. The file is JSON with `//` and `/* */` comments and trailing commas allowed. Unknown keys are
/// ignored; a known key of the wrong type fails the whole file, before Muxify changes anything.
public struct WorktreeSetup: Equatable, Sendable {
    public static let fileName = ".worktree.json"

    /// Replaces the root for this project: a new Worktree goes to `<worktreePath>/<name>`, with no repository folder.
    public var worktreePath: String?
    /// Paths relative to the checkout the setup came from, copied into the new Worktree.
    public var copyFiles: [String] = []
    /// Folders relative to that checkout, linked from the new Worktree.
    public var symlinkDirs: [String] = []
    /// A path here, or a folder above it, is neither copied nor linked.
    public var exclude: [String] = []
    /// Shell commands run one by one in the new Worktree, in its Session's first Window.
    public var postCreate: [String] = []
    /// Shell commands run one by one in the Worktree before Muxify removes it.
    public var preDelete: [String] = []

    public init(worktreePath: String? = nil, copyFiles: [String] = [], symlinkDirs: [String] = [], exclude: [String] = [],
                postCreate: [String] = [], preDelete: [String] = []) {
        self.worktreePath = worktreePath
        self.copyFiles = copyFiles
        self.symlinkDirs = symlinkDirs
        self.exclude = exclude
        self.postCreate = postCreate
        self.preDelete = preDelete
    }

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public let file: String
        public let reason: String
        public var description: String { "\(file) is not a valid Worktree setup: \(reason). Muxify made no Worktree." }
    }

    /// `file` names the file in the error.
    public static func parse(_ text: String, file: String) throws -> WorktreeSetup {
        let json = Data(strippingComments(text).utf8)
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: json) } catch {
            throw Invalid(file: file, reason: "it is not JSON")
        }
        guard let object = value as? [String: Any] else { throw Invalid(file: file, reason: "expected an object") }
        func section(_ key: String) throws -> [String: Any] {
            guard let value = object[key], !(value is NSNull) else { return [:] }
            guard let section = value as? [String: Any] else { throw Invalid(file: file, reason: "\(key): expected an object") }
            return section
        }
        func strings(_ section: [String: Any], _ name: String, _ key: String) throws -> [String] {
            guard let value = section[key], !(value is NSNull) else { return [] }
            guard let list = value as? [Any], let strings = list as? [String] else {
                throw Invalid(file: file, reason: "\(name).\(key): expected a list of strings")
            }
            return strings
        }
        var setup = WorktreeSetup()
        if let value = object["worktreePath"], !(value is NSNull) {
            guard let path = value as? String, !path.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Invalid(file: file, reason: "worktreePath: expected a path")
            }
            setup.worktreePath = path
        }
        let sync = try section("sync"), hooks = try section("hooks")
        setup.copyFiles = try strings(sync, "sync", "copyFiles")
        setup.symlinkDirs = try strings(sync, "sync", "symlinkDirs")
        setup.exclude = try strings(sync, "sync", "exclude")
        setup.postCreate = try strings(hooks, "hooks", "postCreate")
        setup.preDelete = try strings(hooks, "hooks", "preDelete")
        return setup
    }

    public func isExcluded(_ path: String) -> Bool {
        exclude.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// What the sync copies and links, in file order, without the excluded paths.
    public var syncItems: [SyncItem] {
        copyFiles.filter { !isExcluded($0) }.map { .copy($0) } + symlinkDirs.filter { !isExcluded($0) }.map { .link($0) }
    }

    public enum SyncItem: Equatable, Sendable {
        case copy(String)
        case link(String)
    }

    /// JSON from JSONC: comments go, then trailing commas. Strings stay as they are, so `"http://host"` keeps its
    /// slashes.
    static func strippingComments(_ text: String) -> String {
        removingTrailingCommas(scan(text) { scalars, index, output in
            guard scalars[index] == "/", index + 1 < scalars.count else { return nil }
            if scalars[index + 1] == "/" {
                var end = index
                while end < scalars.count, scalars[end] != "\n" { end += 1 }
                return end
            }
            guard scalars[index + 1] == "*" else { return nil }
            var end = index + 2
            while end + 1 < scalars.count, !(scalars[end] == "*" && scalars[end + 1] == "/") { end += 1 }
            output.append(" ")
            return min(end + 2, scalars.count)
        })
    }

    private static func removingTrailingCommas(_ text: String) -> String {
        scan(text) { scalars, index, _ in
            guard scalars[index] == "," else { return nil }
            var ahead = index + 1
            while ahead < scalars.count, scalars[ahead].properties.isWhitespace { ahead += 1 }
            return ahead < scalars.count && (scalars[ahead] == "}" || scalars[ahead] == "]") ? index + 1 : nil
        }
    }

    /// Copies `text`, and outside strings lets `skip` drop a span: it returns where the copy goes on, or nil to keep
    /// the character.
    private static func scan(_ text: String,
                             skip: ([Unicode.Scalar], Int, inout String.UnicodeScalarView) -> Int?) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        var inString = false
        while index < scalars.count {
            let scalar = scalars[index]
            if inString {
                output.append(scalar)
                if scalar == "\\", index + 1 < scalars.count {
                    output.append(scalars[index + 1])
                    index += 2
                    continue
                }
                if scalar == "\"" { inString = false }
                index += 1
            } else if let next = skip(scalars, index, &output) {
                index = next
            } else {
                if scalar == "\"" { inString = true }
                output.append(scalar)
                index += 1
            }
        }
        return String(output)
    }
}
