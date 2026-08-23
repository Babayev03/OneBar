import SwiftUI

struct PreferencesWindow: View {
    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            ClipboardPane()
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            ShelfPane()
                .tabItem { Label("Shelf", systemImage: "tray.full") }
            AutomationPane()
                .tabItem { Label("Automation", systemImage: "cursorarrow.motionlines") }
            ShortcutsPane()
                .tabItem { Label("Shortcuts", systemImage: "command") }
        }
        .frame(width: 620, height: 520)
    }
}
