import AppKit
import MuxifyCore

/// An immutable snapshot of a user-initiated image/file paste. Promised
/// screenshots are copied while the pasteboard still grants access to them.
final class TerminalAttachments {
    enum Item {
        case file(URL)
        case text(String)
    }

    let items: [Item]
    let directory: URL

    private init(items: [Item], directory: URL) {
        self.items = items
        self.directory = directory
    }

    static func capture(_ pasteboard: NSPasteboard, in root: URL = FileManager.default.temporaryDirectory) throws -> TerminalAttachments? {
        let boardItems = pasteboard.pasteboardItems ?? []
        let hasFiles = boardItems.contains { $0.types.contains(.fileURL) }
        let image: Data?
        if hasFiles {
            image = nil
        } else if let png = pasteboard.data(forType: .png) {
            image = png
        } else if let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) {
            image = bitmap.representation(using: .png, properties: [:])
        } else {
            image = nil
        }
        guard hasFiles || image != nil else { return nil }
        let directory = root.appendingPathComponent("muxify-paste-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            var items: [Item] = []
            if let image {
                let file = directory.appendingPathComponent("Screenshot.png")
                try image.write(to: file, options: .atomic)
                items.append(.file(file))
            } else {
                for item in boardItems {
                    if let value = item.propertyList(forType: .fileURL),
                       let file = NSURL(pasteboardPropertyList: value, ofType: .fileURL) as URL?, file.isFileURL {
                        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                            throw TmuxError.failed(status: 1, stderr: "Only files can be pasted into a Remote Environment.")
                        }
                        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                        let copy = folder.appendingPathComponent(file.lastPathComponent)
                        try FileManager.default.copyItem(at: file, to: copy)
                        items.append(.file(copy))
                    } else if let text = item.string(forType: .string) {
                        items.append(.text(text))
                    }
                }
            }
            return TerminalAttachments(items: items, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func removeLocalCopy() { try? FileManager.default.removeItem(at: directory) }

    /// stdin is binary, never the interactive terminal. Publish only a complete
    /// file, in a private per-file directory retained for the remote temp policy.
    static let uploadScript = """
    set -eu
    umask 077
    folder=$(mktemp -d "${TMPDIR:-/tmp}/muxify-paste.XXXXXXXX")
    trap 'rm -rf "$folder"' EXIT HUP INT TERM
    cat > "$folder/.upload"
    mv "$folder/.upload" "$folder/$1"
    printf '%s' "$folder/$1"
    trap - EXIT HUP INT TERM
    """
}
