import AppKit
import MuxifyCore

/// Muxify ▸ Install Extensions: runs the installer bundled at
/// `Contents/Resources/extensions/install.sh`, which installs or updates the
/// bundled Extension of every Agent whose config directory exists, then shows
/// what it printed.
enum ExtensionInstaller {
    static func run() {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("extensions/install.sh"),
              FileManager.default.fileExists(atPath: script.path)
        else {
            showAlert(failed: true, text: "The installer is missing from the app bundle (Contents/Resources/extensions/install.sh).")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let (failed, text) = execute(script)
            DispatchQueue.main.async { showAlert(failed: failed, text: text) }
        }
    }

    /// Runs the installer with the app's own environment: `HOME`, and the
    /// `PATH` that `AppEnvironment.prepare()` extended with Homebrew so the
    /// installer finds `jq`. Returns whether it failed and the text to show.
    private static func execute(_ script: URL) -> (failed: Bool, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let exit: ProcessExit
        do {
            exit = try process.start()
        } catch {
            return (true, "Couldn't run the installer: \(error.localizedDescription)")
        }
        let out = trimmed(stdout.fileHandleForReading.readDataToEndOfFile())
        let err = trimmed(stderr.fileHandleForReading.readDataToEndOfFile())
        exit.wait()

        guard process.terminationStatus == 0 else {
            // The per-Agent lines say which Agent failed and why; stderr has
            // anything the installer's tools complained about.
            let parts = [out, err].filter { !$0.isEmpty }
            let detail = parts.isEmpty ? "The installer exited with status \(process.terminationStatus)." : parts.joined(separator: "\n\n")
            return (true, detail)
        }
        return (false, out.isEmpty ? "The installer printed nothing." : out)
    }

    private static func trimmed(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func showAlert(failed: Bool, text: String) {
        let alert = NSAlert()
        alert.messageText = failed ? "Couldn't install Extensions" : "Extensions installed"
        alert.informativeText = text
        alert.alertStyle = failed ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
