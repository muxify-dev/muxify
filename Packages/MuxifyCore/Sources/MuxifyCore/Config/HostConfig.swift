import Foundation

/// A Host's own Config as read on the Host (ADR 0010): the item of the Host Server's `config` subscription, and what
/// a Sessions-only link reads over its execs. The Mac parses `text` as it parses any remote Config.
public struct HostConfig: Codable, Equatable, Sendable {
    /// Where the Host's Config is, or would be, as an absolute path on the Host.
    public var path: String
    /// The Host's home, so the Mac shows `path` as `~/…` and resolves Override paths as the Host does.
    public var home: String
    /// The Config's YAML text; nil when the Host has no Config, and the Mac uses its local one.
    public var text: String?
    /// The Config Overrides that `text` names (ADR 0075), in list order, each with its text, or none when missing.
    public var overrides: [Override]

    /// One Config Override named by the Host's Config.
    public struct Override: Codable, Equatable, Sendable {
        /// As the Mac's remote Config names it after `host:`: `~/` for the Host's home, else absolute.
        public var path: String
        /// Nil when the file is missing.
        public var text: String?

        public init(path: String, text: String?) {
            self.path = path
            self.text = text
        }
    }

    public init(path: String, home: String, text: String?, overrides: [Override] = []) {
        self.path = path
        self.home = home
        self.text = text
        self.overrides = overrides
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        home = try values.decodeIfPresent(String.self, forKey: .home) ?? ""
        text = try values.decodeIfPresent(String.self, forKey: .text)
        overrides = try values.decodeIfPresent([Override].self, forKey: .overrides) ?? []
    }

    /// The Host has no Config.
    public var isMissing: Bool { text == nil }

    /// `path` as the Mac shows it after `host:`.
    public var shownPath: String { home.isEmpty ? path : Paths.tildify(path, home: home) }

    /// The Override paths that a Host's Config `text`, shown at `shownPath`, names, as `Config.load` resolves them for
    /// a remote Config without its `host:`. None when the text does not parse.
    public static func overridePaths(in text: String, shownPath: String) -> [String] {
        let host = "host:"
        let shown = host + shownPath
        guard case .success(let config) = Config.load(path: shown, isRemote: true, read: { $0 == shown ? text : nil }) else { return [] }
        var seen = Set<String>()
        return config.overrides.compactMap { path in
            guard path.hasPrefix(host) else { return nil }
            let named = String(path.dropFirst(host.count))
            return seen.insert(named).inserted ? named : nil
        }
    }

    /// Reads the Config at `path` and the Overrides it names, on this machine, whose home is `home`.
    public static func read(path: String, home: String,
                            read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> HostConfig {
        var config = HostConfig(path: path, home: home, text: read(path))
        if let text = config.text {
            config.overrides = overridePaths(in: text, shownPath: config.shownPath).map {
                Override(path: $0, text: read(expand($0, home: home)))
            }
        }
        return config
    }

    /// An Override path as this machine names it: `~/` is `home`.
    public static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }

    /// The folders a change to this Config shows in: the Config's and each Override's, or the nearest folder above
    /// each that exists, so creating the folder is a change too.
    public func watchedFolders(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Set<String> {
        let files = [path] + overrides.map { Self.expand($0.path, home: home) }
        return Set(files.map { file in
            var folder = (file as NSString).deletingLastPathComponent
            while !folder.isEmpty, folder != "/", !exists(folder) { folder = (folder as NSString).deletingLastPathComponent }
            return folder.isEmpty ? "/" : folder
        })
    }
}
