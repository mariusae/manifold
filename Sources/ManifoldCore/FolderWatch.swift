import Foundation
#if canImport(CoreServices)
import CoreServices
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Folders watched for what's in them changing — an entry made, removed,
/// renamed, written or its attributes changed — each one by itself, not
/// what's under it: the file system says so (FSEvents on a Mac, inotify
/// on Linux), nothing is looked at again and again. What changed comes
/// together, a moment after the first of it.
public final class FolderWatch {
    private let queue: DispatchQueue
    private let onChange: (Set<String>) -> Void
    /// The folders watched.
    public private(set) var folders: Set<String> = []
    private var pending = Set<String>()
    private var flushing = false

    /// `onChange` is called on `queue`, as `set` must be.
    public init(queue: DispatchQueue, onChange: @escaping (Set<String>) -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        #if canImport(CoreServices)
        stopStream()
        #else
        for t in tokens.values { Inotify.shared.unwatch(t) }
        #endif
    }

    /// Watches these folders, and no others.
    public func set(_ wanted: Set<String>) {
        guard wanted != folders else { return }
        folders = wanted
        #if canImport(CoreServices)
        restartStream()
        #else
        for (f, t) in tokens where !wanted.contains(f) {
            Inotify.shared.unwatch(t)
            tokens[f] = nil
        }
        for f in wanted where tokens[f] == nil { add(f) }
        #endif
    }

    /// Heard, on the queue: told a moment later, with what else comes.
    private func heard(_ changed: Set<String>) {
        let mine = changed.intersection(folders)
        guard !mine.isEmpty else { return }
        pending.formUnion(mine)
        guard !flushing else { return }
        flushing = true
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.flushing = false
            let told = self.pending
            self.pending = []
            if !told.isEmpty { self.onChange(told) }
        }
    }

    #if canImport(CoreServices)
    // MARK: FSEvents

    private var stream: FSEventStreamRef?
    /// Each folder as the file system spells it (/private/tmp for /tmp),
    /// the way its events name it: the folders it's asked as.
    private var asked: [String: Set<String>] = [:]

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func restartStream() {
        stopStream()
        asked = [:]
        for f in folders { asked[Self.real(f), default: []].insert(f) }
        guard !asked.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            var changed = Set<String>()
            for i in 0..<count {
                guard var p = list[i] as? String else { continue }
                while p.count > 1, p.hasSuffix("/") { p.removeLast() }
                let f = flags[i]
                // Events lost, or to be looked for under a folder: each
                // watched there, changed.
                if f & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                    for (real, a) in me.asked where real == p || real.hasPrefix(p == "/" ? "/" : p + "/") { changed.formUnion(a) }
                    continue
                }
                // An entry's change is its folder's; a folder's own (made,
                // removed, renamed) is itself's.
                if let a = me.asked[(p as NSString).deletingLastPathComponent] { changed.formUnion(a) }
                if let a = me.asked[p] { changed.formUnion(a) }
            }
            me.heard(changed)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, Array(asked.keys) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    /// The path with its links resolved, as C's realpath has it (not
    /// Foundation's, which gives /tmp back for /private/tmp); itself if
    /// it isn't there.
    static func real(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }
    #else
    // MARK: inotify

    private var tokens: [String: Inotify.Token] = [:]
    /// Folders that weren't there to watch: tried again when anything's heard.
    private var missing = Set<String>()

    private func add(_ f: String) {
        let t = Inotify.shared.watch(f) { [weak self] _, mask in
            self?.queue.async {
                guard let self else { return }
                if mask & (Inotify.ignored | Inotify.deleteSelf | Inotify.moveSelf) != 0, let t = self.tokens[f] {
                    Inotify.shared.unwatch(t)
                    self.tokens[f] = nil
                    self.missing.insert(f)
                }
                self.heard([f])
                self.retryMissing()
            }
        }
        if let t { tokens[f] = t; missing.remove(f) } else { missing.insert(f) }
    }

    private func retryMissing() {
        for f in missing where folders.contains(f) && tokens[f] == nil {
            add(f)
            if tokens[f] != nil { heard([f]) }
        }
        missing = missing.filter { folders.contains($0) && tokens[$0] == nil }
    }
    #endif
}

