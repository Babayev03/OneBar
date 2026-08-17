import AppKit

/// "Pick Color": the system loupe → the colour under the cursor, formatted
/// onto the clipboard. `ClipboardManager` polls `changeCount`, so the result
/// lands in history as an ordinary text item with nothing extra to do here.
@MainActor
enum ColorPickerService {
    /// One loupe at a time — a second `show` while the first is up stacks them.
    private static var sampling = false

    static func pick() {
        guard !sampling else { return }
        sampling = true
        NSColorSampler().show { color in
            Task { @MainActor in
                sampling = false
                // nil is Esc: a cancelled pick stays silent, the way a
                // cancelled `screencapture -i` does in ScreenCaptureService.
                guard let color else { return }
                copy(color)
            }
        }
    }

    private static func copy(_ color: NSColor) {
        // The sample comes back in the sampled display's own colour space, and
        // reading `redComponent` off a non-RGB colour traps — convert first.
        guard let rgb = color.usingColorSpace(.sRGB) else {
            HUD.show("Couldn't read that color", symbol: "exclamationmark.triangle.fill")
            return
        }

        let text = AppState.shared.colorPickerFormat.string(from: rgb)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        HUD.show("\(text) copied", symbol: "eyedropper")
    }
}
