import AppKit
import SwiftUI

@main
struct OneBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("OneBar Preferences", id: "preferences") {
            PreferencesWindow()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

struct MenuBarLabel: View {
    var body: some View {
        if AppState.shared.menubarLiveStats {
            let stats = SystemStatsService.shared
            // MenuBarExtra labels mangle both view stacks and inline images,
            // so the whole readout is pre-rendered into one template image.
            Image(nsImage: Self.statsImage(
                cpu: Int((stats.cpuUsage * 100).rounded()),
                mem: Int((stats.memUsage * 100).rounded())
            ))
        } else {
            Image(systemName: "gauge.medium")
        }
    }

    @MainActor
    private static func statsImage(cpu: Int, mem: Int) -> NSImage {
        let content = HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.system(size: 11, weight: .medium))
            Text("\(cpu)%")
            Image(systemName: "memorychip")
                .font(.system(size: 11, weight: .medium))
                .padding(.leading, 3)
            Text("\(mem)%")
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.black)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true // menubar recolors for light/dark + selection
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if AppState.shared.clipboardEnabled {
            ClipboardManager.shared.startPolling()
        }
        if AppState.shared.menubarLiveStats {
            SystemStatsService.shared.start()
        }
        HotkeyManager.shared.registerFromStore()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SleepPreventionManager.shared.stop()
        KeyboardCleaningManager.shared.stop()
        MouseMoveService.shared.stop()
        AutoClickService.shared.stop()
        ClickCanvasController.shared.close()
        ClipboardManager.shared.saveNow()
    }
}
