import AppKit
import MuxifyCore

/// Muxify ▸ Install Command Line Tool: links the `muxify` executable bundled at
/// `Contents/Resources/bin/muxify` into `~/.local/bin`. Panes of a tmux server
/// that Muxify starts already find it on the PATH that `AppEnvironment` sets;
/// the link is for other terminals, scripts, and servers started before Muxify.
enum CommandLineToolInstaller {
    static func run() {
        let (failed, text) = install()
        let alert = NSAlert()
        alert.messageText = failed ? "Couldn't install the command line tool" : "Command line tool installed"
        alert.informativeText = text
        alert.alertStyle = failed ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func install() -> (failed: Bool, text: String) {
        let fm = FileManager.default
        guard let tool = Bundle.main.resourceURL?.appendingPathComponent("bin/muxify"),
              fm.isExecutableFile(atPath: tool.path)
        else {
            return (true, "The tool is missing from the app bundle (Contents/Resources/bin/muxify).")
        }
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
        let link = dir.appendingPathComponent("muxify")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Replace our own earlier link (e.g. to an older build), never a real file.
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                return (true, "\(Paths.tildify(link.path)) already exists and isn't a link. Remove it and try again.")
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: tool)
        } catch {
            return (true, error.localizedDescription)
        }
        return (false, "\(Paths.tildify(link.path)) → \(Paths.tildify(tool.path))\n\nAny shell with ~/.local/bin on its PATH can now run muxify.")
    }
}
