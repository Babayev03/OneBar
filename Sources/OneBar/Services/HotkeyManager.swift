import AppKit
import Carbon.HIToolbox
import Foundation

/// The global hotkeys OneBar can hold. Carbon identifies a hotkey by a numeric
/// id, so the raw values are the wire format — never renumber a shipped case.
enum GlobalHotkey: UInt32 {
    case openPanel = 1
    case autoClickStop = 2
    case openClickPoints = 3
    case turboClick = 4
}

/// Registers global hotkeys via Carbon — system-wide with no special
/// permissions, unlike an `NSEvent` monitor, which would drag in Input
/// Monitoring.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?

    private init() {}

    func registerFromStore() {
        register(.openPanel, binding: ShortcutStore.shared.binding(for: .openPanel)) {
            ClipboardPanelController.shared.toggle()
        }
        register(.openClickPoints, binding: ShortcutStore.shared.binding(for: .openClickPoints)) {
            ClickCanvasController.shared.toggle()
            // Nothing activated us — without this the canvas draws but its
            // controls stay dead behind whatever app is frontmost.
            if AppState.shared.autoClickEditing { NSApp.activate(ignoringOtherApps: true) }
        }
        register(.turboClick, binding: ShortcutStore.shared.binding(for: .turboClick)) {
            TurboClickService.shared.toggle()
        }
    }

    /// Re-registering the same hotkey replaces it, so callers can rebind without
    /// unregistering first.
    func register(_ hotkey: GlobalHotkey, binding: KeyBinding, action: @escaping () -> Void) {
        unregister(hotkey)
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x4F4E_4252) /* 'ONBR' */, id: hotkey.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            carbonModifiers(from: binding.modifiers),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            refs[hotkey.rawValue] = ref
            handlers[hotkey.rawValue] = action
        } else {
            NSLog("OneBar: failed to register global hotkey \(hotkey) (status \(status))")
        }
    }

    func unregister(_ hotkey: GlobalHotkey) {
        if let ref = refs.removeValue(forKey: hotkey.rawValue) {
            UnregisterEventHotKey(ref)
        }
        handlers[hotkey.rawValue] = nil
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                // The handler is a C function pointer and can't capture anything,
                // so the fired hotkey has to be read back out of the event.
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                let id = hotKeyID.id
                Task { @MainActor in HotkeyManager.shared.fire(id) }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}
