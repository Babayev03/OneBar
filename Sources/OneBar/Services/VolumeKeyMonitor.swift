import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// `NX_SYSDEFINED`. The volume keys never arrive as key events, and
/// `CGEventType` has no case for this one; 14 is its raw value. See
/// `KeyboardCleaningManager`, which taps the same type to swallow it.
private let systemDefinedEventType: UInt32 = 14
/// `NX_SUBTYPE_AUX_CONTROL_BUTTONS` — volume, brightness, media, backlight.
private let auxControlSubtype: Int16 = 8

private let keyTypeSoundUp: Int32 = 0
private let keyTypeSoundDown: Int32 = 1
private let keyTypeMute: Int32 = 7

/// Makes the volume keys work while an output group is playing.
///
/// A group is an aggregate device, and an aggregate device has no volume
/// control of its own — so F11/F12 ask it to change its volume, it says it
/// can't, and macOS does nothing. The level is perfectly adjustable; macOS just
/// has no way to know that, because only `SoundService`'s fan-out knows the
/// group has members to reach past it to.
///
/// So the keys are caught here and handed to that same fan-out. The tap exists
/// **only while a group is the default output** — every other device answers
/// the keys itself, and taking them over then would be replacing working
/// behaviour with our own imitation of it.
@MainActor
final class VolumeKeyMonitor {
    static let shared = VolumeKeyMonitor()

    /// What one press moves the level by. macOS itself uses sixteenths.
    static let step = 1.0 / 16.0

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    private init() {}

    /// Silently does nothing without Accessibility — and deliberately does not
    /// prompt for it. Arriving at a permission dialog because you selected an
    /// audio device would be baffling; the keys simply stay as dead as they
    /// were, and the menu slider still works.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask = CGEventMask(1 << CGEventMask(systemDefinedEventType))

        // HID level for the same reason cleaning uses it: the system acts on
        // volume keys ahead of any session tap, so a session tap would see the
        // press too late to take it over.
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: volumeKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
    }

    fileprivate func reenableTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Returns true when the press was ours to act on, which is also the signal
    /// to swallow it.
    fileprivate func handle(keyType: Int32) -> Bool {
        // Cleaning mode swallows these keys on purpose so a wipe of the
        // keyboard doesn't change anything. It wins.
        guard !AppState.shared.keyboardCleaningActive else { return false }
        return SoundService.shared.handleVolumeKey(keyType: keyType)
    }
}

private func volumeKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<VolumeKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in monitor.reenableTap() }
        return Unmanaged.passUnretained(event)
    }

    guard type.rawValue == systemDefinedEventType,
          let nsEvent = NSEvent(cgEvent: event),
          nsEvent.subtype.rawValue == auxControlSubtype
    else {
        // This type also carries mouse and accessibility notifications.
        return Unmanaged.passUnretained(event)
    }

    // data1 packs the key and its state: the key in the high 16 bits, and in
    // the low ones a state of 0x0A for a press. Only presses count — acting on
    // the release too would move the level twice per tap.
    let data = nsEvent.data1
    let keyType = Int32((data & 0xFFFF_0000) >> 16)
    let isDown = ((data & 0x0000_FF00) >> 8) == 0x0A

    guard [keyTypeSoundUp, keyTypeSoundDown, keyTypeMute].contains(keyType) else {
        // Brightness, media and backlight keys ride the same subtype and are
        // none of our business.
        return Unmanaged.passUnretained(event)
    }

    guard isDown else { return nil }

    // The tap callback is not on the main actor, and the decision to swallow
    // has to be made now. The group is the only reason this tap exists at all,
    // so a press of one of these three keys is ours by definition; the hop just
    // carries out the change.
    Task { @MainActor in _ = monitor.handle(keyType: keyType) }
    return nil
}
