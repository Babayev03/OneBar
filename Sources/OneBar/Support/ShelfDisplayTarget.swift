import AppKit

/// A snapshot of the connected displays, also usable by geometry tests.
struct ShelfDisplay {
    let id: CGDirectDisplayID
    let frame: NSRect
    let visibleFrame: NSRect

    @MainActor
    static var connected: [ShelfDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            return ShelfDisplay(
                id: number.uint32Value,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
    }
}

/// Display affinity lasts for the shelf's session. Only an explicit window
/// move or a disconnected display can change it; growing or retracting a
/// window across a display boundary cannot.
struct ShelfDisplayTarget {
    private(set) var displayID: CGDirectDisplayID?
    private(set) var placementPoint: NSPoint

    init(at point: NSPoint, displays: [ShelfDisplay]) {
        placementPoint = point
        displayID = (displays.first { $0.frame.contains(point) } ?? displays.first)?.id
    }

    @MainActor
    static func capture(at point: NSPoint? = nil) -> ShelfDisplayTarget {
        ShelfDisplayTarget(at: point ?? NSEvent.mouseLocation, displays: ShelfDisplay.connected)
    }

    mutating func resolve(
        for frame: NSRect,
        displays: [ShelfDisplay],
        cursor: NSPoint
    ) -> NSRect? {
        if let display = displays.first(where: { $0.id == displayID }) {
            return display.visibleFrame
        }
        // Keep the fallback as the new affinity, too. Moving the cursor later
        // must not move a recovered shelf to a different display.
        return followWindow(frame, displays: displays, cursor: cursor)
    }

    @discardableResult
    mutating func followWindow(
        _ frame: NSRect,
        displays: [ShelfDisplay],
        cursor: NSPoint
    ) -> NSRect? {
        guard let visible = ShelfWindowGeometry.targetVisibleFrame(
            for: frame,
            visibleFrames: displays.map(\.visibleFrame),
            cursor: cursor
        ), let display = displays.first(where: { $0.visibleFrame == visible })
        else { return nil }
        displayID = display.id
        placementPoint = NSPoint(x: frame.midX, y: frame.midY)
        return visible
    }
}
