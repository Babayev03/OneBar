import AppKit
import Foundation

/// "Scan Text" / "Scan QR": interactive region screenshot → Vision → clipboard.
@MainActor
enum ScreenCaptureService {
    enum Mode {
        case text
        case qr
    }

    /// Keeps the running capture alive — a Process deallocated while still
    /// running raises an exception and crashes the app.
    private static var runningProcess: Process?

    static func scan(_ mode: Mode) {
        guard runningProcess == nil else { return } // one capture at a time
        let changeCountBefore = NSPasteboard.general.changeCount

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-c"] // interactive selection → clipboard
        process.terminationHandler = { _ in
            Task { @MainActor in
                runningProcess = nil
                await processCapture(mode, changeCountBefore: changeCountBefore)
            }
        }
        do {
            try process.run()
            runningProcess = process
        } catch {
            HUD.show("Couldn't start screen capture", symbol: "exclamationmark.triangle.fill")
        }
    }

    private static func processCapture(_ mode: Mode, changeCountBefore: Int) async {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCountBefore else { return } // user cancelled

        var imageData = pasteboard.data(forType: .png)
        if imageData == nil, let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            imageData = rep.representation(using: .png, properties: [:])
        }
        guard let imageData else {
            HUD.show("No screenshot captured", symbol: "exclamationmark.triangle.fill")
            return
        }

        let result = await ImageAnalysisService.analyze(imageData)

        switch mode {
        case .text:
            if let text = result.text {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                HUD.show("Text copied to clipboard", symbol: "text.viewfinder")
            } else {
                HUD.show("No text found", symbol: "eye.slash")
            }
        case .qr:
            if let payload = result.qrPayload {
                pasteboard.clearContents()
                pasteboard.setString(payload, forType: .string)
                HUD.show("QR content copied", symbol: "qrcode.viewfinder")
            } else {
                HUD.show("No QR code found", symbol: "eye.slash")
            }
        }
    }
}
