import Foundation
import MuxifyCore

/// What the Host CLI install chain leaves for the Host Server (ADR 0084, "Which binary serves").
struct HostCLIReady: Equatable, Sendable {
    /// The chain's result line: the reason a window gives when no `muxify` is found after it (chain D).
    let line: String
    /// The Debug app's own upload, which the server runs from; nil finds the Host CLI as the phone does.
    var server: String?
}

/// Scripts on the Host over the owned master, one of them with a local file as its stdin, as
/// `TerminalAttachments.uploadScript` takes a dropped file.
protocol HostScripts: ScriptRunning {
    func runScript(_ script: String, arguments: [String], timeout: TimeInterval, inputFile: URL?) throws -> String
}

extension TmuxConnection: HostScripts {}

/// A Debug app's own Host CLI build: `build/host-cli/` in its stamped source root, used only when that folder's
/// `version` names the sha stamped into the app. Uncommitted changes are the developer's to keep in step. The app
/// never builds it: the Linux cross-compile takes minutes.
struct DebugHostCLI: Equatable, Sendable {
    let folder: URL
    let sha: String

    /// The build in `sourceRoot` that matches the app's `build` line; nil without a source root, without the
    /// folder's `version`, or when that names another sha.
    static func matching(sourceRoot: String?, build: String) -> DebugHostCLI? {
        guard let sourceRoot, let sha = sha(of: build) else { return nil }
        let folder = URL(fileURLWithPath: sourceRoot, isDirectory: true).appendingPathComponent("build/host-cli", isDirectory: true)
        guard let text = try? String(contentsOf: folder.appendingPathComponent("version"), encoding: .utf8),
              let first = text.split(separator: "\n", omittingEmptySubsequences: false).first,
              Self.sha(of: String(first)) == sha else { return nil }
        return DebugHostCLI(folder: folder, sha: sha)
    }

    /// This app's, read on each connect: a `make host-cli` after launch counts.
    static var app: DebugHostCLI? { matching(sourceRoot: AppBuild.sourceRoot, build: AppBuild.line) }

    /// The sha of a `muxify <sha> <time>` line, which names a file on the Host: hex only, so never `dev`.
    static func sha(of line: String) -> String? {
        guard let sha = HostCLI.version(line)?.sha, sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return sha
    }
}

/// The Host CLI install chain, run once per connect before the Host Server starts (ADR 0084): a Debug app's own
/// build when it has one; else A, the Host downloads `cli-latest` itself (ADR 0076); else B, when the Host cannot
/// download, the Mac fetches the Host's asset from the same base and streams it gzipped over the master into
/// `~/.local/bin/muxify`. When nothing is installed, the server's channel exits 127 and the window shows Sessions
/// only with the chain's line (chain D). The chain never stops a running server: an install's `mv` leaves it on
/// its old inode.
enum HostCLIChain {
    /// How long one upload may take over a slow master.
    static let uploadTimeout: TimeInterval = 120

    /// Runs the chain on the calling thread and reports each step as `Host CLI: <Environment>: <line>`.
    static func run(over scripts: any HostScripts, environmentName: String, baseURL: String, debug: DebugHostCLI?,
                    report: (String) -> Void) -> HostCLIReady {
        func say(_ line: String) { report("Host CLI: \(environmentName): \(line)") }
        if let debug {
            do {
                let path = try upload(debug, over: scripts)
                say("the Debug build \(debug.sha) serves from \(path)")
                return HostCLIReady(line: "the Debug build \(debug.sha)", server: path)
            } catch {
                say("the Debug build \(debug.sha) was not uploaded: \(error)")
            }
        }
        let host = HostCLI.run(over: scripts, baseURL: baseURL)
        say(host)
        guard HostCLI.hostCannotDownload(host) else { return HostCLIReady(line: host) }
        let mac = send(over: scripts, baseURL: baseURL)
        say("from the Mac: \(mac)")
        return HostCLIReady(line: mac.hasPrefix("failed:") ? "\(host); from the Mac: \(mac)" : mac)
    }

    // MARK: Chain B

    /// The Host's platform as `muxify-<os>-<arch>`, then the first line of its Host CLI's `--version`, if any.
    static let probeScript = """
    printf 'muxify-%s-%s\\n' "$(uname -s | tr '[:upper:]' '[:lower:]')" "$(uname -m)"
    (
    \(RemoteSSH.hostCLIVersionScript())
    ) 2>/dev/null || :
    """

