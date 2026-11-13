#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// The program a running tmux server was started from. A tmux of another release can fail on the server even when
/// their protocol versions agree, so a caller that runs this program, not the first tmux it finds, can always talk to it.
public enum TmuxServerBinary {
    /// The executable of the process that listens on the unix socket `socketPath`, or nil when no process of the
    /// current user does. A server that restarts makes a new socket file, so the answer is looked up again then.
    public static func path(forSocket socketPath: String) -> String? {
        guard let identity = FileIdentity(socketAt: socketPath) else { return nil }
        if let known = cache.binary(forSocket: socketPath, identity: identity),
           FileManager.default.isExecutableFile(atPath: known) { return known }
        guard let found = executable(ofListenerOn: canonical(socketPath)) else { return nil }
        cache.set(found, forSocket: socketPath, identity: identity)
        return found
    }

    /// The path with its symlinks resolved. tmux binds its default socket under the real path of its directory, such
    /// as `/private/tmp` for `/tmp` on macOS, and a process names the socket by that path.
    static func canonical(_ path: String) -> String { Folder.local(path).real }

    /// A lookup scans every process of the user, so the answer stays until the socket file is a different one.
    /// A nil answer is not kept: a server binds its socket a moment before it listens on it.
    private static let cache = Cache()

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        /// A file system can hand a new socket the inode of one that was just removed.
        let modifiedNanoseconds: Int64

        init?(socketAt path: String) {
            var info = stat()
            guard stat(path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { return nil }
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
            #if canImport(Darwin)
            let modified = info.st_mtimespec
            #else
            let modified = info.st_mtim
            #endif
            modifiedNanoseconds = Int64(modified.tv_sec) * 1_000_000_000 + Int64(modified.tv_nsec)
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (identity: FileIdentity, binary: String)] = [:]

        func binary(forSocket path: String, identity: FileIdentity) -> String? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[path], entry.identity == identity else { return nil }
            return entry.binary
        }

        func set(_ binary: String, forSocket path: String, identity: FileIdentity) {
            lock.lock()
            entries[path] = (identity, binary)
            lock.unlock()
        }
    }
}

#if os(Linux)
extension TmuxServerBinary {
    /// The inode of the listening socket comes from `/proc/net/unix`, and the process is the one that has a file
    /// descriptor on it. A process named `tmux` is looked at first; any other of the user's processes follows, for a
    /// server that runs from a program under another name.
    fileprivate static func executable(ofListenerOn socket: String) -> String? {
        guard let table = readFile("/proc/net/unix") else { return nil }
        let name = "/" + (socket as NSString).lastPathComponent
        let links = Set(table.split(separator: "\n").dropFirst().compactMap { line -> String? in
            // Num RefCount Protocol Flags Type St Inode Path; 0x10000 in Flags is __SO_ACCEPTCON, the listening state.
            let fields = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard fields.count == 8, fields[7].hasSuffix(name), let flags = UInt32(fields[3], radix: 16),
                  flags & 0x10000 != 0, canonical(String(fields[7])) == socket else { return nil }
            return "socket:[\(fields[6])]"
        })
        guard !links.isEmpty else { return nil }
        let user = getuid()
        let own = ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []).compactMap { pid -> (pid: String, isTmux: Bool)? in
            var info = stat()
            guard Int32(pid) != nil, stat("/proc/\(pid)", &info) == 0, info.st_uid == user else { return nil }
            return (pid, (readFile("/proc/\(pid)/comm") ?? "").hasPrefix("tmux"))
        }
        for candidate in own.filter(\.isTmux) + own.filter({ !$0.isTmux }) where holds(candidate.pid, oneOf: links) {
            return program(ofProcess: candidate.pid)
        }
        return nil
    }

    private static func holds(_ pid: String, oneOf links: Set<String>) -> Bool {
        let descriptors = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(pid)/fd")) ?? []
        return descriptors.contains { descriptor in link("/proc/\(pid)/fd/\(descriptor)").map(links.contains) ?? false }
    }

    /// Linux can run `/proc/<pid>/exe` even after the program's file was replaced or deleted, as `brew upgrade` does
    /// under a running server, so it is the answer when the link's target is gone.
    private static func program(ofProcess pid: String) -> String {
        let exe = "/proc/\(pid)/exe"
        guard let target = link(exe), !target.hasSuffix(" (deleted)"), FileManager.default.isExecutableFile(atPath: target) else { return exe }
        return target
    }

    private static func link(_ path: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let length = readlink(path, &buffer, buffer.count)
        return length < 0 ? nil : String(decoding: buffer[..<length], as: UTF8.self)
    }

    /// `/proc` files report a size of 0, so they are read to their end.
    private static func readFile(_ path: String) -> String? {
        FileHandle(forReadingAtPath: path).map { String(decoding: $0.readDataToEndOfFile(), as: UTF8.self) }
    }
}
#else
extension TmuxServerBinary {
    /// libproc lists the user's processes, their file descriptors and each socket descriptor's bound path. A program
    /// named `tmux` is looked at first; any other of the user's processes follows.
    fileprivate static func executable(ofListenerOn socket: String) -> String? {
        let size = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard size > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 16)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let own = pids.prefix(max(Int(filled), 0) / MemoryLayout<pid_t>.size).filter { $0 > 0 }.compactMap { pid -> (pid: pid_t, program: String)? in
            program(ofProcess: pid).map { (pid, $0) }
        }
        let isTmux = { (program: String) in (program as NSString).lastPathComponent.hasPrefix("tmux") }
        for candidate in own.filter({ isTmux($0.program) }) + own.filter({ !isTmux($0.program) }) where listens(candidate.pid, on: socket) {
            return candidate.program
        }
        return nil
    }

    private static func listens(_ pid: pid_t, on socket: String) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * MemoryLayout<proc_fdinfo>.size))
        for descriptor in descriptors.prefix(max(Int(filled), 0) / MemoryLayout<proc_fdinfo>.size)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
                  info.psi.soi_family == AF_UNIX, info.psi.soi_kind == Int32(SOCKINFO_UN),
                  Int32(info.psi.soi_options) & SO_ACCEPTCONN != 0 else { continue }
            let bound = withUnsafeBytes(of: info.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if canonical(bound) == socket { return true }
        }
        return false
    }

    private static func program(ofProcess pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }
}
#endif
