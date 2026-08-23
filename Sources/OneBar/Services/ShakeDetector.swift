import AppKit
import Foundation

/// Watches for the cursor being shaken while a drag is in flight, and asks
/// `ShelfManager` for a shelf when it sees one.
///
/// Deliberately built on `NSEvent` mouse monitors and nothing else. Global
/// **mouse** monitors need no permission — only keyboard ones drag in Input
/// Monitoring, which is why `HotkeyManager` goes through Carbon instead. A
/// `CGEvent` tap would work too and would cost a permission grant for nothing.
@MainActor
final class ShakeDetector {
    static let shared = ShakeDetector()

    private struct Sample {
        let time: TimeInterval
        let point: NSPoint
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var samples: [Sample] = []
    private var dragPasteboardBaseline = 0
    private var isDragSession = false
    private var isIgnoredSource = false
    private var lastFired: TimeInterval = 0

    /// Long enough to hold a whole shake, short enough that two separate
    /// wiggles a second apart never add up to one.
    private let window: TimeInterval = 0.6
    private let cooldown: TimeInterval = 1.2

    private init() {}

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // The global monitor never sees our own windows, and a drag that starts
        // on a shelf has to be tracked too — if only to be ignored.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if let self { self.handle(event) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        reset()
    }

    /// Called when the enable/sensitivity preferences change.
    func restart() {
        stop()
        if AppState.shared.shelfEnabled && AppState.shared.shelfShakeEnabled { start() }
    }

    // MARK: - Event handling

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            reset()
            dragPasteboardBaseline = NSPasteboard(name: .drag).changeCount
        case .leftMouseDragged:
            track(event)
        case .leftMouseUp:
            reset()
        default:
            break
        }
    }

    private func track(_ event: NSEvent) {
        guard AppState.shared.shelfEnabled, AppState.shared.shelfShakeEnabled else { return }

        if !isDragSession {
            // A mouse drag is not a *file* drag. Scrubbing a video, rubber-band
            // selecting on the Desktop and dragging a window by its title bar
            // all move the cursor with the button down and none of them touch
            // the drag pasteboard, which AppKit bumps the moment a real drag
            // session declares its types.
            guard NSPasteboard(name: .drag).changeCount != dragPasteboardBaseline else { return }
            isDragSession = true
            isIgnoredSource = ShelfManager.shared.isDraggingOut || isFrontmostAppIgnored()
        }
        guard !isIgnoredSource else { return }

        let now = ProcessInfo.processInfo.systemUptime
        samples.append(Sample(time: now, point: NSEvent.mouseLocation))
        samples.removeAll { now - $0.time > window }

        guard now - lastFired > cooldown, samples.count >= 6 else { return }

        let sensitivity = AppState.shared.shelfShakeSensitivity
        let needed = sensitivity.reversals
        let leg = sensitivity.minimumLeg
        let horizontal = reversals(in: samples.map(\.point.x), minimumLeg: leg)
        let vertical = reversals(in: samples.map(\.point.y), minimumLeg: leg)

        guard max(horizontal, vertical) >= needed else { return }

        lastFired = now
        samples.removeAll()
        ShelfManager.shared.newShelf(at: NSEvent.mouseLocation)
    }

    private func reset() {
        samples.removeAll()
        isDragSession = false
        isIgnoredSource = false
    }

    private func isFrontmostAppIgnored() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return ShelfManager.shared.ignoredApps.contains { $0.bundleID == bundleID }
    }

    /// Counts direction changes along one axis, ignoring any that arrive before
    /// the cursor has travelled `minimumLeg` since the last extreme. Anchoring
    /// on the extreme rather than the previous sample is what makes tremor and
    /// a slow curved drag score zero.
    private func reversals(in values: [CGFloat], minimumLeg: CGFloat) -> Int {
        guard let first = values.first else { return 0 }
        var count = 0
        var direction = 0
        var anchor = first

        for value in values.dropFirst() {
            let delta = value - anchor
            if delta == 0 { continue }
            let sign = delta > 0 ? 1 : -1

            if direction == 0 {
                // No direction established yet, so the anchor stays put until
                // the cursor has actually gone somewhere.
                if abs(delta) >= minimumLeg {
                    direction = sign
                    anchor = value
                }
            } else if sign == direction {
                anchor = value
            } else if abs(delta) >= minimumLeg {
                count += 1
                direction = sign
                anchor = value
            }
        }
        return count
    }
}

