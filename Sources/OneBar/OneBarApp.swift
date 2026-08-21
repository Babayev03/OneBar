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
        // Replacing SwiftUI's own Quit item is what puts the confirmation in
        // front of ⌘Q. The menu is never drawn — an accessory app has none —
        // but its key equivalents still fire while one of our windows is key,
        // which is the only way ⌘Q reaches OneBar at all.
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit OneBar") {
                    QuitConfirmation.requestQuit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
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

        // Mops up after a previous run that was force quit or crashed:
        // the lid switch lives in the system and survives the process
        // that set it, and nothing else would ever put it back.
        Clamshell.setSleepDisabled(false)

        if AppState.shared.clipboardEnabled {
            ClipboardManager.shared.startPolling()
        }
        if AppState.shared.menubarLiveStats {
            SystemStatsService.shared.start()
        }
        BrightnessService.shared.start()
        // Before the first enumeration, or the strays are listed as devices for
        // the length of this launch.
        AppMixer.destroyLegacyGroupDevices()
        SoundService.shared.start()
        AppAudioService.shared.start()
        HotkeyManager.shared.registerFromStore()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SleepPreventionManager.shared.stop()
        // Belt and braces: the lid switch lives in the kernel, not in
        // this process, so a half-torn-down session must not be able to
        // leave it flipped.
        Clamshell.setSleepDisabled(false)
        KeyboardCleaningManager.shared.stop()
        MouseMoveService.shared.stop()
        AutoClickService.shared.stop()
        TurboClickService.shared.stop()
        ClickCanvasController.shared.close()
        BrightnessService.shared.restoreDimming()
        SoundService.shared.tearDown()
        // Taps mute the apps they are on, so leaving one behind would leave an
        // app silent with nothing left to un-silence it.
        AppAudioService.shared.tearDown()
        ClipboardManager.shared.saveNow()
    }
}
