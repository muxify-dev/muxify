// SwiftUI builds a window's accessibility tree only after an accessibility client outside the app asks for it.
// The TestDriver reads that tree from inside the app, so the Sandbox runs this once per launch.
import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: ax_wake <pid>\n".utf8))
    exit(2)
}

// macOS checks the Accessibility permission of the responsible process: the app that started the terminal, or the
// tmux server, that runs the checks. When that app has no permission, or has quit, the helper starts itself again
// as its own responsible process. Then one grant to this file works wherever the checks run.
let disclaimedKey = "AX_WAKE_DISCLAIMED"
let path = Bundle.main.executablePath ?? CommandLine.arguments[0]

typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

func runDisclaimed() -> Int32 {
    // RTLD_DEFAULT; the function is private API in libSystem.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
        FileHandle.standardError.write(Data("not trusted, and this macOS has no responsibility_spawnattrs_setdisclaim: allow the terminal that runs the checks in System Settings > Privacy & Security > Accessibility\n".utf8))
        return 3
    }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    _ = unsafeBitCast(symbol, to: SetDisclaim.self)(&attributes, 1)
    setenv(disclaimedKey, "1", 1)
    var child = pid_t()
    guard posix_spawn(&child, path, nil, &attributes, CommandLine.unsafeArgv, environ) == 0 else {
        FileHandle.standardError.write(Data("could not start \(path) as its own responsible process\n".utf8))
        return 3
    }
    var status: Int32 = 0
    while waitpid(child, &status, 0) == -1 && errno == EINTR {}
    return status & 0x7f == 0 ? (status >> 8) & 0xff : 3
}

guard AXIsProcessTrusted() else {
    guard getenv(disclaimedKey) == nil else {
        FileHandle.standardError.write(Data("not trusted: allow \(path) in System Settings > Privacy & Security > Accessibility\n".utf8))
        exit(3)
    }
    exit(runDisclaimed())
}
var windows: CFTypeRef?
let result = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windows)
exit(result == .success ? 0 : 1)
