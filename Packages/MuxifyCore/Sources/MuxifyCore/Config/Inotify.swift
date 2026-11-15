#if os(Linux)
/// inotify for FolderWatcher and the `repository` watch, declared here: the static Linux SDK's C module does not
/// promise `sys/inotify.h`.
enum Inotify {
    /// IN_MODIFY, IN_ATTRIB, IN_CLOSE_WRITE, IN_MOVED_FROM, IN_MOVED_TO, IN_CREATE and IN_DELETE.
    static let changes: UInt32 = 0x2 | 0x4 | 0x8 | 0x40 | 0x80 | 0x100 | 0x200
    /// IN_DELETE_SELF and IN_MOVE_SELF.
    static let folderGone: UInt32 = 0x400 | 0x800
    /// IN_NONBLOCK and IN_CLOEXEC, which are O_NONBLOCK and O_CLOEXEC on both architectures.
    private static let nonBlocking: Int32 = 0o4000
    private static let closeOnExec: Int32 = 0o2000000

    /// A non-blocking, close-on-exec inotify descriptor, or -1.
    static func initialize() -> Int32 { muxifyInotifyInit1(nonBlocking | closeOnExec) }

    static func addWatch(_ descriptor: Int32, _ path: String, _ mask: UInt32) -> Int32 {
        muxifyInotifyAddWatch(descriptor, path, mask)
    }

    static func removeWatch(_ descriptor: Int32, _ watch: Int32) -> Int32 { muxifyInotifyRmWatch(descriptor, watch) }
}

@_silgen_name("inotify_init1")
private func muxifyInotifyInit1(_ flags: Int32) -> Int32

@_silgen_name("inotify_add_watch")
private func muxifyInotifyAddWatch(_ descriptor: Int32, _ path: UnsafePointer<CChar>, _ mask: UInt32) -> Int32

@_silgen_name("inotify_rm_watch")
private func muxifyInotifyRmWatch(_ descriptor: Int32, _ watch: Int32) -> Int32
#endif
