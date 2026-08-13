import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Keeps the system idle clock topped up so presence-based apps (Teams, Slack)
/// never flip to Away while the Mac is unattended. Nothing is ever clicked and
/// nothing is typed: the cursor is nudged a few pixels and put straight back,
/// which is all it takes to reset `HIDIdleTime`.
@MainActor
final class MouseMoveService: NSObject {
    static let shared = MouseMoveService()

    /// `kCGAnyInputEventType` — keyboard *and* pointer, so real typing counts as
    /// activity too. It isn't a real enum case, hence the raw value.
    private static let anyInputEvent = CGEventType(rawValue: ~0) ?? .mouseMoved

    private var timer: Timer?
    private var glideTask: Task<Void, Never>?
    private var autoOffTimer: Timer?
    private var autoOffDate: Date?
    private var statusItem: NSStatusItem?
    /// Flipped after every nudge: a cursor parked against a screen edge can't
    /// travel further that way, so the next one tries the opposite direction.
    private var nudgeSign: CGFloat = 1
    private(set) var isActive = false

    private override init() {}

    /// Returns false when the Accessibility permission is missing (and prompts
    /// for it) — without it synthesized events are dropped on the floor.
    @discardableResult
    func start() -> Bool {
        guard !isActive else { return true }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }

        isActive = true
        scheduleTimer()
        scheduleAutoOff()
        showStatusItem()
        return true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        glideTask?.cancel()
        glideTask = nil
        timer?.invalidate()
        timer = nil
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffDate = nil
        removeStatusItem()
    }

    /// Picks up a changed interval or idle-awareness setting without making the
    /// user toggle the feature off and on again.
    func reapply() {
        guard isActive else { return }
        scheduleTimer()
    }

    // MARK: - Scheduling

    /// In idle-aware mode the tick rate is deliberately finer than the interval:
    /// the nudge is driven by *measured* idle time rather than by the timer, so
    /// real input pushes the next nudge out instead of racing it. Otherwise the
    /// timer itself is the schedule.
    private func scheduleTimer() {
        timer?.invalidate()

        let interval = AppState.shared.mouseMoveInterval
        let cadence = AppState.shared.mouseMoveOnlyWhenIdle
            ? max(1, min(5, interval / 4))
            : interval

        let timer = Timer(timeInterval: cadence, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let state = AppState.shared
        if glideTask != nil { return }
        if state.mouseMoveOnlyWhenIdle, idleSeconds() < state.mouseMoveInterval { return }
        nudge(by: CGFloat(state.mouseMoveDistance))
    }

    private func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: Self.anyInputEvent)
    }

    // MARK: - The nudge

    /// Sweeps out and back along an eased path rather than teleporting: a jump
    /// reads as a glitch, and two moves posted in the same instant are coalesced
    /// into no visible movement at all.
    private func nudge(by distance: CGFloat) {
        guard let origin = CGEvent(source: nil)?.location else { return }
        let target = CGPoint(x: origin.x + distance * nudgeSign, y: origin.y)
        nudgeSign *= -1

        glideTask = Task { @MainActor [weak self] in
            await self?.glide(from: origin, to: target)
            await self?.glide(from: target, to: origin)
            self?.glideTask = nil
        }
    }

    private static let frameInterval = 1.0 / 60.0

    private func glide(from: CGPoint, to: CGPoint) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let span = hypot(to.x - from.x, to.y - from.y)
        let steps = max(1, Int((span / AppState.shared.mouseMoveSpeed / Self.frameInterval).rounded()))
        // One step's worth of travel, with headroom: the cursor's reported
        // position can still be a frame behind what we last posted.
        let tolerance = max(5, (span / Double(steps)) * 2)
        var last = from

        for step in 1...steps {
            if Task.isCancelled { return }
            // Our own events land exactly where we put them, so a cursor that
            // has drifted anywhere else means a hand is on the mouse — bail out
            // rather than fight it.
            if let current = CGEvent(source: nil)?.location,
               hypot(current.x - last.x, current.y - last.y) > tolerance {
                return
            }

            let t = Self.ease(Double(step) / Double(steps))
            let point = CGPoint(
                x: from.x + (to.x - from.x) * t,
                y: from.y + (to.y - from.y) * t
            )
            post(source, to: point)
            last = point
            try? await Task.sleep(for: .seconds(Self.frameInterval))
        }
    }

    /// Ease-in-out, so the sweep accelerates away and settles instead of
    /// starting and stopping at full speed.
    private static func ease(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    private func post(_ source: CGEventSource?, to point: CGPoint) {
        CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    // MARK: - Auto-off

    private func scheduleAutoOff() {
        let minutes = AppState.shared.mouseMoveAutoOffMinutes
        guard minutes > 0 else { return }
        let date = Date().addingTimeInterval(TimeInterval(minutes * 60))
        autoOffDate = date
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
                AppState.shared.mouseMoveActive = false
                HUD.show("Auto Mouse Move turned off automatically", symbol: "cursorarrow.motionlines")
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
            systemSymbolName: "cursorarrow.motionlines",
            accessibilityDescription: "Auto Mouse Move is on"
        )
        item.button?.toolTip = "OneBar — Auto Mouse Move is on"

        let menu = NSMenu()
        let title: String
        if let autoOffDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            title = "Auto Mouse Move is On — auto-off at \(formatter.string(from: autoOffDate))"
        } else {
            title = "Auto Mouse Move is On"
        }
        let info = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        let turnOff = NSMenuItem(title: "Turn Off Auto Mouse Move", action: #selector(turnOffFromMenu), keyEquivalent: "")
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
        AppState.shared.mouseMoveActive = false
    }
}
