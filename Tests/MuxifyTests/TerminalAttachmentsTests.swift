import AppKit
import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class TerminalAttachmentsTests: XCTestCase {
    func testTIFFClipboardBecomesPNGAndTextClipboardStaysText() throws {
        let root = try TestDirectory()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("ordinary paste", forType: .string)
        XCTAssertNil(try TerminalAttachments.capture(board, in: root.url))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        board.clearContents()
        board.setData(try XCTUnwrap(bitmap.tiffRepresentation), forType: .tiff)
        let captured = try XCTUnwrap(TerminalAttachments.capture(board, in: root.url))
        guard case .file(let file) = captured.items.first else { return XCTFail("No image") }
        XCTAssertEqual(file.pathExtension, "png")
        let data = try Data(contentsOf: file)
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(NSBitmapImageRep(data: data)?.pixelsWide, 2)
    }

    func testFileURLsWinOverPreviewImagesAndAreSnapshottedBeforeUpload() throws {
        let root = try TestDirectory()
        let source = root.url.appendingPathComponent("Screenshot ' ; $().png")
        let bytes = Data((0..<10000).map { UInt8($0 % 256) })
        try bytes.write(to: source)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString(source.absoluteString, forType: .fileURL)
        item.setData(Data("preview".utf8), forType: .png)
        let text = NSPasteboardItem()
        text.setString("caption", forType: .string)
        board.writeObjects([item, text])
        let captured = try XCTUnwrap(TerminalAttachments.capture(board, in: root.url))
        try FileManager.default.removeItem(at: source)
        guard case .file(let file) = captured.items.first else { return XCTFail("No file") }
        XCTAssertEqual(file.lastPathComponent, source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        guard case .text("caption") = captured.items.last else { return XCTFail("Lost caption") }
        captured.removeLocalCopy()
        XCTAssertFalse(FileManager.default.fileExists(atPath: captured.directory.path))
    }

    func testUploadStreamsBinaryAndPreservesFilenameInPrivateRemoteDirectory() throws {
        let root = try TestDirectory()
        let source = root.url.appendingPathComponent("source")
        let bytes = Data((0..<2_000_000).map { UInt8($0 % 256) })
        try bytes.write(to: source)
        let name = "Screenshot ' ; $(touch unwanted)\n😃.png"
        let result = try CommandRunner().run(CommandInvocation(executable: "/bin/sh",
            arguments: ["-c", TerminalAttachments.uploadScript, "muxify", name]),
            environment: ["PATH": "/usr/bin:/bin", "TMPDIR": root.url.path], inputFile: source)
        let destination = URL(fileURLWithPath: result)
        XCTAssertTrue(result.hasPrefix(root.url.path + "/muxify-paste."))
        XCTAssertEqual(destination.lastPathComponent, name)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().appendingPathComponent(".upload").path))
        let permissions = try FileManager.default.attributesOfItem(atPath: destination.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
    }

    func testUploadFailureDoesNotPublishAPathOrLeaveAPartialFile() throws {
        let root = try TestDirectory()
        let bin = root.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        let cat = bin.appendingPathComponent("cat")
        try "#!/bin/sh\nprintf partial\nexit 1\n".write(to: cat, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cat.path)
        XCTAssertThrowsError(try CommandRunner().run(CommandInvocation(executable: "/bin/sh",
            arguments: ["-c", TerminalAttachments.uploadScript, "muxify", "image.png"]),
            environment: ["PATH": bin.path + ":/usr/bin:/bin", "TMPDIR": root.url.path]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.url.path), ["bin"])
    }

    func testSSHUploadPastesIntoCapturedPaneAfterClientSwitches() throws {
        let tmux = try requireTmux()
        let root = try TestDirectory()
        defer { withExtendedLifetime(root) {} }
        let fm = FileManager.default
        let bin = root.url.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: false)
        let socket = root.url.appendingPathComponent("t").path
        let shim = bin.appendingPathComponent("tmux")
        try ("#!/bin/sh\nexec " + Tmux.shellQuote(tmux) + " -S " + Tmux.shellQuote(socket) + " -f /dev/null \"$@\"\n")
            .write(to: shim, atomically: true, encoding: .utf8)
        let started = root.url.appendingPathComponent("upload-started")
        let hold = root.url.appendingPathComponent("upload-hold")
        try Data().write(to: hold)
        let ssh = bin.appendingPathComponent("ssh")
        try """
        #!/bin/bash
        unset TMUX TMUX_PANE
        export TMUX_TMPDIR=\(Tmux.shellQuote(root.url.path)) TMPDIR=\(Tmux.shellQuote(root.url.path))
        export PATH=\(Tmux.shellQuote(bin.path + ":/usr/bin:/bin"))
        for arg do command=$arg; done
        if [[ "$command" == *'folder=$(mktemp'* ]]; then
            touch \(Tmux.shellQuote(started.path))
            while [ -f \(Tmux.shellQuote(hold.path)) ]; do sleep 0.02; done
        fi
        exec /bin/sh -c "$command"

        """.write(to: ssh, atomically: true, encoding: .utf8)
        for file in [shim, ssh] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        environment["TMUX_TMPDIR"] = root.url.path
        environment["TERM"] = "xterm-256color"
        let runner = CommandRunner()
        func raw(_ args: [String]) throws -> String {
            if args.first == "kill-server" {
                let actual = try runner.run(CommandInvocation(executable: shim.path,
                    arguments: ["display-message", "-p", "#{socket_path}"]), environment: environment)
                guard actual.trimmingCharacters(in: .newlines) == socket else { throw TmuxError.notReady }
            }
            return try runner.run(CommandInvocation(executable: shim.path, arguments: args), environment: environment)
        }
        defer { _ = try? raw(["kill-server"]) }
        let output = root.url.appendingPathComponent("input")
        let ready = root.url.appendingPathComponent("ready")
        let command = "stty raw -echo; printf '\\033[?2004h'; touch " + Tmux.shellQuote(ready.path)
            + "; exec cat > " + Tmux.shellQuote(output.path)
        let pane = try raw(["new-session", "-d", "-s", "paste", "-P", "-F", "#{pane_id}", command])
            .trimmingCharacters(in: .newlines)
        let terminal = Process()
        terminal.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        terminal.arguments = ["-q", "/dev/null", shim.path, "attach-session", "-t", "paste"]
        terminal.environment = environment
        let input = Pipe()
        terminal.standardInput = input
        terminal.standardOutput = FileHandle.nullDevice
        terminal.standardError = FileHandle.nullDevice
        try terminal.run()
        defer {
            if terminal.isRunning { terminal.terminate(); terminal.waitUntilExit() }
            withExtendedLifetime(input) {}
        }
        func eventually(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if condition() { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            throw TmuxError.timedOut
        }
        var client: [String] = []
        try eventually {
            client = ((try? raw(["list-clients", "-F", "#{client_tty}|#{client_pid}"])) ?? "")
                .trimmingCharacters(in: .newlines).components(separatedBy: "|")
            return client.count == 2 && !client[0].isEmpty && fm.fileExists(atPath: ready.path)
        }
        let connection = try TmuxConnection(environment: RemoteEnvironment(name: "fixture", host: "unused", username: "unused"),
                                            sshExecutable: ssh.path)
        let remote = try XCTUnwrap(connection.remote)
        defer { connection.retire(); connection.cleanup() }
        _ = try raw(["set-option", "-sq", remote.markerOption,
                     [client[1], client[0], root.url.path, "fixture", "remote"].joined(separator: Tmux.separator)])
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let bytes = Data((0..<10000).map { UInt8($0 % 256) })
        board.setData(bytes, forType: .png)
        let attachments = try XCTUnwrap(TerminalAttachments.capture(board, in: root.url))
        let finished = expectation(description: "attachment pasted")
        connection.pasteAttachments(attachments, client: client[0]) { result in
            switch result {
            case .success(let target): XCTAssertEqual(target, pane)
            case .failure(let error): XCTFail("Paste failed: \(error)")
            }
            finished.fulfill()
        }
        try eventually { fm.fileExists(atPath: started.path) }
        _ = try raw(["new-window", "-t", "paste:", "sleep 60"])
        XCTAssertNotEqual(try raw(["display-message", "-p", "-c", client[0], "#{pane_id}"]).trimmingCharacters(in: .newlines), pane)
        try fm.removeItem(at: hold)
        wait(for: [finished], timeout: 10)
        var pasted = ""
        try eventually {
            pasted = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            return pasted.hasSuffix("\u{1b}[201~")
        }
        XCTAssertTrue(pasted.hasPrefix("\u{1b}[200~"))
        let path = String(pasted.dropFirst(6).dropLast(6))
        XCTAssertTrue(path.hasPrefix(root.url.path + "/muxify-paste."), pasted)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        XCTAssertFalse(fm.fileExists(atPath: attachments.directory.path))
    }
}
