import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation

/// Walks the click sequence: travel to each node, click it, wait, repeat.
///
/// Three independent things stop it — the ESC kill switch, taking hold of the
/// mouse, and the auto-off timer — because a running clicker owns your input and
/// one way out isn't enough.
@MainActor
@Observable
final class AutoClickService: NSObject {
    static let shared = AutoClickService()

    /// Esc. Registered only while running: a permanently held bare Esc would be
    /// swallowed system-wide, which would break it everywhere else.
    private static let killSwitch = KeyBinding(keyCode: 53)

    private var runTask: Task<Void, Never>?
    private var autoOffTimer: Timer?
    private var autoOffDate: Date?
    private var statusItem: NSStatusItem?

    private(set) var isRunning = false
    /// Which node is firing, so the canvas can light it up.
    private(set) var currentNode: UUID?
    private(set) var completedPasses = 0

    private override init() {}

    /// Returns false when there's nothing to run or Accessibility is missing
    /// (which it also prompts for) — without it our events are dropped.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        guard !ClickSequence.shared.nodes.isEmpty else {
            HUD.show("Add a click point first", symbol: "cursorarrow.click.badge.clock")
            return false
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }

        isRunning = true
        completedPasses = 0
        // The canvas sits over everything; if it keeps eating mouse events it
        // swallows the very clicks we're about to post underneath it.
        ClickCanvasController.shared.setPassthrough(true)
        registerKillSwitch()
        scheduleAutoOff()
        showStatusItem()

        runTask = Task { @MainActor [weak self] in
            await self?.run()
        }
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        currentNode = nil
        runTask?.cancel()
        runTask = nil
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffDate = nil
        HotkeyManager.shared.unregister(.autoClickStop)
        ClickCanvasController.shared.setPassthrough(false)
        removeStatusItem()
        AppState.shared.autoClickActive = false
    }

    // MARK: - The loop

    private func run() async {
        let state = AppState.shared

        while !Task.isCancelled {
            let nodes = ClickSequence.shared.nodes
            guard !nodes.isEmpty else { break }

            for node in nodes {
                if Task.isCancelled { return }
                currentNode = node.id

                guard await perform(node) else {
                    stopped(reason: "Auto Click stopped — you took the mouse back")
                    return
                }
                try? await Task.sleep(for: .seconds(varied(node.delay)))
            }

            completedPasses += 1
            if state.autoClickRepeatCount > 0, completedPasses >= state.autoClickRepeatCount {
                break
            }
        }

        // Falling out of the loop means we finished or ran out of nodes. A
        // cancelled run already went through `stop()`, so this is a no-op there.
        if isRunning { stopped(reason: "Auto Click finished") }
    }

    /// Returns false when a hand took over the cursor and resistance stop is on.
    private func perform(_ node: ClickNode) async -> Bool {
        let state = AppState.shared
        guard let origin = CursorMotion.location else { return false }

        let target = scattered(node.point, by: state.autoClickJitter)
        let arrived = await CursorMotion.glide(
            from: origin,
            to: target,
            speed: state.autoClickTravelSpeed,
            curve: state.autoClickCurve
        )
        if !arrived, state.autoClickResistanceStop { return false }
        if Task.isCancelled { return false }

        await click(at: target, button: node.button, count: node.clickCount)
        return true
    }

    private func click(at point: CGPoint, button: ClickButton, count: Int) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let (downType, upType, cgButton) = eventTypes(for: button)

        for press in 1...max(1, count) {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: downType,
                mouseCursorPosition: point,
                mouseButton: cgButton
            ) else { return }

            // What makes a double click a double click is this field, not the gap
            // between two events — post two plain clicks and apps read two singles.
            event.setIntegerValueField(.mouseEventClickState, value: Int64(press))
            event.post(tap: .cghidEventTap)

            // Hold briefly before releasing: a zero-length press is dropped by
            // some controls, which watch for the button being held at all.
            try? await Task.sleep(for: .milliseconds(20))
            event.type = upType
            event.post(tap: .cghidEventTap)

            if press < count { try? await Task.sleep(for: .milliseconds(60)) }
        }
    }

    private func eventTypes(for button: ClickButton) -> (CGEventType, CGEventType, CGMouseButton) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp, .left)
        case .right: return (.rightMouseDown, .rightMouseUp, .right)
        case .middle: return (.otherMouseDown, .otherMouseUp, .center)
        }
    }

    // MARK: - Taking the edge off the rhythm

    private func scattered(_ point: CGPoint, by jitter: Int) -> CGPoint {
        guard jitter > 0 else { return point }
        let spread = Double(jitter)
        return CGPoint(
            x: point.x + .random(in: -spread...spread),
            y: point.y + .random(in: -spread...spread)
        )
    }

    private func varied(_ delay: Double) -> Double {
        let variance = AppState.shared.autoClickVariance
        guard variance > 0 else { return delay }
        return max(0, delay * (1 + .random(in: -variance...variance)))
    }

    // MARK: - Stopping

    private func stopped(reason: String) {
        stop()
        HUD.show(reason, symbol: "cursorarrow.click.badge.clock")
    }

    private func registerKillSwitch() {
        HotkeyManager.shared.register(.autoClickStop, binding: Self.killSwitch) {
            AutoClickService.shared.stopped(reason: "Auto Click stopped")
        }
    }

    private func scheduleAutoOff() {
        let minutes = AppState.shared.autoClickAutoOffMinutes
        guard minutes > 0 else { return }
        let date = Date().addingTimeInterval(TimeInterval(minutes * 60))
        autoOffDate = date
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stopped(reason: "Auto Click turned off automatically")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoOffTimer = timer
    }

    // MARK: - Extra menubar icon while running

    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "cursorarrow.click.badge.clock",
            accessibilityDescription: "Auto Click is running"
        )
        item.button?.toolTip = "OneBar — Auto Click is running"

        let menu = NSMenu()
        let title: String
        if let autoOffDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            title = "Auto Click is Running — auto-off at \(formatter.string(from: autoOffDate))"
        } else {
            title = "Auto Click is Running"
        }
        let info = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)

        let hint = NSMenuItem(title: "Press Esc to stop", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        let turnOff = NSMenuItem(title: "Stop Auto Click", action: #selector(stopFromMenu), keyEquivalent: "")
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
