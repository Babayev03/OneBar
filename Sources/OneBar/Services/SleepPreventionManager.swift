import AppKit
import Foundation
import IOKit.pwr_mgt

/// "Temporary & safe": the assertion lives only while the toggle is on and
/// dies with the process, so quitting OneBar always restores normal sleep.
/// While active, a second menubar icon makes the state impossible to miss.
@MainActor
final class SleepPreventionManager: NSObject {
    static let shared = SleepPreventionManager()

    private var assertionIDs: [IOPMAssertionID] = []
    private var statusItem: NSStatusItem?
    private var autoOffTimer: Timer?
    private var autoOffDate: Date?
    private(set) var isActive = false

    private override init() {}

    func start() {
        guard !isActive else { return }
        let created = createAssertions()
        guard !created.isEmpty else { return }

        assertionIDs = created
        isActive = true
        scheduleAutoOff()
        showStatusItem()
    }

    /// Picks up a changed `allowDisplaySleep` without making the user toggle
    /// Prevent Sleep off and on again.
    func reapply() {
        guard isActive else { return }
        releaseAssertions()
        let created = createAssertions()
        guard !created.isEmpty else {
            // Nothing is held any more, so don't keep claiming to be active.
            stop()
            AppState.shared.preventSleepActive = false
            return
        }
        assertionIDs = created
    }

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

    func stop() {
        guard isActive else { return }
        releaseAssertions()
        isActive = false
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffDate = nil
        removeStatusItem()
    }

    private func scheduleAutoOff() {
        let minutes = AppState.shared.sleepAutoOffMinutes
        guard minutes > 0 else { return }
        let date = Date().addingTimeInterval(TimeInterval(minutes * 60))
        autoOffDate = date
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
                AppState.shared.preventSleepActive = false
                HUD.show("Prevent Sleep turned off automatically", symbol: "moon.zzz.fill")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoOffTimer = timer
    }

    // MARK: - Extra menubar icon while active

    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "cup.and.saucer.fill",
            accessibilityDescription: "Prevent Sleep is on"
        )
        item.button?.toolTip = "OneBar — Prevent Sleep is on"

        let menu = NSMenu()
        let title: String
        if let autoOffDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            title = "Prevent Sleep is On — auto-off at \(formatter.string(from: autoOffDate))"
        } else {
            title = "Prevent Sleep is On"
        }
        let info = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        let turnOff = NSMenuItem(title: "Turn Off Prevent Sleep", action: #selector(turnOffFromMenu), keyEquivalent: "")
        turnOff.target = self
        menu.addItem(turnOff)
        item.menu = menu

        statusItem = item
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func turnOffFromMenu() {
        stop()
        AppState.shared.preventSleepActive = false
    }
}
