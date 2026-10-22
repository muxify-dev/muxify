import AppKit
import Observation
import UniformTypeIdentifiers
import MuxifyCore

/// The live Config. It loads the Ghostty config the Config names into
/// libghostty, applies the Browser section to every Tab, and when the Config or any Ghostty config file changes it
/// reads the Config again and reloads the Ghostty config.
@Observable
final class ConfigStore {
    let path: String
    private var loaded = LoadedConfig()
    /// The last Config that read without a syntax error.
    var config: Config { loaded.config }
    /// What the banner lists: the skipped values or the syntax error.
    var problems: [ConfigProblem] { loaded.problems }
    /// The user closed the problems banner. The next reload shows it again.
    var problemsDismissed = false

    @ObservationIgnored private var filesStamp = ""
    @ObservationIgnored private var watcher: Timer?

    init(path: String = MuxifyPaths().configFile.path) {
        self.path = path
        load()
    }

    /// Must run before any terminal is created.
    func start() {
        GhosttyRuntime.shared.start(ghosttyConfigFile: config.ghosttyConfigFile)
        filesStamp = stampFiles()
        watcher = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.stampFiles() != self.filesStamp else { return }
            self.reload()
        }
    }

    func reload() {
        load()
        problemsDismissed = false
        GhosttyRuntime.shared.reloadConfig(ghosttyConfigFile: config.ghosttyConfigFile)
        filesStamp = stampFiles()
    }

    /// Takes the SessionPaths found for `source`'s `sessions`, unless that section changed while they were found.
    func updateSessionPaths(_ sessionPaths: [SessionPath], foundFor source: Config) {
        guard config.sessionRoots == source.sessionRoots, config.sessionAliases == source.sessionAliases,
              config.sessionPaths != sessionPaths else { return }
        loaded.update(sessionPaths: sessionPaths)
    }

    /// Opens the Config in the app registered for YAML, or the plain-text
    /// editor, first writing a commented template when there is no Config yet.
    func openInEditor() {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Config.template.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("muxify: cannot create the Config at \(path): \(error)")
                return
            }
        }
        let workspace = NSWorkspace.shared
        guard let editor = workspace.urlForApplication(toOpen: url) ?? workspace.urlForApplication(toOpen: .plainText) else { return }
        workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    private func load() {
        loaded.update(with: Config.load(path: path, read: Self.readFile))
        for problem in loaded.problems { NSLog("muxify: config: \(problem)") }
        BrowserPageScripts.setVimKeys(config.browser.vimKeys)
    }

    /// Modification times of every file the Config or the Ghostty config can
    /// come from, including missing ones, so creating a file is a change too.
    private func stampFiles() -> String {
        let fm = FileManager.default
        let files = Set([path] + Self.ghosttyFiles(ghosttyConfigFile: config.ghosttyConfigFile))
        return files.sorted().map { path in
            let date = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            return "\(path)@\(date?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }

    /// The files libghostty reads: Ghostty's default files, the file the
    /// Config names, the files those include, and custom themes.
    private static func ghosttyFiles(ghosttyConfigFile: String?) -> [String] {
        let home = NSHomeDirectory()
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? "\(home)/.config"
        let directories = ["\(xdg)/ghostty", "\(home)/Library/Application Support/com.mitchellh.ghostty"]
        let roots = directories.flatMap { ["\($0)/config", "\($0)/config.ghostty"] } + (ghosttyConfigFile.map { [$0] } ?? [])
        var files = roots.flatMap { ConfigFileSet(root: $0, read: readFile).files }
        for directory in directories {
            let themes = "\(directory)/themes"
            files += [themes] + ((try? FileManager.default.contentsOfDirectory(atPath: themes)) ?? []).map { "\(themes)/\($0)" }
        }
        return files
    }

    private static func readFile(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}
