import AppKit

/// Pure window calculations shared by shelf controllers and unit tests.
enum ShelfWindowGeometry {
    static let margin: CGFloat = 8
    /// Interactive strip below the camera housing. Nothing is drawn here —
    /// it only widens the AppKit drop destination, since a target confined to
    /// the obscured housing is awkward to hit.
    static let notchTargetDepth: CGFloat = 12
    /// Transparent room for the bloom to fade in. At `notchBloomBlur` the
    /// glow is fully gone by ~28pt, so this must stay above that or the
    /// window edge cuts a straight line through it.
    static let notchGlowOutset: CGFloat = 30
    /// The bottom corners of the notch outline. Fitted to Dropover's rim,
    /// whose measured edge offsets (0.5, 2.0, 3.5, 6.0pt at 26, 29, 31, 33pt
    /// deep) match a 12pt arc to within a third of a point.
    static let notchCornerRadius: CGFloat = 12
    /// Blur on the ambient bloom. Calibrated by rendering this exact shape
    /// offscreen and matching the falloff of a Dropover screenshot: at 14 the
    /// alpha runs 0.29 / 0.14 / 0.04 at 8 / 15 / 23pt from the notch edge,
    /// against Dropover's 0.29 / 0.14 / 0.05.
    static let notchBloomBlur: CGFloat = 14
    /// Rim thickness when the drag is over the notch. Centred on the notch
    /// boundary, so half shows beside the housing and half hides behind it —
    /// Dropover's rim measured 660.0...665.5 around a notch edge at 663.
    static let notchRimWidth: CGFloat = 5
    static let notchActivationDepth: CGFloat = notchTargetDepth + notchGlowOutset
    static let collapseStackOffset: CGFloat = 124

    @MainActor
    static var hasNotchedDisplay: Bool {
        NSScreen.screens.contains { screen in
            guard screen.safeAreaInsets.top > 0,
                  let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea
            else { return false }
            return right.minX > left.maxX
        }
    }

