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

        switch node.kind {
        case .click:
            await click(at: target, button: node.button, count: node.clickCount)
        case .text:
            // Click first: text has to land somewhere, and the point is what
            // says where the caret goes.
            await click(at: target, button: .left, count: 1)
            await type(node.text)
        case .slide:
            await slide(from: target, to: node.slideEnd, duration: node.slideDuration, button: node.button)
        case .scroll:
            await scroll(
                at: target,
                direction: node.scrollDirection,
                distance: node.scrollDistance,
                duration: node.scrollDuration
            )
        }
        return true
    }

    // MARK: - Typing

    /// Types by overriding each event's unicode payload rather than looking up
    /// virtual keycodes, so it is independent of the active keyboard layout and
    /// handles anything the string can hold.
    private func type(_ string: String) async {
        guard !string.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let perCharacter = 1 / max(1, AppState.shared.autoClickTypingSpeed)

        for character in string {
            if Task.isCancelled { return }

            if character == "\n" || character == "\r" {
                // A literal newline in the payload is ignored by most text
                // fields; they are watching for the Return key itself.
                press(virtualKey: 36, source: source)
            } else {
                var utf16 = Array(String(character).utf16)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                else { return }
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }

            try? await Task.sleep(for: .seconds(varied(perCharacter)))
        }
    }

    private func press(virtualKey: CGKeyCode, source: CGEventSource?) {
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)?.post(tap: .cghidEventTap)
    }

    // MARK: - Sliding

    /// Press, drag along an eased path, release. The release is posted on every
    /// exit path — bailing out mid-drag would otherwise leave the system holding
    /// a mouse button down with nothing to release it.
    private func slide(from start: CGPoint, to end: CGPoint, duration: Double, button: ClickButton) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let (downType, upType, cgButton) = MouseEvents.types(for: button)
        let dragType = MouseEvents.dragType(for: button)

        MouseEvents.post(source, type: downType, at: start, button: cgButton)
        // Let the press land before anything moves: drag targets commonly need
        // to see the button held at the origin first.
        try? await Task.sleep(for: .milliseconds(40))

        let steps = max(1, Int((max(0.05, duration) / CursorMotion.frameInterval).rounded()))
        var last = start
        for step in 1...steps {
            if Task.isCancelled { break }
            let t = Double(step) / Double(steps)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            last = CGPoint(
                x: start.x + (end.x - start.x) * eased,
                y: start.y + (end.y - start.y) * eased
            )
            MouseEvents.post(source, type: dragType, at: last, button: cgButton)
            try? await Task.sleep(for: .seconds(CursorMotion.frameInterval))
        }

        MouseEvents.post(source, type: upType, at: last, button: cgButton)
    }

    // MARK: - Scrolling

    /// Posts real wheel events, which is a different thing from a drag: nothing
    /// is pressed, and the scroll goes to whatever sits under the pointer rather
    /// than to whatever holds focus — hence setting the event's location.
    private func scroll(at point: CGPoint, direction: ScrollDirection, distance: Double, duration: Double) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let steps = max(1, Int((max(0.05, duration) / CursorMotion.frameInterval).rounded()))

        // Wheel deltas are integers, so a small per-step amount would round away
        // to nothing. Tracking what has actually been emitted keeps the total
        // honest however finely the scroll is sliced.
        var emitted = 0.0
        for step in 1...steps {
            if Task.isCancelled { return }

            let progress = Double(step) / Double(steps)
            let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
            let wanted = distance * eased
            let chunk = (wanted - emitted).rounded(.towardZero)

            if chunk != 0 {
                let (vertical, horizontal) = direction.delta(chunk)
                if let event = CGEvent(
                    scrollWheelEvent2Source: source,
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: Int32(vertical),
                    wheel2: Int32(horizontal),
                    wheel3: 0
                ) {
                    event.location = point
                    event.post(tap: .cghidEventTap)
                }
                emitted += abs(chunk)
            }
            try? await Task.sleep(for: .seconds(CursorMotion.frameInterval))
        }
    }

    private func click(at point: CGPoint, button: ClickButton, count: Int) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let (downType, upType, cgButton) = MouseEvents.types(for: button)

        for press in 1...max(1, count) {
            MouseEvents.post(source, type: downType, at: point, button: cgButton, clickState: Int64(press))
            // Hold briefly before releasing: a zero-length press is dropped by
            // some controls, which watch for the button being held at all.
            try? await Task.sleep(for: .milliseconds(20))
            MouseEvents.post(source, type: upType, at: point, button: cgButton, clickState: Int64(press))

            if press < count { try? await Task.sleep(for: .milliseconds(60)) }
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
