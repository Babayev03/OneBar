import AppKit
import Foundation

/// Recognizes a shake from points supplied by `ShelfDragObserver`.
///
/// It deliberately owns no event monitors. Notch activation must continue to
/// observe real drags when shake recognition is disabled or the source app is
/// on the shake ignore list.
@MainActor
final class ShakeDetector {
    static let shared = ShakeDetector()

    private struct Sample {
        let time: TimeInterval
        let point: NSPoint
    }

    private var samples: [Sample] = []
    private var ignoresCurrentDrag = false
    private var lastFired: TimeInterval = 0

    private let window: TimeInterval = 0.6
    private let cooldown: TimeInterval = 1.2

    private init() {}

    func dragBegan(ignored: Bool) {
        samples.removeAll()
        ignoresCurrentDrag = ignored
    }

    func dragMoved(to point: NSPoint) {
        guard AppState.shared.shelfEnabled,
              AppState.shared.shelfShakeEnabled,
              !ignoresCurrentDrag
        else { return }

        let now = ProcessInfo.processInfo.systemUptime
        samples.append(Sample(time: now, point: point))
        samples.removeAll { now - $0.time > window }

        guard now - lastFired > cooldown, samples.count >= 6 else { return }

        let sensitivity = AppState.shared.shelfShakeSensitivity
        let horizontal = reversals(in: samples.map(\.point.x), minimumLeg: sensitivity.minimumLeg)
        let vertical = reversals(in: samples.map(\.point.y), minimumLeg: sensitivity.minimumLeg)
        guard max(horizontal, vertical) >= sensitivity.reversals else { return }

        lastFired = now
        samples.removeAll()
        ShelfManager.shared.newShelf(at: point)
    }

    func dragEnded() {
        samples.removeAll()
        ignoresCurrentDrag = false
    }

    /// Counts direction changes while ignoring tremor shorter than one leg.
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
