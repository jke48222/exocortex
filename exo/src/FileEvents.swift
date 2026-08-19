import Foundation
import CoreServices

/// Filesystem activity via FSEvents.
///
/// PASS-4 Area B: FSEvents over `NSMetadataQuery`, because it is kernel-level, coalesced,
/// and — the decisive property — **replayable from a persisted `FSEventStreamEventId`**
/// after the daemon restarts. Spotlight has no durable cursor.
///
/// Records file *events* (path, op, time), never file *contents*. Building a full-disk
/// content index would duplicate Spotlight at enormous cost for little gain.
private final class Ctx {
    let store: Store
    var n = 0
    init(_ s: Store) { store = s }
}

enum FileEvents {
    /// Directories that are pure noise, or that would capture other people's data.
    static let skip = ["/Library/", "/.git/", "/node_modules/", "/.build/", "/.venv/",
                       "/DerivedData/", "/.Trash/", "/Caches/", "/__pycache__/",
                       "/.claude/", "/Application Support/"]

    static func watch(store: Store, seconds: Double) -> Int {
        let home = NSHomeDirectory()
        var count = 0
        let cursorKey = "fsevents"
        let saved = store.cursor("fs", cursorKey).flatMap { UInt64($0) }
        let since: FSEventStreamEventId = saved ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

        let ctx = Ctx(store)
        // passRetained, not passUnretained: `ctx` is otherwise only referenced from a C
        // callback the optimizer cannot see, so -O is free to deallocate it the moment
        // FSEventStreamCreate returns — a use-after-free that segfaults on the first event.
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        defer { Unmanaged<Ctx>.fromOpaque(ctxPtr).release() }
        var streamCtx = FSEventStreamContext(
            version: 0, info: ctxPtr, retain: nil, release: nil, copyDescription: nil)

        let cb: FSEventStreamCallback = { _, info, numEvents, eventPaths, flags, _ in
            guard let info else { return }
            let ctx = Unmanaged<Ctx>.fromOpaque(info).takeUnretainedValue()
            // eventPaths is a CFArrayRef of CFStringRef ONLY when the stream was created
            // with kFSEventStreamCreateFlagUseCFTypes. Without that flag it is a raw
            // char** and bridging it as an NSArray segfaults inside objc_msgSend.
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            for i in 0..<numEvents {
                guard i < paths.count else { break }
                let p = paths[i]
                if FileEvents.skip.contains(where: { p.contains($0) }) { continue }
                if p.hasSuffix(".swp") || p.hasSuffix("~") { continue }
                let f = flags[i]
                var ops: [String] = []
                if f & UInt32(kFSEventStreamEventFlagItemCreated) != 0 { ops.append("created") }
                if f & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { ops.append("removed") }
                if f & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { ops.append("renamed") }
                if f & UInt32(kFSEventStreamEventFlagItemModified) != 0 { ops.append("modified") }
                if ops.isEmpty { continue }
                var e = Event(source: "fs", sourceKind: .ownFile)   // your own filesystem -> verified
                e.app = "Finder"
                e.title = (p as NSString).lastPathComponent
                e.text = "\(ops.joined(separator: ",")) \(p)"
                e.externalID = "fs:\(p):\(ops.joined(separator: ","))"
                if ctx.store.insert(e) { ctx.n += 1 }
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, cb, &streamCtx, [home] as CFArray, since, 1.0,
            UInt32(kFSEventStreamCreateFlagFileEvents
                   | kFSEventStreamCreateFlagNoDefer
                   | kFSEventStreamCreateFlagUseCFTypes))
        else { return 0 }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let last = FSEventStreamGetLatestEventId(stream)
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        store.setCursor("fs", cursorKey, String(last))
        count = ctx.n
        return count
    }
}
