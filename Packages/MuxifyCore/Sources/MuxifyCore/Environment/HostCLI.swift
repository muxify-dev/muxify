import Foundation

/// The Host CLI: the `muxify` that a Remote Environment's machine keeps in `~/.local/bin`, installed and updated from
/// the rolling `cli-latest` GitHub prerelease each time the Environment connects (ADR 0076).
public enum HostCLI {
    public static let defaultBaseURL = "https://github.com/muxify-dev/muxify/releases/download/cli-latest/"
    /// Where Muxify.app keeps its own `muxify`, the last place the phone looks.
    public static let appBundleCLI = "/Applications/Muxify.app/Contents/Resources/bin/muxify"
    /// The download is a few megabytes; a slow Host still finishes, a stuck one gives up.
    public static let timeout: TimeInterval = 60

    /// `MUXIFY_CLI_BASE_URL` when it is set, so a test serves its own build; else the release's.
    public static func baseURL(environment: [String: String]) -> String {
        environment["MUXIFY_CLI_BASE_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL
    }

    /// The install, `host-cli-install.sh` in this package's resources, in POSIX `sh` so that the phone runs the same
    /// text: `make host-cli` publishes the file as the `install.sh` asset. `$1` is the base URL, ending in `/`; `$2`,
    /// for tests, replaces `appBundleCLI`. It looks `muxify` up as the phone does (the bundle only on a Mac), leaves
    /// one inside an app bundle alone, and downloads `muxify-<os>-<arch>` over `~/.local/bin/muxify` when none is
    /// found, when the found one's `--version` fails, or when the published commit time is later. A newer one is
    /// never replaced. It prints one line, `installed`, `updated`, `current`, `kept`, `skipped:` or `failed:`, and
    /// exits 0.
    public static let script: String = {
        guard let url = Bundle.module.url(forResource: "host-cli-install", withExtension: "sh"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "echo 'failed: host-cli-install.sh is missing from MuxifyCore'"
        }
        return text
    }()

    /// Runs the install on the Environment's machine, off the calling thread, and gives `report` its result line
    /// or its error, as `Host CLI: <Environment>: <line>`. Nothing waits for it, and nothing it finds changes the
    /// connection.
    public static func install(over scripts: any ScriptRunning, environmentName: String, baseURL: String,
                               report: @escaping @Sendable (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let line: String
            do {
                let output = try scripts.runScript(script, arguments: [baseURL], timeout: timeout)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                line = output.isEmpty ? "failed: the install printed nothing" : output
            } catch {
                line = "failed: \(error)"
            }
            report("Host CLI: \(environmentName): \(line)")
        }
    }
}
