import AppKit
import ApplicationServices
import Foundation

@MainActor
enum PasteService {
    /// Writes the item to the pasteboard, hides the panel, and synthesizes ⌘V
    /// into the frontmost app. Falls back to copy-only when Accessibility
    /// permission hasn't been granted.
    static func paste(_ item: ClipboardItem, plainText: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            if plainText {
                return
            }
            guard let url = ClipboardStore.shared.imageURL(for: item),
                  let data = try? Data(contentsOf: url) else { return }
            pasteboard.setData(data, forType: .png)
            if let rep = NSBitmapImageRep(data: data), let tiff = rep.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }

        ClipboardPanelController.shared.hide()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Task { @MainActor in postCommandV() }
        }
    }

    static func postCommandV() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // V
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