    /// A shelf restricted to its current Space must not use
    /// `.moveToActiveSpace`: that behavior follows the user's Space switch and
    /// briefly draws the window in both desktops during the swipe animation.
    static func collectionBehavior(
        keepInCurrentSpace: Bool
    ) -> NSWindow.CollectionBehavior {
        keepInCurrentSpace
            ? [.fullScreenAuxiliary]
            : [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// Includes the obscured camera-housing rectangle plus a small visible and
    /// interactive strip immediately below it. Content drawn only inside the
    /// housing cannot be seen and isn't a reliable AppKit drag destination.
    ///
    /// The housing needs no estimating. `NSScreen.safeAreaInsets` is defined
    /// as "the obscured distance from each edge of the screen" and the two
    /// auxiliary areas as the parts above it that are "also unobscured", so
    /// the gap between them is exactly the housing and `safeAreaTop` is
    /// exactly its depth. Do not reintroduce a fudge factor here — one was
    /// fitted from a phone photograph of the screen and drew the highlight
    /// visibly narrower than the notch on both sides.
    static func notchTargetRect(
        screenFrame: NSRect,
        safeAreaTop: CGFloat,
        auxiliaryLeft: NSRect,
        auxiliaryRight: NSRect,
        activationDepth: CGFloat = notchActivationDepth
    ) -> NSRect? {
        let housingWidth = auxiliaryRight.minX - auxiliaryLeft.maxX
        guard safeAreaTop > 0, housingWidth > 0, activationDepth >= 0 else { return nil }
        return NSRect(
            x: auxiliaryLeft.maxX - notchGlowOutset,
            y: screenFrame.maxY - safeAreaTop - activationDepth,
            width: housingWidth + (notchGlowOutset * 2),
            height: safeAreaTop + activationDepth
        )
    }

    static func shouldSnap(
        isRealUserMove: Bool,
        enabled: Bool,
        isCollapsed: Bool,
        commandSuppressed: Bool
    ) -> Bool {
        isRealUserMove && enabled && !isCollapsed && !commandSuppressed
    }

    static func clamped(
        _ frame: NSRect,
        to visible: NSRect,
        margin: CGFloat = margin
    ) -> NSRect {
        var result = frame
        let maximumX = max(visible.minX + margin, visible.maxX - frame.width - margin)
        let maximumY = max(visible.minY + margin, visible.maxY - frame.height - margin)
        result.origin.x = min(max(frame.minX, visible.minX + margin), maximumX)
        result.origin.y = min(max(frame.minY, visible.minY + margin), maximumY)
        return result
    }

    static func collapsed(
        _ frame: NSRect,
        mode: ShelfCollapse,
        edge: ShelfEdge,
        in visible: NSRect,
        stackDepth: Int = 0
    ) -> NSRect {
        var result = frame
        let baseX = edge == .left
            ? visible.minX - frame.width + mode.visibleWidth
            : visible.maxX - mode.visibleWidth
        let maximumShift = max(0, visible.width - mode.visibleWidth - margin)
        let stackShift = min(CGFloat(max(0, stackDepth)) * collapseStackOffset, maximumShift)
        result.origin.x = baseX + (edge == .left ? stackShift : -stackShift)
        let maximumY = max(visible.minY + margin, visible.maxY - frame.height - margin)
        result.origin.y = min(max(frame.minY, visible.minY + margin), maximumY)
        return result
    }

    /// Only the exposed strip of a collapsed card should react to hover. This
    /// prevents every shelf in an overlapping stack from opening together.
    static func collapsedInteractionFrame(
        _ frame: NSRect,
        mode: ShelfCollapse,
        edge: ShelfEdge,
        stackDepth: Int
    ) -> NSRect {
        let width = min(
            frame.width,
            stackDepth == 0 ? mode.visibleWidth : collapseStackOffset
        )
        return NSRect(
            x: edge == .left ? frame.maxX - width : frame.minX,
            y: frame.minY,
            width: width,
            height: frame.height
        )
    }

    /// The first free row down an edge, so retracted shelves fill the column
    /// before any of them starts stacking in front of another. Returns nil when
    /// the column has no room left, which is the caller's cue to stack.
    static func firstFreeRow(
        height: CGFloat,
        in visible: NSRect,
        occupiedRows: [ClosedRange<CGFloat>],
        spacing: CGFloat = 10
    ) -> CGFloat? {
        let top = visible.maxY - height - margin
        let floor = visible.minY + margin
        guard top >= floor else { return nil }

        var candidate = top
        // Each pass drops below whatever is in the way, so the search walks down
        // the edge rather than looping between two overlapping neighbours.
        for _ in 0..<(occupiedRows.count + 1) {
            // Strict comparisons, so a neighbour exactly `spacing` away is a
            // tidy gap rather than a collision that pushes this shelf past it.
            let low = candidate - spacing
            let high = candidate + height + spacing
            let blocking = occupiedRows.filter { $0.lowerBound < high && $0.upperBound > low }
            guard let lowest = blocking.map(\.lowerBound).min() else {
                return candidate >= floor ? candidate : nil
            }
            candidate = lowest - spacing - height
            guard candidate >= floor else { return nil }
        }
        return candidate >= floor ? candidate : nil
    }

    static func rested(_ frame: NSRect, edge: ShelfEdge, in visible: NSRect) -> NSRect {
        var result = clamped(frame, to: visible)
        result.origin.x = edge == .left
            ? visible.minX + margin
            : visible.maxX - frame.width - margin
        return result
    }

    /// Hover-peek is flush with the display edge so there is no dead strip
    /// that repeatedly fires leave/enter while the shelf is animating.
    static func edgeAttached(_ frame: NSRect, edge: ShelfEdge, in visible: NSRect) -> NSRect {
        var result = clamped(frame, to: visible)
        result.origin.x = edge == .left
            ? visible.minX
            : visible.maxX - frame.width
        return result
    }

    /// Expands a card away from the cards in front of it. A deeper card keeps
    /// the outer edge of its exposed strip fixed instead of jumping into the
    /// depth-zero card's position.
    static func peeked(
        _ frame: NSRect,
        mode: ShelfCollapse,
        edge: ShelfEdge,
        in visible: NSRect,
        stackDepth: Int
    ) -> NSRect {
        guard stackDepth > 0 else {
            return edgeAttached(frame, edge: edge, in: visible)
        }
        let strip = collapsedInteractionFrame(
            frame,
            mode: mode,
            edge: edge,
            stackDepth: stackDepth
        )
        var result = clamped(frame, to: visible)
        result.origin.x = edge == .left
            ? strip.minX
            : strip.maxX - frame.width
        return result
    }

    /// Finds the closest free placement to the requested location. Candidates
    /// sit beside the edges of existing shelves, which naturally makes top-
    /// corner notch shelves cascade downward before starting another column.
    static func avoidingOverlap(
        _ frame: NSRect,
        in visible: NSRect,
        occupiedFrames: [NSRect],
        spacing: CGFloat = 12
    ) -> NSRect {
        let preferred = clamped(frame, to: visible)
        let obstacles = occupiedFrames.filter { !$0.intersection(visible).isNull }
        guard obstacles.contains(where: { padded($0, by: spacing).intersects(preferred) })
        else { return preferred }

        var xCandidates = [preferred.minX, visible.minX + margin, visible.maxX - frame.width - margin]
        var yCandidates = [preferred.minY, visible.minY + margin, visible.maxY - frame.height - margin]
        for obstacle in obstacles {
            xCandidates.append(contentsOf: [
                obstacle.minX - frame.width - spacing,
                obstacle.maxX + spacing
            ])
            yCandidates.append(contentsOf: [
                obstacle.minY - frame.height - spacing,
                obstacle.maxY + spacing
            ])
        }

        let candidates = xCandidates.flatMap { x in
            yCandidates.map { y in
                clamped(NSRect(origin: NSPoint(x: x, y: y), size: frame.size), to: visible)
            }
        }
        let freeCandidates = candidates.filter { candidate in
                !obstacles.contains { padded($0, by: spacing).intersects(candidate) }
            }
        // Staying in the same column is important for edge retraction: a
        // horizontal offset disappears when both shelves collapse against the
        // same edge, while a vertical offset survives.
        let sameColumn = freeCandidates.filter { abs($0.minX - preferred.minX) < 0.5 }
        return (sameColumn.isEmpty ? freeCandidates : sameColumn)
            .min {
                distanceSquared($0.origin, preferred.origin)
                    < distanceSquared($1.origin, preferred.origin)
            }
            ?? preferred
    }

    static func snapped(
        _ frame: NSRect,
        to visible: NSRect,
        otherFrames: [NSRect],
        threshold: CGFloat = 12
    ) -> NSRect {
        let relevant = otherFrames.filter { $0.intersects(visible) }
        var xCandidates: [CGFloat] = [visible.minX + margin, visible.maxX - frame.width - margin]
        var yCandidates: [CGFloat] = [visible.minY + margin, visible.maxY - frame.height - margin]

        for other in relevant {
            xCandidates += [
                other.minX,
                other.maxX - frame.width,
                other.maxX + margin,
                other.minX - frame.width - margin
            ]
            yCandidates += [
                other.minY,
                other.maxY - frame.height,
                other.maxY + margin,
                other.minY - frame.height - margin
            ]
        }

        var result = frame
        if let x = nearest(to: frame.minX, in: xCandidates), abs(x - frame.minX) <= threshold {
            result.origin.x = x
        }
        if let y = nearest(to: frame.minY, in: yCandidates), abs(y - frame.minY) <= threshold {
            result.origin.y = y
        }
        return clamped(result, to: visible)
    }

    /// Chooses the display containing most of the shelf. If that display was
    /// disconnected, the display under the cursor is the safe fallback.
    static func targetVisibleFrame(
        for frame: NSRect,
        visibleFrames: [NSRect],
        cursor: NSPoint
    ) -> NSRect? {
        guard !visibleFrames.isEmpty else { return nil }
        if let best = visibleFrames.max(by: {
            intersectionArea(frame, $0) < intersectionArea(frame, $1)
        }), intersectionArea(frame, best) > 0 {
            return best
        }
        return visibleFrames.first(where: { $0.contains(cursor) }) ?? visibleFrames.first
    }

    private static func nearest(to value: CGFloat, in candidates: [CGFloat]) -> CGFloat? {
        candidates.min { abs($0 - value) < abs($1 - value) }
    }

    private static func padded(_ frame: NSRect, by amount: CGFloat) -> NSRect {
        frame.insetBy(dx: -amount, dy: -amount)
    }

    private static func distanceSquared(_ first: NSPoint, _ second: NSPoint) -> CGFloat {
        let dx = first.x - second.x
        let dy = first.y - second.y
        return dx * dx + dy * dy
    }

    private static func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
