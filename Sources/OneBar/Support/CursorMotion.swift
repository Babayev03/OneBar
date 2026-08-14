import AppKit
import CoreGraphics
import Foundation

/// Shared cursor-movement primitives. Auto Mouse Move and Auto Click both drive
/// the pointer through here, so the two behave identically: an eased multi-frame
/// path — a single jump gets coalesced into no visible movement at all — that
/// gives up the moment the cursor stops being where we put it.
enum CursorMotion {
    static let frameInterval = 1.0 / 60.0

    /// Read back through `CGEvent` rather than `NSEvent.mouseLocation`: this is
    /// already in the flipped, top-left-origin space that posted events use, so
    /// multi-monitor setups need no coordinate conversion.
    static var location: CGPoint? { CGEvent(source: nil)?.location }

    /// Pins a destination inside the display `reference` sits on. A point past
    /// the edge gets clamped by the WindowServer anyway — and the cursor would
    /// then not be where we posted it, which `glide` reads as a hand on the
    /// mouse and gives up on.
    static func clamp(_ point: CGPoint, onDisplayContaining reference: CGPoint, margin: CGFloat = 6) -> CGPoint {
        let screens = NSScreen.screens.map { screen -> CGRect in
            CGRect(origin: screen.eventSpaceOrigin, size: screen.frame.size)
        }
        let bounds = screens.first { $0.contains(reference) } ?? screens.first ?? .zero
        guard bounds.width > margin * 2, bounds.height > margin * 2 else { return point }
        let usable = bounds.insetBy(dx: margin, dy: margin)
        return CGPoint(
            x: min(max(point.x, usable.minX), usable.maxX),
            y: min(max(point.y, usable.minY), usable.maxY)
        )
    }

    /// Walks the cursor from `from` to `to`, returning false if a real hand took
    /// over partway and the move was abandoned.
    /// - Parameter curve: how far the path bows off the straight line, as a
    ///   fraction of the distance travelled. 0 draws a straight line.
    @discardableResult
    static func glide(from: CGPoint, to: CGPoint, speed: Double, curve: Double = 0) async -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let span = hypot(to.x - from.x, to.y - from.y)
        guard span > 0 else { return true }

        let steps = max(1, Int((span / max(1, speed) / frameInterval).rounded()))
        // One step's worth of travel, with headroom: the cursor's reported
        // position can still be a frame behind what we last posted.
        let tolerance = max(5, (span / Double(steps)) * 2)
        let control = controlPoint(from: from, to: to, span: span, curve: curve)
        var last = from

        for step in 1...steps {
            if Task.isCancelled { return false }
            // Our own events land exactly where we put them, so a cursor that has
            // drifted anywhere else means a hand is on the mouse — bail out
            // rather than fight it.
            if let current = location, hypot(current.x - last.x, current.y - last.y) > tolerance {
                return false
            }

            let t = ease(Double(step) / Double(steps))
            let point = control.map { bezier(from: from, control: $0, to: to, t: t) }
                ?? CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            post(source, to: point)
            last = point
            try? await Task.sleep(for: .seconds(frameInterval))
        }
        return true
    }

    /// Offsets the midpoint perpendicular to the direction of travel, which is
    /// what turns the straight line into an arc. The magnitude and side are both
    /// random so repeated trips between the same two points don't retrace one
    /// identical path.
    private static func controlPoint(from: CGPoint, to: CGPoint, span: Double, curve: Double) -> CGPoint? {
        guard curve > 0 else { return nil }
        let normalX = -(to.y - from.y) / span
        let normalY = (to.x - from.x) / span
        let bow = span * curve * Double.random(in: 0.4...1) * (Bool.random() ? 1 : -1)
        return CGPoint(
            x: (from.x + to.x) / 2 + normalX * bow,
            y: (from.y + to.y) / 2 + normalY * bow
        )
    }

    private static func bezier(from: CGPoint, control: CGPoint, to: CGPoint, t: Double) -> CGPoint {
        let inverse = 1 - t
        let a = inverse * inverse
        let b = 2 * inverse * t
        let c = t * t
        return CGPoint(
            x: a * from.x + b * control.x + c * to.x,
            y: a * from.y + b * control.y + c * to.y
        )
    }

    /// Ease-in-out, so a move accelerates away and settles instead of starting
    /// and stopping at full speed.
    private static func ease(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    private static func post(_ source: CGEventSource?, to point: CGPoint) {
        CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }
}
