import CoreGraphics
import Foundation

/// Synthetic mouse-button events, shared by the click sequence and turbo mode so
/// both post exactly the same thing.
enum MouseEvents {
    static func types(for button: ClickButton) -> (down: CGEventType, up: CGEventType, button: CGMouseButton) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp, .left)
        case .right: return (.rightMouseDown, .rightMouseUp, .right)
        case .middle: return (.otherMouseDown, .otherMouseUp, .center)
        }
    }

    static func dragType(for button: ClickButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }

    static func post(
        _ source: CGEventSource?,
        type: CGEventType,
        at point: CGPoint,
        button: CGMouseButton,
        clickState: Int64 = 1
    ) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        // What makes a double click a double click is this field, not the gap
        // between two events — post two plain clicks and apps read two singles.
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.post(tap: .cghidEventTap)
    }

    /// Press and release with no hold in between. Turbo uses this; anything
    /// aimed at ordinary UI should hold the button briefly instead, since some
    /// controls drop a zero-length press.
    static func click(_ source: CGEventSource?, at point: CGPoint, button: ClickButton) {
        let (down, up, cgButton) = types(for: button)
        post(source, type: down, at: point, button: cgButton)
        post(source, type: up, at: point, button: cgButton)
    }
}
