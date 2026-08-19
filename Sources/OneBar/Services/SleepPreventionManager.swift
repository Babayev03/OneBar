import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation

/// One session at a time, always with something that ends it: a clock, an app
/// quitting, a download finishing, a flat battery, or you. The assertions die
/// with the process, and the lid switch is put back on the way out, so quitting
/// OneBar always restores normal sleep.
@MainActor
@Observable
final class SleepPreventionManager {
    static let shared = SleepPreventionManager()

    /// Why a session stopped — the difference between "you pressed stop" and
    /// "your battery is nearly gone" is the whole point of the HUD.
    enum EndReason {
        case manual
        case timeExpired
        case appQuit(String)
        case downloadFinished
        case lowBattery

        var message: String {
            switch self {
            case .manual: return "Prevent Sleep off"
            case .timeExpired: return "Prevent Sleep finished"
            case .appQuit(let name): return "Prevent Sleep off — \(name) quit"
            case .downloadFinished: return "Prevent Sleep off — download finished"
            case .lowBattery: return "Prevent Sleep off — battery low"
            }
        }

        var symbol: String {
            switch self {
            case .lowBattery: return "battery.25"
            case .downloadFinished: return "arrow.down.circle.fill"
            default: return "moon.zzz.fill"
            }
        }
    }

    private(set) var session: SleepSession?
    private(set) var endDate: Date?
    /// Re-read every tick so the countdown in the card and on the button moves
    /// without either of them owning a timer.
    private(set) var now = Date()

    var isActive: Bool { session != nil }

    var remaining: TimeInterval? {
        endDate.map { max(0, $0.timeIntervalSince(now)) }
    }

    @ObservationIgnored private var assertionIDs: [IOPMAssertionID] = []
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private var statusInfoItem: NSMenuItem?
    @ObservationIgnored private let menuTarget = StatusMenuTarget()
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var download: DownloadWatch?

    /// What a watched file looked like last time we counted, and when it last
    /// looked different.
    private struct DownloadWatch {
        /// Not constant: a finished download is renamed, and the watch follows.
        var url: URL
        let timeout: TimeInterval
        var size: UInt64
        var modified: Date?
        var lastChange: Date
    }

    private init() {}

    // MARK: - Starting and stopping

    @discardableResult
    func start(_ session: SleepSession) -> Bool {
        // Starting a second session replaces the first rather than stacking on
        // it — two sets of assertions would need two stops.
        if isActive { tearDown() }

        let created = createAssertions()
        guard !created.isEmpty else { return false }
        assertionIDs = created

        self.session = session
        endDate = session.endDate
        now = Date()

        switch session {
        case .whileAppRuns(let bundleID, _):
            observeTermination(of: bundleID)
        case .whileFileGrows(let url, let timeout):
            let payload = Self.payload(at: url)
            download = DownloadWatch(
                url: url,
                timeout: timeout,
                size: payload?.size ?? 0,
                modified: payload?.modified,
                lastChange: Date()
            )
        case .indefinite, .until:
            break
        }

        applyClamshell()
        startTicker()
        showStatusItem()
        AppState.shared.preventSleepActive = true
        notify("Prevent Sleep on — \(session.summary)", symbol: "cup.and.saucer.fill")
        return true
    }

    func stop() {
        end(.manual)
    }

    private func end(_ reason: EndReason) {
        guard isActive else { return }
        tearDown()
        notify(reason.message, symbol: reason.symbol)
    }

    /// Everything a session holds, released in one place so no exit path can
    /// leave the lid switch or an assertion behind.
    private func tearDown() {
        releaseAssertions()
        Clamshell.setSleepDisabled(false)
        stopObservingTermination()
        ticker?.invalidate()
        ticker = nil
        ticks = 0
        download = nil
        session = nil
        endDate = nil
        removeStatusItem()
        AppState.shared.preventSleepActive = false
    }

    /// Picks up a changed `allowDisplaySleep` or lid setting without making the
    /// user stop and restart the session.
    func reapply() {
        guard isActive else { return }
        releaseAssertions()
        let created = createAssertions()
        guard !created.isEmpty else {
            // Nothing is held any more, so don't keep claiming to be active.
            end(.manual)
            return
        }
        assertionIDs = created
        applyClamshell()
    }

