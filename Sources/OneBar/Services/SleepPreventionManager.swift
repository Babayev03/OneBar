import AppKit
import Foundation
import IOKit.pwr_mgt

/// "Temporary & safe": the assertion lives only while the toggle is on and
/// dies with the process, so quitting OneBar always restores normal sleep.
/// While active, a second menubar icon makes the state impossible to miss.
@MainActor
final class SleepPreventionManager: NSObject {
    static let shared = SleepPreventionManager()

    private var assertionID: IOPMAssertionID = 0
    private var statusItem: NSStatusItem?
    private var autoOffTimer: Timer?
    private var autoOffDate: Date?
    private(set) var isActive = false

    private override init() {}

    func start() {
        guard !isActive else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "OneBar Prevent Sleep" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            isActive = true
            scheduleAutoOff()
            showStatusItem()
        }
    }

    func stop() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
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
