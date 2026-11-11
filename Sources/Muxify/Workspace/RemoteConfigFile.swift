import Foundation
import MuxifyCore

/// Reads a Remote Environment's own Config file over the SSH master (ADR 0010).
enum RemoteConfigFile {
    /// Prints the file's path, then `present` and its text, or `missing`.
    static let script = """
    file=${XDG_CONFIG_HOME:-$HOME/.config}/muxify/config.yaml
    printf '%s\\n' "$file"
    if [ -f "$file" ]; then
        printf 'present\\n'
        cat "$file"
    else
        printf 'missing\\n'
    fi
    """

    /// The file's path, and its text when it exists.
    static func parse(_ output: String) -> (path: String, text: String?)? {
        let lines = output.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count >= 2, !lines[0].isEmpty else { return nil }
        switch lines[1] {
        case "present": return (String(lines[0]), lines.count > 2 ? String(lines[2]) : "")
        case "missing": return (String(lines[0]), nil)
        default: return nil
        }
    }

    /// Takes an end line, then each Config Override's path on the remote. A
    /// path that starts with `~/` starts at the remote home. For each, prints
    /// `present` and its text, or `missing`, then a newline and the end line.
    static let overridesScript = """
    end=$1
    shift
    for file in "$@"; do
        case $file in
            "~/"*) file=$HOME/${file#"~/"} ;;
        esac
        if [ -f "$file" ]; then
            printf 'present\\n'
            cat "$file" || exit 1
        else
            printf 'missing\\n'
        fi
        printf '\\n%s\\n' "$end"
    done
    """

    /// The arguments of `overridesScript`.
    static func overridesArguments(_ paths: [String], end: String) -> [String] {
        [end] + paths
    }

    /// Each of `paths` to its text, or to nil when it is missing; nil when the
    /// output is not one block per path.
    static func parseOverrides(_ output: String, paths: [String], end: String) -> [String: String?]? {
        var blocks = output.components(separatedBy: "\n\(end)\n")
        guard blocks.last == "" else { return nil }
        blocks.removeLast()
        guard blocks.count == paths.count else { return nil }
        var texts: [String: String?] = [:]
        for (path, block) in zip(paths, blocks) {
            if block == "missing\n" {
                texts[path] = .some(nil)
            } else if block.hasPrefix("present\n") {
                texts[path] = String(block.dropFirst("present\n".count))
            } else {
                return nil
            }
        }
        return texts
    }

    /// The remote Config `text`, shown as `shown`, with its Config Overrides
    /// merged on top (ADR 0075). `overrides` holds the texts read on the
    /// remote, by shown path; one that is not there is missing.
    static func load(_ text: String, shown: String, overrides: [String: String?] = [:]) -> Result<Config, ConfigSyntaxError> {
        Config.load(path: shown, isRemote: true) { $0 == shown ? text : overrides[$0] ?? nil }
    }
}
