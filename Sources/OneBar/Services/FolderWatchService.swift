import AppKit
import CoreServices
import Foundation

/// Watches the configured folders and puts what arrives in them onto a shelf.
///
/// `FSEventStream` rather than a `DispatchSource` file-descriptor watch, because
/// only FSEvents can report what happens inside subfolders — and because a
/// descriptor watch says the directory changed without saying what changed, so
/// every notification would mean re-listing the folder and diffing it.
///
/// One stream covers every watch. A stream is not free, and the per-watch part
/// — the rules, whether subfolders count — is applied when an event is matched
/// back to the watch its path belongs to.
@MainActor
final class FolderWatchService {
    static let shared = FolderWatchService()

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.onebar.folder-watch")
    /// Arrivals waiting to stop growing, keyed by path so repeated events for
    /// one file collapse into the single check already running for it.
    private var settling: [String: Task<Void, Never>] = [:]
    /// The shelf each watch is currently filling, so a folder that receives ten
    /// files puts them on one shelf rather than asking for ten.
    private var shelfByWatch: [UUID: UUID] = [:]
    private var announcedLimit = false

    private init() {}

    // MARK: - Lifetime

    func start() {
        FolderWatchStore.shared.refreshScreenshotLocation()
        restart()
    }

    func restart() {
        stop()
        guard AppState.shared.shelfEnabled else { return }
        let paths = FolderWatchStore.shared.watches
            .filter(\.isEnabled)
            .compactMap { $0.resolveURL()?.path }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // `SinceNow` is what stops enabling a watch on Downloads from emptying
        // the whole folder onto a shelf: only what arrives from here counts.
        // `FileEvents` asks for per-file paths rather than "this directory
        // changed", and `NoDefer` delivers the first event of a burst at once
        // instead of at the end of the latency window.
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        for task in settling.values { task.cancel() }
        settling.removeAll()
    }

    // MARK: - Events

    fileprivate func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        for event in events {
            // A file that was only modified is one that was already there.
            // Delivering those would put a document back on a shelf every time
            // it was saved.
            let created = event.flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0
            let renamed = event.flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
            guard created || renamed else { continue }
            guard let watch = watch(for: event.path) else { continue }
            guard isDeliverable(event.path) else { continue }
            scheduleSettle(event.path, watchID: watch.id)
        }
    }

    /// The watch an arrival belongs to. A path inside a subfolder only counts
    /// for a watch that asked for subfolders — FSEvents is always recursive, so
    /// the shallow case is a filter rather than a different stream.
    private func watch(for path: String) -> ShelfFolderWatch? {
        let url = URL(filePath: path)
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        return FolderWatchStore.shared.watches.first { watch in
            guard watch.isEnabled, let root = watch.resolveURL()?.standardizedFileURL.path
            else { return false }
            if parent == root { return true }
            return watch.includesSubfolders && path.hasPrefix(root + "/")
        }
    }

    /// Things that are not arrivals in any sense a person would recognise.
    private func isDeliverable(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        // A download in flight is renamed to its real name when it finishes,
        // and that rename is the event worth acting on.
        let inProgress = ["download", "crdownload", "part", "partial", "tmp", "temp"]
        return !inProgress.contains((name as NSString).pathExtension.lowercased())
    }

    /// Waits for the file to stop growing before handing it over.
    ///
    /// A file exists from its first byte, so an arrival seen the instant it is
    /// created is very often a file still being written. The shelf references
    /// rather than copies, so a half-written file is not corrupted by this —
    /// but its size and thumbnail would be wrong, and a rule about size would
    /// be tested against a number still climbing.
    private func scheduleSettle(_ path: String, watchID: UUID) {
        settling[path]?.cancel()
        settling[path] = Task { @MainActor [weak self] in
            var lastSize = -1
            // Long enough for a large file over a slow connection, and bounded
            // so a file being written forever does not leak a task.
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                guard FileManager.default.fileExists(atPath: path) else {
                    self?.settling[path] = nil
                    return
                }
                let size = WatchedFile.read(URL(filePath: path)).byteSize
                if size == lastSize { break }
                lastSize = size
            }
            guard !Task.isCancelled, let self else { return }
            self.settling[path] = nil
            self.deliver(path, watchID: watchID)
        }
    }

    // MARK: - Delivery

    private func deliver(_ path: String, watchID: UUID) {
        guard let watch = FolderWatchStore.shared.watch(watchID), watch.isEnabled else { return }
        let url = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard watch.rules.matches(WatchedFile.read(url)) else { return }
        guard let item = ShelfItemReader.fileItem(for: url) else { return }
        guard let shelf = shelf(for: watch) else { return }
        shelf.add([item])
    }

    /// The shelf this watch is filling, making one if there is not one already.
    ///
    /// Reusing a shelf matters more than it sounds: a folder that receives a
    /// burst of files would otherwise ask for a shelf per file and hit the open
    /// shelf limit on the third one.
    private func shelf(for watch: ShelfFolderWatch) -> ShelfController? {
        if !watch.newShelfPerFile,
           let existing = shelfByWatch[watch.id],
           let controller = ShelfManager.shared.shelves.first(where: { $0.id == existing }) {
            return controller
        }
        // Never takes focus: a file arriving in a folder is not the user asking
        // for anything, and stealing the keyboard mid-sentence would be rude.
        guard let controller = ShelfManager.shared.newShelf(at: nil, focus: .none) else {
            announceLimitOnce()
            return nil
        }
        controller.setName(watch.displayName)
        shelfByWatch[watch.id] = controller.id
        return controller
    }

    /// Said once per run. A folder filling up while every shelf is open would
    /// otherwise put the same message on screen for every file that arrived.
    private func announceLimitOnce() {
        guard !announcedLimit else { return }
        announcedLimit = true
        HUD.show("No room for a watched folder's shelf", symbol: "tray.full")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.announcedLimit = false
        }
    }
}

/// A C function pointer captures nothing, so the service arrives through the
/// stream's context and the paths are read back out of the CF array.
private let eventCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info else { return }
    let service = Unmanaged<FolderWatchService>.fromOpaque(info).takeUnretainedValue()
    guard let pathArray = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    var events: [(path: String, flags: FSEventStreamEventFlags)] = []
    for index in 0..<min(count, pathArray.count) {
        events.append((pathArray[index], flags[index]))
    }
    Task { @MainActor in service.handle(events) }
}