#if !canImport(CoreServices)
/// The process's one inotify instance, shared by all that watch: a watch
/// on a folder, its handlers told of each event in it (the name of the
/// entry, none for the folder itself) on inotify's own queue.
final class Inotify: @unchecked Sendable {
    static let shared = Inotify()
    typealias Handler = (_ name: String?, _ mask: UInt32) -> Void
    struct Token: Hashable { let wd: Int32; let id: Int }

    static let modify: UInt32 = 0x2, attrib: UInt32 = 0x4, closeWrite: UInt32 = 0x8, movedFrom: UInt32 = 0x40, movedTo: UInt32 = 0x80,
               create: UInt32 = 0x100, delete: UInt32 = 0x200, deleteSelf: UInt32 = 0x400, moveSelf: UInt32 = 0x800,
               overflow: UInt32 = 0x4000, ignored: UInt32 = 0x8000
    /// Every watch asks for all of these (a second watch on a folder
    /// replaces the first's mask): each handler takes what it wants.
    static let mask: UInt32 = modify | attrib | closeWrite | movedFrom | movedTo | create | delete | deleteSelf | moveSelf

    private let fd: Int32
    private let lock = NSLock()
    private var handlers: [Int32: [Int: Handler]] = [:]
    private var nextID = 0
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "inotify", qos: .utility)

    private init() {
        // IN_NONBLOCK | IN_CLOEXEC, as O_NONBLOCK and O_CLOEXEC are on Linux.
        fd = inotify_init1(0x800 | 0x80000)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.read() }
        s.resume()
        source = s
    }

    func watch(_ path: String, _ handler: @escaping Handler) -> Token? {
        guard fd >= 0 else { return nil }
        let wd = inotify_add_watch(fd, path, Self.mask)
        guard wd >= 0 else { return nil }
        lock.lock()
        nextID += 1
        let t = Token(wd: wd, id: nextID)
        handlers[wd, default: [:]][t.id] = handler
        lock.unlock()
        return t
    }

    func unwatch(_ t: Token) {
        lock.lock()
        handlers[t.wd]?[t.id] = nil
        let last = handlers[t.wd]?.isEmpty == true
        if last { handlers[t.wd] = nil }
        lock.unlock()
        if last { inotify_rm_watch(fd, t.wd) }
    }

    private func read() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { Glibc_read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            var calls: [(Handler, String?, UInt32)] = []
            buf.withUnsafeBytes { raw in
                var off = 0
                lock.lock()
                while off + 16 <= n {
                    let wd = raw.loadUnaligned(fromByteOffset: off, as: Int32.self)
                    let mask = raw.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self)
                    let len = Int(raw.loadUnaligned(fromByteOffset: off + 12, as: UInt32.self))
                    var name: String?
                    if len > 0 {
                        let bytes = raw[(off + 16)..<min(off + 16 + len, n)]
                        name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                    }
                    off += 16 + len
                    if mask & Self.overflow != 0 {
                        // Events lost: every watch told something changed.
                        for hs in handlers.values { for h in hs.values { calls.append((h, nil, mask)) } }
                        continue
                    }
                    for h in (handlers[wd] ?? [:]).values { calls.append((h, name, mask)) }
                    // The kernel let it go (its folder removed): so do we.
                    if mask & Self.ignored != 0 { handlers[wd] = nil }
                }
                lock.unlock()
            }
            for (h, name, mask) in calls { h(name, mask) }
        }
    }
}

private func Glibc_read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ n: Int) -> Int { read(fd, buf, n) }
#endif
