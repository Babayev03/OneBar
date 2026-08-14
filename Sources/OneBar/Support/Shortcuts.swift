import AppKit
import Foundation
import Observation

struct KeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifierRaw: UInt

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierRaw).intersection([.command, .shift, .option, .control])
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifierRaw = modifiers.intersection([.command, .shift, .option, .control]).rawValue
    }

    var display: String {
        var parts = ""
        let mods = modifiers
        if mods.contains(.control) { parts += "^" }
        if mods.contains(.option) { parts += "⌥" }
        if mods.contains(.shift) { parts += "⇧" }
        if mods.contains(.command) { parts += "⌘" }
        return parts + (parts.isEmpty ? "" : " ") + KeyBinding.keyName(keyCode)
    }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode &&
            event.modifierFlags.intersection([.command, .shift, .option, .control]) == modifiers
    }

    static func keyName(_ keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
            38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
            15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            36: "Enter", 76: "Enter", 51: "Delete", 117: "Del⌦", 53: "Esc", 49: "Space", 48: "Tab",
            126: "↑", 125: "↓", 123: "←", 124: "→",
            27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 50: "`"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case openPanel
    case search
    case moveUp
    case moveDown
    case selectItem
    case pasteOriginal
    case pastePlain
    case pastePlainDirect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openPanel: return "Open clipboard history"
        case .search: return "Search clipboard history"
        case .moveUp: return "Move up"
        case .moveDown: return "Move down"
        case .selectItem: return "Select item"
        case .pasteOriginal: return "Paste original"
        case .pastePlain: return "Paste plain text"
        case .pastePlainDirect: return "Paste plain text directly"
        }
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .openPanel: return KeyBinding(keyCode: 4, modifiers: [.command])   // ⌘H
        case .search: return KeyBinding(keyCode: 1)                             // S
        case .moveUp: return KeyBinding(keyCode: 126)                           // ↑
        case .moveDown: return KeyBinding(keyCode: 125)                         // ↓
        case .selectItem: return KeyBinding(keyCode: 36)                        // Enter
        case .pasteOriginal: return KeyBinding(keyCode: 31)                     // O
        case .pastePlain: return KeyBinding(keyCode: 35)                        // P
        case .pastePlainDirect: return KeyBinding(keyCode: 9, modifiers: [.control]) // ^V
        }
    }

    /// Global shortcuts need at least one modifier; in-panel keys may be bare.
    var isGlobal: Bool { self == .openPanel }
}

@MainActor
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()

    private static let defaultsKey = "shortcutBindings"

    private(set) var bindings: [ShortcutAction: KeyBinding]

    private init() {
        var loaded: [ShortcutAction: KeyBinding] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let raw = try? JSONDecoder().decode([String: KeyBinding].self, from: data) {
            for (key, value) in raw {
                if let action = ShortcutAction(rawValue: key) { loaded[action] = value }
            }
        }
        for action in ShortcutAction.allCases where loaded[action] == nil {
            loaded[action] = action.defaultBinding
        }
        bindings = loaded
    }

    func binding(for action: ShortcutAction) -> KeyBinding {
        bindings[action] ?? action.defaultBinding
    }

    func set(_ binding: KeyBinding, for action: ShortcutAction) {
        bindings[action] = binding
        save()
        if action == .openPanel {
            HotkeyManager.shared.registerFromStore()
        }
    }

    func reset(_ action: ShortcutAction) {
        set(action.defaultBinding, for: action)
    }

    private func save() {
        var raw: [String: KeyBinding] = [:]
        for (action, binding) in bindings { raw[action.rawValue] = binding }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
