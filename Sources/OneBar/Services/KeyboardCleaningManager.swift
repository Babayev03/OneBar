import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SwiftUI

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
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
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
    // Swallow the event.
    return nil
}
