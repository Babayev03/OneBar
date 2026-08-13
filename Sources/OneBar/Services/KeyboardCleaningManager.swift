import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SwiftUI

/// `NX_SYSDEFINED` — volume, brightness, media and eject keys never arrive as
/// key events, so the tap has to ask for this type explicitly. CGEventType has
/// no case for it; 14 is its raw value.
private let systemDefinedEventType: UInt32 = 14

/// System-defined subtypes that are a physical button press we want to swallow.
///
/// Mouse subtypes (`NX_SUBTYPE_AUX_MOUSE_BUTTONS`, 7) are deliberately absent —
/// exiting cleaning mode is mouse-only. Touch ID is absent because a fingerprint
/// read produces no CGEvent at all: it goes straight to the Secure Enclave and
/// never reaches an event tap, so it keeps working while everything else is
/// dead. Only a physical *press* of that same button emits an event, and that
/// is subtype 1 below.
private let blockedSystemDefinedSubtypes: Set<Int16> = [
    1,  // NX_SUBTYPE_POWER_KEY — power button press (not the fingerprint read)
    8,  // NX_SUBTYPE_AUX_CONTROL_BUTTONS — volume, brightness, media, keyboard backlight
    10  // NX_SUBTYPE_EJECT_KEY
]

/// Swallows every key event system-wide via a CGEventTap while a dimmed
/// overlay tells the user cleaning mode is on. Exit is mouse-only.
@MainActor
final class KeyboardCleaningManager {
    static let shared = KeyboardCleaningManager()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var overlayWindows: [NSWindow] = []

    var isActive: Bool { tap != nil }

    private init() {}

    /// Returns false when the Accessibility permission is missing (and prompts for it).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventMask(systemDefinedEventType))

        // HID level, not session level: volume and brightness are acted on by the
        // system itself, which sits ahead of the session tap, so a session tap
        // sees those presses too late to suppress them.
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cleaningTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        showOverlay()
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil

        for window in overlayWindows { window.orderOut(nil) }
        overlayWindows = []

        if AppState.shared.keyboardCleaningActive {
            AppState.shared.keyboardCleaningActive = false
        }
    }

    fileprivate func reenableTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func showOverlay() {
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(
                rootView: KeyboardCleaningOverlay { [weak self] in
                    Task { @MainActor in self?.stop() }
                }
            )
            window.makeKeyAndOrderFront(nil)
            overlayWindows.append(window)
        }
    }
}

private func cleaningTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon {
            let manager = Unmanaged<KeyboardCleaningManager>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in manager.reenableTap() }
        }
        return Unmanaged.passUnretained(event)
    }

    if type.rawValue == systemDefinedEventType {
        // Pass anything that isn't a hardware button through untouched: this
        // type also carries mouse and accessibility notifications.
        guard let subtype = NSEvent(cgEvent: event)?.subtype.rawValue,
              blockedSystemDefinedSubtypes.contains(subtype)
        else {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    // Swallow the key event.
    return nil
}
