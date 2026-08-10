import SwiftUI

struct PreferencesWindow: View {
    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            ClipboardPane()
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            ShortcutsPane()
                .tabItem { Label("Shortcuts", systemImage: "command") }
        }
        .frame(width: 520, height: 460)
    }
}