    /// Unpacks the gzipped upload on stdin into `~/.local/bin/muxify` with the install's own temp name and atomic
    /// `mv`, after the new file prints `$1`, the published version line. It prints one line and exits 0.
    static let installScript = """
    set -f
    dir=$HOME/.local/bin
    target=$dir/muxify
    new=$dir/muxify.new.$$
    nl='
    '
    result() {
        printf '%s\\n' "$1"
        exit 0
    }
    command -v gzip >/dev/null 2>&1 || result "failed: no gzip on the Host"
    mkdir -p "$dir" 2>/dev/null || result "failed: cannot create $dir"
    trap 'rm -f "$new"' EXIT
    trap 'exit 1' HUP INT TERM
    gzip -dc >"$new" 2>/dev/null || result "failed: cannot unpack the upload into $new"
    chmod +x "$new" 2>/dev/null || result "failed: cannot make $new executable"
    out=$("$new" --version 2>/dev/null) || out=
    [ "${out%%"$nl"*}" = "$1" ] || result "failed: the upload prints '${out%%"$nl"*}', not '$1'"
    mv -f "$new" "$target" 2>/dev/null || result "failed: cannot move $new to $target"
    result "uploaded ${1#muxify } to $target"
    """

    /// Chain B: the Mac fetches `version` and the Host's asset from `baseURL` and sends the asset when it is newer
    /// than the Host's own, as the install would have. Its result line, `failed:` when it could not.
    static func send(over scripts: any HostScripts, baseURL: String) -> String {
        do {
            let probe = try scripts.runScript(probeScript, arguments: [], timeout: HostCLI.timeout)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let asset = probe.first ?? ""
            guard HostCLI.assets.contains(asset) else { return "failed: no Host CLI for \(asset)" }
            let line = String(decoding: try fetch(baseURL + "version"), as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard let published = HostCLI.version(line) else { return "failed: \(baseURL)version holds no version: \(line)" }
            if probe.count > 1, let installed = HostCLI.version(probe[1]) {
                if installed.time > published.time {
                    return "kept \(installed.sha) \(installed.time) (newer than \(published.sha) \(published.time))"
                }
                if installed.time == published.time { return "current \(installed.sha) \(installed.time)" }
            }
            return try withTemporaryDirectory { directory in
                let binary = directory.appendingPathComponent(asset)
                try fetch(baseURL + asset).write(to: binary)
                return try scripts.runScript(installScript, arguments: [line], timeout: uploadTimeout,
                                             inputFile: try gzipped(binary, into: directory))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            return "failed: \(error)"
        }
    }

    // MARK: The Debug app's own build

    /// Unpacks the gzipped upload on stdin into `muxify-$1` in the Debug builds' own folder, never `~/.local/bin`,
    /// keeps the three newest files there and prints the new file's path. A running server keeps its inode, so
    /// removing its file is safe.
    static let debugUploadScript = """
    set -f
    dir=$HOME/.local/share/muxify/server
    target=$dir/muxify-$1
    new=$dir/.muxify-$1.new.$$
    command -v gzip >/dev/null 2>&1 || { echo 'no gzip on the Host' >&2; exit 1; }
    mkdir -p "$dir" || exit 1
    trap 'rm -f "$new"' EXIT
    trap 'exit 1' HUP INT TERM
    gzip -dc >"$new" && chmod +x "$new" && mv -f "$new" "$target" || exit 1
    ls -t "$dir" | tail -n +4 | while IFS= read -r old; do rm -f "$dir/$old"; done
    printf '%s\\n' "$target"
    """

    /// Uploads the Debug build for the Host's platform and returns its path there.
    static func upload(_ debug: DebugHostCLI, over scripts: any HostScripts) throws -> String {
        let asset = try scripts.runScript(probeScript, arguments: [], timeout: HostCLI.timeout)
            .split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let binary = debug.folder.appendingPathComponent(asset)
        guard HostCLI.assets.contains(asset), FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw ChainError("\(debug.folder.path) has no \(asset)")
        }
        let path = try withTemporaryDirectory { directory in
            try scripts.runScript(debugUploadScript, arguments: [debug.sha], timeout: uploadTimeout,
                                  inputFile: try gzipped(binary, into: directory))
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\n") else { throw ChainError("the upload printed '\(path)'") }
        return path
    }

    // MARK: Helpers

    struct ChainError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// The file gzipped into `directory`.
    private static func gzipped(_ file: URL, into directory: URL) throws -> URL {
        let packed = directory.appendingPathComponent(file.lastPathComponent + ".gz")
        _ = try CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: [
            "-c", "/usr/bin/gzip -c <\"$1\" >\"$2\"", "gzip", file.path, packed.path,
        ]), timeout: 60)
        return packed
    }

    /// Runs `body` with a new private directory, which it then removes.
    private static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-host-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// The body at `url`, which may be a `file://` URL as tests serve, within `HostCLI.timeout`.
    static func fetch(_ url: String) throws -> Data {
        guard let address = URL(string: url) else { throw ChainError("cannot fetch \(url)") }
        if address.isFileURL {
            do { return try Data(contentsOf: address) } catch { throw ChainError("cannot fetch \(url)") }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = HostCLI.timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        let result = Fetched()
        session.dataTask(with: address) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, error == nil, (200..<300).contains(status) { result.data = data }
            done.signal()
        }.resume()
        done.wait()
        guard let data = result.data else { throw ChainError("cannot fetch \(url)") }
        return data
    }

    private final class Fetched: @unchecked Sendable {
        var data: Data?
    }
}
