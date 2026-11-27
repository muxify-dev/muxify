import Foundation
import Darwin
import MuxifyCore

/// One foreground, prompt-owning SSH master and its master-only channels.
/// No helper or listening port is installed on the remote machine.
final class RemoteSSH {
    let environment: RemoteEnvironment
    let directory: URL
    let nonce: String
    private let sshExecutable: String
    private var ownsDirectory = false
    var socketPath: String { directory.appendingPathComponent("s").path }
    var markerOption: String { ClientMarker.option(nonce: nonce) }
    private var exitFile: URL { directory.appendingPathComponent("exit") }
    private var errorFile: URL { directory.appendingPathComponent("stderr") }
    private var snapshotFile: URL { directory.appendingPathComponent("snapshot") }

    init(environment: RemoteEnvironment, temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         sshExecutable: String = "/usr/bin/ssh") throws {
        self.environment = environment
        self.sshExecutable = sshExecutable
        nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        directory = temporaryDirectory.appendingPathComponent("mx-\(nonce.prefix(10))")
        guard directory.appendingPathComponent("s").path.utf8.count < 104 else {
            throw TmuxError.failed(status: 1, stderr: "Temporary directory path is too long for an SSH control socket")
        }
        // Exclusive creation: never reuse or later remove a directory that
        // existed before this connection, even if a random name collides.
        guard directory.path.withCString({ mkdir($0, 0o700) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        ownsDirectory = true
    }

    private var options: [String] {
        var args = [
            "-l", environment.username, environment.forwardAgent ? "-A" : "-a",
            "-o", "ControlPath=\(socketPath)",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
            "-o", "StrictHostKeyChecking=ask", "-o", "ForwardX11=no",
            "-o", "RemoteCommand=none",
            "-o", "ForkAfterAuthentication=no",
            "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
        ]
        if let port = environment.port { args += ["-p", String(port)] }
        if let key = environment.identityFile { args += ["-i", key, "-o", "IdentitiesOnly=yes"] }
        return args
    }

    func control(_ operation: String) -> CommandInvocation {
        CommandInvocation(executable: sshExecutable, arguments: options + ["-O", operation, "--", environment.host])
    }

    /// BatchMode alone is insufficient: ssh otherwise falls back to a new
    /// connection if the master disappears. The failing proxy closes that race.
    func command(_ args: [String]) -> CommandInvocation {
        var checks = ""
        if args != ["show-option", "-sqv", markerOption] {
            // A server restart must not turn queued IDs into commands against
            // a new server. This nonce belongs only to our attachment/server.
            checks = """
            marker=$(tmux -u show-option -sqv \(Tmux.shellQuote(markerOption))) || exit $?
            if [ -z "$marker" ]; then echo 'Muxify: remote tmux attachment is no longer available.' >&2; exit 75; fi
            """
            if ["switch-client", "display-message"].contains(args.first ?? ""),
               let index = args.firstIndex(of: "-c"), args.indices.contains(index + 1) {
                checks += """

                expected=${marker%%\(Tmux.separator)*}
                actual=$(tmux -u list-clients -F '#{client_tty} #{client_pid}' | while IFS= read -r line; do
                    tty=${line% *}
                    pid=${line##* }
                    if [ "$tty" = \(Tmux.shellQuote(args[index + 1])) ]; then printf '%s' "$pid"; break; fi
                done)
                if [ "$actual" != "$expected" ]; then echo 'Muxify: remote tmux client changed.' >&2; exit 75; fi
                """
            }
        }
        let tmux = "tmux -u " + args.map(Tmux.shellQuote).joined(separator: " ")
        let script: String
        if args.first == "-C" {
            // The Listener attaches with no target and `TmuxEvents` moves it to the Session that the marked Client,
            // the Terminal's, shows; it makes no Session. The SSH master, and so the Terminal, waits for every channel
            // over it. It ends itself once the attachment's marker is gone, which the bootstrap clears
            // when its Client ends. The control client reads the channel's input, saved before `&` replaces it.
            script = Self.remotePath + "\n" + checks + """

            exec 3<&0
            \(tmux) <&3 &
            listener=$!
            exec 3<&-
            while kill -0 "$listener" 2>/dev/null; do
                sleep 1
                if [ -z "$(tmux -u show-option -sqv \(Tmux.shellQuote(markerOption)) 2>/dev/null)" ]; then
                    kill -HUP "$listener" 2>/dev/null
                    break
                fi
            done
            wait "$listener"
            """
        } else {
            script = Self.remotePath + "\n" + checks + "\nexec " + tmux
        }
        return CommandInvocation(executable: sshExecutable, arguments: options + [
            "-T", "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ProxyCommand=/usr/bin/false",
            "--", environment.host, "exec /bin/sh -c " + Tmux.shellQuote(script),
        ])
    }

    /// Runs `script` with /bin/sh on the remote machine, over the master like
    /// tmux commands, with `arguments` as its positional parameters.
    func script(_ script: String, arguments: [String] = []) -> CommandInvocation {
        let words = [Self.remotePath + "\n" + script, "muxify"] + arguments
        return CommandInvocation(executable: sshExecutable, arguments: options + [
            "-T", "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ProxyCommand=/usr/bin/false",
            "--", environment.host, "exec /bin/sh -c " + words.map(Tmux.shellQuote).joined(separator: " "),
        ])
    }

    /// The Host Server, `muxify server`, as a channel of the master like the execs (ADR 0088):
    /// it never signs in on its own and never outlives the master. Its stdin and stdout are the protocol's.
    /// `executable` is the Debug app's own upload; nil finds the Host CLI.
    func serverInvocation(executable: String? = nil) -> CommandInvocation {
        script(Self.findHostCLI(at: executable) + "\nexec \"$muxify\" server")
    }

    /// `findHostCLI`, or `executable` when there is one: the Debug app's own upload, which exits 127 too when it is
    /// gone.
    static func findHostCLI(at executable: String?) -> String {
        guard let executable else { return findHostCLI }
        return """
        muxify=\(Tmux.shellQuote(executable))
        [ -x "$muxify" ] || { echo "muxify: $muxify is not there" >&2; exit 127; }
        """
    }

    /// Finds the Host CLI as the install and the phone do: on the PATH, in `~/.local/bin`, then, on a Mac only,
    /// Muxify.app's own. Exits 127 with no line on stdout when there is none.
    static let findHostCLI = """
    bundle=\(Tmux.shellQuote(HostCLI.appBundleCLI))
    if muxify=$(command -v muxify 2>/dev/null) && [ -x "$muxify" ]; then :
    elif [ -x "$HOME/.local/bin/muxify" ]; then muxify=$HOME/.local/bin/muxify
    elif [ "$(uname -s)" = Darwin ] && [ -x "$bundle" ]; then muxify=$bundle
    else echo 'muxify: the Host CLI is not installed' >&2; exit 127
    fi
    """

    /// Prints the first line of the Host CLI's `--version`, for the reason a window gives when that CLI has no
    /// server mode. An old CLI prints nothing.
    static func hostCLIVersionScript(at executable: String? = nil) -> String {
        findHostCLI(at: executable) + "\n\"$muxify\" --version 2>/dev/null | head -n 1"
    }

    /// The Session that Start a Session… starts on the remote machine: its name, and its folder there.
    struct NewSession: Equatable {
        let name: String
        let folder: String
    }

    func terminalCommand(target: String? = nil, picksLatestSession: Bool = true, newSession: NewSession? = nil,
                         hidesStatusLine: Bool = false) -> String {
        terminalInvocation(target: target, picksLatestSession: picksLatestSession, newSession: newSession,
                           hidesStatusLine: hidesStatusLine).commandLine
    }

    func terminalInvocation(target: String? = nil, picksLatestSession: Bool = true, newSession: NewSession? = nil,
                            hidesStatusLine: Bool = false) -> CommandInvocation {
        let ssh = attachmentInvocation(target: target, picksLatestSession: picksLatestSession, newSession: newSession,
                                       hidesStatusLine: hidesStatusLine)
        // Stream stdout unchanged to the terminal (fd 3). SSH's remote PTY
        // merges remote stderr into stdout, so retain only a bounded tail in
        // memory and save just the nonce-framed final snapshot on exit.
        // Both pipelines finish before Ghostty reports the child closed.
        // Prompts still read /dev/tty; save SSH's status, not tee/login's status.
        let script = """
        export SSH_ASKPASS_REQUIRE=never
        export TERM="${TERM:-xterm-256color}"
        exec 3>&1
        {
            {
                \(ssh.commandLine) 2>&1 >&4
                printf '%s\\n' "$?" > \(Tmux.shellQuote(exitFile.path))
            } | /usr/bin/tee \(Tmux.shellQuote(errorFile.path)) >&2
        } 4>&1 | /usr/bin/tee /dev/fd/3 | /usr/bin/tail -c 1048576 | /usr/bin/tr -d '\\r' | /usr/bin/sed -n \(Tmux.shellQuote("/^\(snapshotStart)$/,/^\(snapshotEnd)$/p")) > \(Tmux.shellQuote(snapshotFile.path))
        status=$(cat \(Tmux.shellQuote(exitFile.path)))
        exit "${status:-255}"
        """
        return CommandInvocation(executable: "/bin/bash", arguments: ["-c", script])
    }

    /// Reads the normal SSH config, including Host aliases and IdentityAgent
    /// (e.g. 1Password). Only our session/socket lifecycle and safety settings
    /// override it; background channels still cannot independently authenticate.
    func attachmentInvocation(target: String? = nil, picksLatestSession: Bool = true, newSession: NewSession? = nil,
                              hidesStatusLine: Bool = false) -> CommandInvocation {
        CommandInvocation(executable: sshExecutable, arguments: options + [
            "-tt", "-M", "-o", "ControlPersist=no",
            "--", environment.host,
            "exec /bin/sh -c " + Tmux.shellQuote(bootstrap(target: target, picksLatestSession: picksLatestSession, newSession: newSession,
                                                           hidesStatusLine: hidesStatusLine)),
        ])
    }

    private var snapshotStart: String { "Muxify snapshot \(nonce)" }
    private var snapshotEnd: String { "Muxify snapshot end \(nonce)" }

    /// The connection's script on the remote machine. With no Session of the user's there, it starts none by itself
    /// (Start a Session… chooses the folder): it reports the empty server and exits, unless `newSession` names the
    /// Session to go to, or to start in its folder. Without a `target`, `picksLatestSession` attaches to the Session
    /// with the latest activity, else to the first Window.
    /// `hidesStatusLine`: the Client lists itself as a Muxify Terminal and sets the hooks that hide tmux's status line
    /// before it attaches, so no frame shows it (`TmuxStatusLine`, ADR 0104).
    func bootstrap(target: String? = nil, picksLatestSession: Bool = true, newSession: NewSession? = nil,
                   hidesStatusLine: Bool = false) -> String {
        let targetSetup = target.map { "target=\(Tmux.shellQuote($0))" }
            ?? (newSession == nil ? nil : "target=\"$new_session\"")
            ?? "target=$(tmux -u show-options -gqv \(Tmux.shellQuote(Tmux.lastWindowOption)) 2>/dev/null)"
        let snapshotCommand = "tmux -u " + Tmux.snapshotArguments.map(Tmux.shellQuote).joined(separator: " ")
        // An unsupported DCS is ignored by the renderer, so the handoff does
        // not flash raw Session/Browser records in the terminal before exit.
        // The records go in hex: Ghostty takes any byte 0x80-0x9F as a C1
        // control even inside a DCS, and UTF-8 such as ␟ or ✳ holds those
        // bytes, so plain text would end the DCS and print the rest.
        let report = """
        report() {
            printf '\\033Pmuxify;\\n%s\\n' \(Tmux.shellQuote(snapshotStart)) >&2
            od -An -v -tx1 | tr -d ' ' >&2
            printf '%s\\n\\033\\\\' \(Tmux.shellQuote(snapshotEnd)) >&2
        }
        """
        let reportSnapshot = """
        if snapshot=$(\(snapshotCommand) 2>/dev/null); then
            reports=$(printf '%s\\n' "$snapshot" | /bin/sh -c \(Tmux.shellQuote(Tmux.codexReportsForInventoryScript)))
            printf '%s\\n%s\\n%s\\n' "${HOME}\(Tmux.separator)$(uname -n)" "$snapshot" "$reports" | report
        elif absence=$(tmux -u has-session 2>&1); then
            :
        else
            case "$absence" in
                *"no server running"*|*"no sessions"*|*"error connecting"*"No such file or directory"*)
                    printf '%s\\nempty\\n' "${HOME}\(Tmux.separator)$(uname -n)" | report ;;
            esac
        fi
        """
        let sessionSetup = newSession.map { session in
            let shape = Tmux.shellQuote("#{session_id}:#{window_id}")
            return """
            new_session=$(tmux -u list-windows -t \(Tmux.shellQuote("=" + session.name)) -F \(shape) 2>/dev/null | head -n 1)
            if [ -z "$new_session" ]; then
                new_session=$(tmux -u new-session -d -s \(Tmux.shellQuote(session.name)) -c \(Tmux.shellQuote(session.folder)) -P -F \(shape)) || exit $?
            fi
            """
        } ?? """
        if ! tmux -u list-sessions -F . 2>/dev/null | grep -q .; then
            \(reportSnapshot)
            exit 0
        fi
        """
        // A child owns the tmux client PID recorded in the marker. Its parent
        // remains on the same foreground SSH/PTY to report inventory on exit.
        // no-detach-on-destroy (tmux 3.6+; older tmux ignores it): when the Client's Session ends, tmux moves the
        // Client to the most recent Session left, so the connection stays instead of reconnecting.
        let attachment = """
        marker="$$\(Tmux.separator)$1\(Tmux.separator)${HOME}\(Tmux.separator)$(uname -n)\(Tmux.separator)remote"
        tmux -u set-option -sq \(Tmux.shellQuote(markerOption)) "$marker" || exit $?
        \(hidesStatusLine ? TmuxStatusLine.attachSetup(tmux: "tmux -u") : ":")
        if [ -n "$2" ]; then
            exec tmux -u -T RGB attach-session -f no-detach-on-destroy -t "$2"
        else
            exec tmux -u -T RGB attach-session -f no-detach-on-destroy
        fi
        """
        return """
        \(Self.remotePath)
        unset TMUX TMUX_PANE
        \(report)
        if ! command -v tmux >/dev/null 2>&1; then
            echo 'Muxify: tmux was not found on the remote machine.' >&2
            exit 127
        fi
        version=$(tmux -u -V)
        version=${version#tmux }
        major=${version%%.*}
        minor=${version#*.}
        minor=${minor%%[!0-9]*}
        case "$major:$minor" in *[!0-9:]*|:*) echo 'Muxify: could not determine the remote tmux version.' >&2; exit 2;; esac
        if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "${minor:-0}" -lt 2 ]; }; then
            echo 'Muxify: remote tmux 3.2 or newer is required.' >&2
            exit 2
        fi
        # SSH carries Ghostty's TERM with the PTY. Keep it when the remote
        # terminfo knows it; do not require installing an entry or infocmp.
        if [ -z "${TERM:-}" ] || ! command -v infocmp >/dev/null 2>&1 || ! infocmp "$TERM" >/dev/null 2>&1; then
            TERM=xterm-256color
        fi
        # Set this here rather than relying on the SSH server's AcceptEnv.
        export TERM COLORTERM=truecolor MUXIFY_TERMINAL=1
        # An earlier Muxify's Listener sat in a Session of its own; it goes, so it neither counts nor gets the Terminal.
        tmux -u kill-session -t \(Tmux.shellQuote("=" + EnvironmentPublisher.leftoverWatchSession)) 2>/dev/null
        \(sessionSetup)
        \(targetSetup)
        if [ -n "$target" ] && ! tmux -u list-panes -t "$target" >/dev/null 2>&1; then target=; fi
        \(picksLatestSession
            ? "if [ -z \"$target\" ]; then target=$(tmux -u list-sessions -F '#{session_activity} #{session_id}' | sort -rn | head -n 1 | cut -d ' ' -f 2); fi"
            : "if [ -z \"$target\" ]; then target=$(tmux -u list-windows -a -F '#{session_id}:#{window_id}' | head -n 1); fi")
        # Some SSH servers (including OrbStack) omit SSH_TTY despite -tt.
        client_tty=${SSH_TTY:-$(tty)}
        case "$client_tty" in
            /dev/*) ;;
            *) echo 'Muxify: the remote SSH connection did not provide a terminal.' >&2; exit 2;;
        esac
        # Our renderer supports RGB even if the fallback terminfo does not.
        # Advertise it for this client only, without rewriting server options.
        /bin/sh -c \(Tmux.shellQuote(attachment)) muxify "$client_tty" "$target"
        status=$?
        # The SSH master stays until every channel over it closes. Clearing the marker ends them: the listener ends
        # itself, and the Mac closes the Host Server's channel once the server says its Client is gone.
        tmux -u set-option -su \(Tmux.shellQuote(markerOption)) 2>/dev/null
        \(reportSnapshot)
        exit "$status"
        """
    }

    private static let remotePath = "unset TMUX TMUX_PANE\nPATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin\"; export PATH"

    var exitStatus: Int? {
        (try? String(contentsOf: exitFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var failureMessage: String {
        let text = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map(String.init)
        return lines.suffix(4).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Accept only a complete report from a cleanly exited foreground owner.
    /// A transport/authentication failure is never evidence of an empty server.
    var closedSnapshot: TmuxSnapshot? {
        guard exitStatus == 0, let text = try? String(contentsOf: snapshotFile, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.lastIndex(of: snapshotStart),
              let end = lines[(start + 1)...].firstIndex(of: snapshotEnd),
              let decoded = Self.text(hex: lines[(start + 1)..<end].joined()) else { return nil }
        var records = decoded.components(separatedBy: "\n")
        if records.last == "" { records.removeLast() }
        guard records.count >= 2 else { return nil }
        let metadata = records[0].components(separatedBy: Tmux.separator)
        guard metadata.count == 2 else { return nil }
        let payload = records[1...].joined(separator: "\n")
        var snapshot = payload == "empty"
            ? TmuxSnapshot(windows: [], clients: [], panes: [], lastWindowID: nil, serverRunning: false)
            : Tmux.parseSnapshot(payload)
        guard payload == "empty" || snapshot.serverID != nil else { return nil }
        snapshot.stampHost(home: metadata[0], hostName: metadata[1])
        return snapshot
    }

    /// The text that `od -An -v -tx1` wrote as hex digits, or nil when they are not whole bytes of UTF-8.
    static func text(hex: String) -> String? {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = hexValue(digits[index]), let low = hexValue(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func hexValue(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    var shouldReconnect: Bool {
        guard exitStatus == 255 else { return false }
        let error = failureMessage.lowercased()
        // Authentication/setup failures require user action; reconnecting may
        // otherwise repeatedly ask for a passphrase or host-key approval.
        if ["permission denied", "host key verification failed", "host identification has changed",
                 "no such identity", "unprotected private key", "too many authentication failures",
                 "muxify: tmux", "muxify: remote tmux", "muxify: could not determine"].contains(where: error.contains) { return false }
        // A cancelled verification/passphrase prompt can also exit 255.
        // Only transport failures should automatically acquire another master.
        return ["connection reset", "connection refused", "timed out", "broken pipe", "no route to host",
                "network is unreachable", "network is down", "not responding", "could not resolve hostname"]
            .contains(where: error.contains) || (error.contains("connection") && error.contains("closed"))
    }

    func cleanup() {
        guard ownsDirectory else { return }
        ownsDirectory = false
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { cleanup() }
}
