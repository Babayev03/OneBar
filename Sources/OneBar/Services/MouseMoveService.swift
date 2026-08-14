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

        let state = AppState.shared
        let interval = state.mouseMoveInterval

        // On a fixed schedule the interval is the only thing anyone could watch,
        // so in natural mode the timer is one-shot and re-armed with a fresh
        // interval each time. Idle mode already ticks faster than the interval
        // and gates on measured idle time, so it stays repeating.
        let oneShot = state.mouseMoveNatural && !state.mouseMoveOnlyWhenIdle
        let cadence = state.mouseMoveOnlyWhenIdle
            ? max(1, min(5, interval / 4))
            : (state.mouseMoveNatural ? varied(interval) : interval)

        let timer = Timer(timeInterval: cadence, repeats: !oneShot) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let state = AppState.shared
        defer {
            // Re-arm the one-shot schedule whether or not this tick nudged.
            if state.mouseMoveNatural, !state.mouseMoveOnlyWhenIdle, isActive { scheduleTimer() }
        }

        if glideTask != nil { return }
        if state.mouseMoveOnlyWhenIdle {
            // Jittered threshold, rolled fresh each time it fires, so the gap
            // between nudges isn't the same number over and over.
            let threshold = state.mouseMoveNatural ? varied(state.mouseMoveInterval) : state.mouseMoveInterval
            if idleSeconds() < threshold { return }
        }
        nudge(by: CGFloat(state.mouseMoveDistance))
    }

    private func varied(_ value: Double) -> Double {
        max(1, value * .random(in: 0.85...1.25))
    }

    private func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: Self.anyInputEvent)
    }

    // MARK: - The nudge

    /// Sweeps out and back rather than teleporting: a jump reads as a glitch,
    /// and two moves posted in the same instant are coalesced into no visible
    /// movement at all. `CursorMotion` handles the pathing.
    private func nudge(by distance: CGFloat) {
        guard let origin = CursorMotion.location else { return }
        let natural = AppState.shared.mouseMoveNatural

        // A dead-straight horizontal sweep of a fixed length is the giveaway, so
        // natural mode tilts the direction and varies how far it goes.
        let travel = natural ? distance * .random(in: 0.7...1.15) : distance
        let angle = natural ? Double.random(in: -0.45...0.45) : 0
        let target = CursorMotion.clamp(
            CGPoint(
                x: origin.x + travel * nudgeSign * cos(angle),
                y: origin.y + travel * sin(angle)
            ),
            onDisplayContaining: origin
        )
        nudgeSign *= -1

        glideTask = Task { @MainActor [weak self] in
            let speed = AppState.shared.mouseMoveSpeed
            // The control point is randomised per call, so the way back is a
            // different arc from the way out rather than a retraced line.
            let curve = natural ? 0.16 : 0
            // Only come back if the outward trip finished — if a hand took over
            // mid-sweep, dragging the cursor home would be exactly the fight the
            // abort exists to avoid.
            if await CursorMotion.glide(from: origin, to: target, speed: speed, curve: curve) {
                await CursorMotion.glide(from: target, to: origin, speed: speed, curve: curve)
            }
            self?.glideTask = nil
        }
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
