import AppKit

/// A black window laid over a display, its opacity standing in for brightness.
///
/// This is the only thing that dims an AirPlay or Sidecar screen. Those have no
/// backlight to command and no gamma table that survives the trip — a gamma
/// write is accepted and then quietly ignored — but they still composite
/// windows, so a window is what dims them.
@MainActor
final class ShadeController {
    static let shared = ShadeController()

    /// Never fully black: a screen you can't see is a screen you can't undim.
    private static let maxOpacity = 0.9

    private var shades: [CGDirectDisplayID: NSWindow] = [:]

    private init() {}

    /// `brightness` is the usual 0…1; 1 removes the shade entirely rather than
    /// leaving a fully transparent window sitting over the screen.
    func setBrightness(_ brightness: Double, for id: CGDirectDisplayID) {
        guard brightness < 1 else {
            remove(id)
            return
        }
        guard let shade = shade(for: id) else { return }
        shade.contentView?.alphaValue = (1 - brightness) * Self.maxOpacity
    }

    func brightness(for id: CGDirectDisplayID) -> Double {
        guard let alpha = shades[id]?.contentView?.alphaValue else { return 1 }
        return 1 - Double(alpha) / Self.maxOpacity
    }

    /// Screens move and resize; a shade pinned to yesterday's frame would leave
    /// a bright strip down the side.
    func reposition() {
        for (id, shade) in shades {
            guard let screen = screen(for: id) else {
                remove(id)
                continue
            }
            shade.setFrame(screen.frame, display: true)
        }
    }

    func remove(_ id: CGDirectDisplayID) {
        shades.removeValue(forKey: id)?.orderOut(nil)
    }

    func removeAll() {
        for id in shades.keys { remove(id) }
    }

    private func shade(for id: CGDirectDisplayID) -> NSWindow? {
        if let existing = shades[id] { return existing }
        guard let screen = screen(for: id) else { return nil }

        let shade = NSWindow(contentRect: screen.frame, styleMask: [], backing: .buffered, defer: false)
        shade.backgroundColor = .clear
        shade.isOpaque = false
        shade.hasShadow = false
        // Above everything, menubar included — a shade with a bright strip
        // across the top isn't a brightness control.
        shade.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        // Never takes a click: this sits over whatever you're working in.
        shade.ignoresMouseEvents = true
        shade.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        shade.contentView?.wantsLayer = true
        shade.contentView?.layer?.backgroundColor = NSColor.black.cgColor
        shade.contentView?.alphaValue = 0
        shade.setFrame(screen.frame, display: true)
        shade.orderFrontRegardless()

        shades[id] = shade
        return shade
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }
}
