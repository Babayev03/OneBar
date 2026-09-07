import AppKit
import Testing
@testable import OneBar

@Suite("Shelf display affinity")
struct ShelfDisplayTargetTests {
    private func display(_ id: CGDirectDisplayID, _ frame: NSRect) -> ShelfDisplay {
        ShelfDisplay(id: id, frame: frame, visibleFrame: frame)
    }

    @Test("Shake at a stepped horizontal boundary keeps the trigger display")
    func horizontalBoundary() throws {
        let left = display(1, NSRect(x: 0, y: 0, width: 1_000, height: 800))
        let right = display(2, NSRect(x: 1_000, y: -400, width: 1_000, height: 800))
        let point = NSPoint(x: 995, y: 5)
        let proposed = NSRect(x: 845, y: -60, width: 300, height: 130)
        // This is the former bug: most of the centered shelf overlaps right,
        // even though the shake happened on left.
        #expect(ShelfWindowGeometry.targetVisibleFrame(
            for: proposed, visibleFrames: [left.visibleFrame, right.visibleFrame], cursor: point
        ) == right.visibleFrame)
        var target = ShelfDisplayTarget(at: point, displays: [left, right])
        let resolved = target.resolve(
            for: proposed, displays: [left, right], cursor: NSPoint(x: 1_500, y: 100)
        )
        let visible = try #require(resolved)
        let placed = ShelfWindowGeometry.clamped(proposed, to: visible)
        #expect(visible == left.visibleFrame)
        #expect(left.visibleFrame.contains(placed))
        #expect(target.displayID == left.id)
    }

    @Test("Growing down across a vertical boundary cannot change displays")
    func verticalGrowth() throws {
        let lower = display(1, NSRect(x: 0, y: 0, width: 1_000, height: 800))
        let upper = display(2, NSRect(x: 0, y: 800, width: 1_000, height: 800))
        var target = ShelfDisplayTarget(at: NSPoint(x: 500, y: 820), displays: [lower, upper])
        let grown = NSRect(x: 350, y: 498, width: 300, height: 440)
        #expect(ShelfWindowGeometry.targetVisibleFrame(
            for: grown, visibleFrames: [lower.visibleFrame, upper.visibleFrame], cursor: .zero
        ) == lower.visibleFrame)
        let resolved = target.resolve(for: grown, displays: [lower, upper], cursor: .zero)
        let visible = try #require(resolved)
        let clamped = ShelfWindowGeometry.clamped(grown, to: visible)
        #expect(upper.visibleFrame.contains(clamped))
        for edge in [ShelfEdge.left, .right] {
            let retracted = ShelfWindowGeometry.collapsed(clamped, mode: .retracted, edge: edge, in: visible)
            #expect(retracted.minY >= upper.visibleFrame.minY)
            #expect(retracted.minX == (edge == .left ? -204 : 904))
        }
    }

    @Test("An asynchronous drop retains its display and cursor placement")
    func deferredDrop() {
        let left = display(1, NSRect(x: -1_000, y: 0, width: 1_000, height: 800))
        let right = display(2, NSRect(x: 0, y: 0, width: 1_000, height: 800))
        let point = NSPoint(x: -500, y: 795)
        var captured = ShelfDisplayTarget(at: point, displays: [left, right])
        #expect(captured.resolve(
            for: NSRect(x: 0, y: 0, width: 300, height: 130),
            displays: [left, right], cursor: NSPoint(x: 600, y: 400)
        ) == left.visibleFrame)
        #expect(captured.placementPoint == point)
    }

    @Test("Offscreen collapsed frames and stacked hover reveals retain affinity")
    func collapseAndHover() throws {
        let left = display(1, NSRect(x: 0, y: 0, width: 1_000, height: 800))
        let right = display(2, NSRect(x: 1_000, y: 0, width: 1_000, height: 800))
        var target = ShelfDisplayTarget(at: NSPoint(x: 900, y: 400), displays: [left, right])
        let frame = NSRect(x: 692, y: 300, width: 300, height: 220)
        for mode in [ShelfCollapse.docked, .retracted] {
            for depth in 0...3 {
                let collapsed = ShelfWindowGeometry.collapsed(
                    frame, mode: mode, edge: .right, in: left.visibleFrame, stackDepth: depth
                )
                let resolved = target.resolve(
                    for: collapsed, displays: [left, right], cursor: NSPoint(x: 1_500, y: 400)
                )
                let visible = try #require(resolved)
                #expect(visible == left.visibleFrame)
                let revealed = ShelfWindowGeometry.peeked(
                    collapsed, mode: mode, edge: .right, in: visible, stackDepth: depth
                )
                #expect(left.visibleFrame.contains(revealed))
                #expect(target.displayID == left.id)
            }
        }
    }

    @Test("Deliberately moving a shelf updates its retraction display")
    func userMove() {
        let left = display(1, NSRect(x: 0, y: 0, width: 1_000, height: 800))
        let right = display(2, NSRect(x: 1_000, y: 0, width: 1_000, height: 800))
        var target = ShelfDisplayTarget(at: NSPoint(x: 500, y: 400), displays: [left, right])
        let moved = NSRect(x: 1_200, y: 300, width: 300, height: 220)
        target.followWindow(moved, displays: [left, right], cursor: .zero)
        #expect(target.displayID == right.id)
        #expect(target.resolve(for: moved, displays: [left, right], cursor: .zero) == right.visibleFrame)
        #expect(target.placementPoint == NSPoint(x: moved.midX, y: moved.midY))
    }

    @Test("Rearrangement follows display identity and disconnection retains a fallback")
    func topologyChanges() {
        let first = display(1, NSRect(x: 0, y: 0, width: 1_000, height: 800))
        let second = display(2, NSRect(x: 1_000, y: 0, width: 1_000, height: 800))
        var target = ShelfDisplayTarget(at: NSPoint(x: 1_500, y: 400), displays: [first, second])
        let frame = NSRect(x: 1_350, y: 300, width: 300, height: 220)
        let rearranged = display(2, NSRect(x: 0, y: 800, width: 1_000, height: 800))
        #expect(target.resolve(for: frame, displays: [first, rearranged], cursor: .zero) == rearranged.visibleFrame)
        #expect(target.resolve(for: frame, displays: [], cursor: .zero) == nil)
        #expect(target.displayID == second.id)
        #expect(target.resolve(for: frame, displays: [first], cursor: .zero) == first.visibleFrame)
        // Reconnecting the old screen or moving the pointer cannot steal it.
        #expect(target.resolve(for: frame, displays: [first, second], cursor: NSPoint(x: 1_500, y: 400)) == first.visibleFrame)
        #expect(target.displayID == first.id)
    }

    @Test("The full display, including its menu bar, selects the creation target")
    func menuBarCreation() {
        let first = display(1, NSRect(x: 0, y: 0, width: 1_000, height: 800))
        let notched = ShelfDisplay(
            id: 2,
            frame: NSRect(x: 0, y: 800, width: 1_000, height: 800),
            visibleFrame: NSRect(x: 0, y: 824, width: 1_000, height: 738)
        )
        var target = ShelfDisplayTarget(at: NSPoint(x: 500, y: 1_580), displays: [first, notched])
        #expect(target.displayID == notched.id)
        #expect(target.resolve(for: .zero, displays: [first, notched], cursor: .zero) == notched.visibleFrame)
    }
}