    /// The panel needs OneBar frontmost, and the caller has to drop the menu
    /// popover first — it sits over the open panel the same way it would sit
    /// over the colour loupe in `ColorPickerService`.
    func startFileSession() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick the file being downloaded. The session ends once it stops growing."
        panel.prompt = "Watch"
        panel.directoryURL = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Following the rename at the end means reading the folder around the
        // file, and macOS asks about a folder the first time it is read. Do it
        // now, with the user still at the keyboard — asked an hour later, when
        // the download finishes and they have walked away, the dialog just sits
        // there and the session never learns the download is done.
        _ = try? FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path
        )

        start(.whileFileGrows(url: url, timeout: AppState.shared.sleepDownloadTimeout))
    }

    // MARK: - The assertions

    /// Preventing system sleep says nothing about the display — without the
    /// second assertion the screen still goes dark while the Mac stays awake.
    /// Together these are `caffeinate -di`; system-only is `caffeinate -i`.
    private func createAssertions() -> [IOPMAssertionID] {
        var types = [kIOPMAssertionTypePreventUserIdleSystemSleep]
        if !AppState.shared.allowDisplaySleep {
            types.append(kIOPMAssertionTypePreventUserIdleDisplaySleep)
        }

        return types.compactMap { type in
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "OneBar Prevent Sleep" as CFString,
                &id
            )
            return result == kIOReturnSuccess ? id : nil
        }
    }

    private func releaseAssertions() {
        for id in assertionIDs { IOPMAssertionRelease(id) }
        assertionIDs = []
    }

    /// The assertions above only cover idle sleep; closing the lid is a
    /// separate path that ignores them entirely.
    private func applyClamshell() {
        Clamshell.setSleepDisabled(isActive && AppState.shared.sleepLidClosed)
    }

    // MARK: - Watching for the end

    private func startTicker() {
        // One timer for the whole session: the countdown, the clock, the file
        // and the battery all move at multiples of a second, and separate
        // timers would only be more things to invalidate.
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in SleepPreventionManager.shared.tick() }
        }
        // .common, or it stops dead while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard isActive else { return }
        now = Date()

        if let endDate, now >= endDate {
            end(.timeExpired)
            return
        }

        ticks += 1
        if download != nil, ticks % 5 == 0 { checkDownload() }
        if ticks % 30 == 0 { checkBattery() }
        updateStatusItem()
    }

    private func observeTermination(of bundleID: String) {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
                app.bundleIdentifier == bundleID
            else { return }
            let name = app.localizedName ?? "The app"
            Task { @MainActor in SleepPreventionManager.shared.end(.appQuit(name)) }
        }
    }

    private func stopObservingTermination() {
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
    }

    private func checkDownload() {
        guard var watch = download else { return }

        guard let payload = Self.payload(at: watch.url) else {
            // Finishing renames rather than deletes: `Foo.dmg.download` becomes
            // `Foo.dmg`. Follow the rename — only a disappearance with nothing
            // to follow means the download is really over.
            if let moved = Self.replacement(for: watch.url) {
                watch.url = moved
                watch.lastChange = Date()
                download = watch
                return
            }
            end(.downloadFinished)
            return
        }

        if payload.size != watch.size || payload.modified != watch.modified {
            watch.size = payload.size
            watch.modified = payload.modified
            watch.lastChange = Date()
            download = watch
            return
        }

        if Date().timeIntervalSince(watch.lastChange) >= watch.timeout {
            end(.downloadFinished)
        }
    }

    /// How big the thing at `url` is, and when it last changed.
    ///
    /// Safari downloads into a `Foo.dmg.download` *package* — a folder — whose
    /// own size never moves however much arrives inside it, so measuring the
    /// path itself would read every download as stalled from the first check.
    /// A folder is therefore measured by what it contains.
    private static func payload(at url: URL) -> (size: UInt64, modified: Date?)? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        guard isDirectory.boolValue else {
            guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { return nil }
            return (
                (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                attributes[.modificationDate] as? Date
            )
        }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let items = manager.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return (0, nil)
        }

        var total: UInt64 = 0
        var newest: Date?
        for case let item as URL in items {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            total += UInt64(values.fileSize ?? 0)
            if let changed = values.contentModificationDate, changed > newest ?? .distantPast {
                newest = changed
            }
        }
        return (total, newest)
    }

    /// The same download under its other name, in either direction — the
    /// partial next to the final one, or the final one next to the partial.
    private static func replacement(for url: URL) -> URL? {
        let manager = FileManager.default
        let partialSuffixes = ["download", "crdownload", "part", "partial", "tmp"]

        if partialSuffixes.contains(url.pathExtension.lowercased()) {
            let final = url.deletingPathExtension()
            return manager.fileExists(atPath: final.path) ? final : nil
        }

        for suffix in partialSuffixes {
            let partial = url.appendingPathExtension(suffix)
            if manager.fileExists(atPath: partial.path) { return partial }
        }
        return nil
    }

    private func checkBattery() {
        guard AppState.shared.sleepEndOnLowBattery,
              !PowerSource.isOnAC,
              let percentage = PowerSource.percentage,
              percentage <= AppState.shared.sleepLowBatteryPercent
        else { return }
        end(.lowBattery)
    }

    private func notify(_ message: String, symbol: String) {
        guard AppState.shared.sleepNotifications else { return }
        HUD.show(message, symbol: symbol)
    }

    // MARK: - Extra menubar icon while active

    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "cup.and.saucer.fill",
            accessibilityDescription: "Prevent Sleep is on"
        )
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "OneBar — Prevent Sleep is on"

        let menu = NSMenu()
        let info = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        statusInfoItem = info
        menu.addItem(.separator())
        let turnOff = NSMenuItem(
            title: "Turn Off Prevent Sleep",
            action: #selector(StatusMenuTarget.turnOff),
            keyEquivalent: ""
        )
        turnOff.target = menuTarget
        menu.addItem(turnOff)
        item.menu = menu

        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let statusItem else { return }
        // The countdown rides the icon rather than replacing it: the cup is
        // what makes the state readable at a glance.
        statusItem.button?.title = remaining.map { " " + Countdown.short($0) } ?? ""
        statusInfoItem?.title = statusTitle
    }

    private var statusTitle: String {
        guard let session else { return "Prevent Sleep is On" }
        if let remaining {
            return "Prevent Sleep — \(Countdown.long(remaining))"
        }
        return "Prevent Sleep — \(session.summary)"
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        statusInfoItem = nil
    }
}

/// A menu item needs an Objective-C target, which an `@Observable` class can't
/// be — so the selector lives on a two-line object the manager holds.
@MainActor
private final class StatusMenuTarget: NSObject {
    @objc func turnOff() {
        SleepPreventionManager.shared.stop()
    }
}
