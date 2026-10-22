import AppKit

/// Files another app promises on a drag (Photos, Mail's attachments, the
/// screenshot thumbnail): written to a scratch folder of their own when
/// dropped, then taken as files dropped from the Finder are.
enum Promises {
    /// The types to register for, beside a view's own.
    static var types: [NSPasteboard.PasteboardType] { NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } }

    static func receivers(_ pb: NSPasteboard) -> [NSFilePromiseReceiver] {
        (pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
    }

    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    /// The files, once written: on the main queue (none if they never come).
    static func receive(_ receivers: [NSFilePromiseReceiver], done: @escaping ([URL]) -> Void) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let folder = caches.appendingPathComponent("Manifold/Dropped/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        let group = DispatchGroup()
        for r in receivers {
            for _ in r.fileNames.isEmpty ? [""] : r.fileNames { group.enter() }
            var left = max(r.fileNames.count, 1)
            r.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                DispatchQueue.main.async {
                    if error == nil { urls.append(url) }
                    if left > 0 { left -= 1; group.leave() }
                }
            }
        }
        group.notify(queue: .main) { done(urls) }
    }
}
