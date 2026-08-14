import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation

/// Rapid clicking wherever the cursor already is — no points, no sequence. A
/// global hotkey toggles it, which is the whole idea: you leave the pointer on
/// the target and hit the key.
@MainActor
@Observable
final class TurboClickService: NSObject {
    static let shared = TurboClickService()

    /// Autoclick's author found macOS locks up past 900 clicks a second. This
    /// ceiling is an order of magnitude below that on purpose.
    static let maxRate: Double = 100

    /// Esc, matching the sequence's kill switch. Registered only while running.
    private static let killSwitch = KeyBinding(keyCode: 53)

    private var runTask: Task<Void, Never>?
    private var statusItem: NSStatusItem?

    private(set) var isRunning = false

    private override init() {}

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }

        // Turbo and the sequence both drive the same one pointer; running them
        // together would interleave clicks in two different places.
        AutoClickService.shared.stop()

        isRunning = true
        AppState.shared.turboClickActive = true
        ClickCanvasController.shared.setPassthrough(true)
        HotkeyManager.shared.register(.autoClickStop, binding: Self.killSwitch) {
            TurboClickService.shared.stop()
        }
        showStatusItem()
        HUD.show("Turbo click on", symbol: "bolt.fill")

        runTask = Task { @MainActor [weak self] in
            await self?.run()
        }
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        AppState.shared.turboClickActive = false
        runTask?.cancel()
        runTask = nil
        HotkeyManager.shared.unregister(.autoClickStop)
        ClickCanvasController.shared.setPassthrough(false)
        removeStatusItem()
        HUD.show("Turbo click off", symbol: "bolt.slash.fill")
    }

    private func run() async {
        let state = AppState.shared
        let button = state.turboClickButton
        let source = CGEventSource(stateID: .combinedSessionState)
        let interval = 1 / min(Self.maxRate, max(1, state.turboClickRate))

        while !Task.isCancelled {
            // Read the position every tick rather than latching it: turbo is
            // meant to follow the pointer while it's held on a target.
            guard let point = CursorMotion.location else { break }
            MouseEvents.click(source, at: point, button: button)
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    // MARK: - Extra menubar icon while running

    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Turbo click is on")
        item.button?.toolTip = "OneBar — Turbo click is on"

        let menu = NSMenu()
        let info = NSMenuItem(
            title: "Turbo Click is On — \(Int(AppState.shared.turboClickRate)) clicks/sec",
            action: nil,
            keyEquivalent: ""
        )
        info.isEnabled = false
        menu.addItem(info)

        let hint = NSMenuItem(title: "Press Esc to stop", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        let turnOff = NSMenuItem(title: "Stop Turbo Click", action: #selector(stopFromMenu), keyEquivalent: "")
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

    @objc private func stopFromMenu() {
        stop()
    }
}
