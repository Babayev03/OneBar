import SwiftUI
import UniformTypeIdentifiers

struct ClipboardPane: View {
    private var manager: ClipboardManager { ClipboardManager.shared }
    @State private var selectedApp: IgnoredApp.ID?

    var body: some View {
        VStack(spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Ignored apps")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .help("Copies made while one of these apps is frontmost are never recorded.")
                    }
                    .padding(.bottom, 8)

                    List(selection: $selectedApp) {
                        ForEach(manager.ignoredApps) { app in
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                Text(app.name)
                                    .font(.system(size: 13))
                            }
                            .tag(app.id)
                        }
                    }
                    .listStyle(.bordered)
                    .frame(minHeight: 180)

                    HStack(spacing: 12) {
                        Button {
                            addApp()
                        } label: {
                            Image(systemName: "plus")
                        }
                        Button {
                            if let selectedApp,
                               let app = manager.ignoredApps.first(where: { $0.id == selectedApp }) {
                                manager.removeIgnoredApp(app)
                            }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .disabled(selectedApp == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 8)
                }
                .padding(6)
            }

            GroupBox {
                VStack(spacing: 10) {
                    HStack {
                        Text("Keep images")
                            .font(.system(size: 14))
                        Spacer()
                        Text("\(AppState.shared.maxImages)")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Stepper("", value: imageLimitBinding, in: 5...100, step: 5)
                            .labelsHidden()
                    }

                    HStack {
                        Text("History limit")
                            .font(.system(size: 14))
                        Spacer()
                        Picker("", selection: historyCapBinding) {
                            Text("Unlimited").tag(0)
                            Text("200 items").tag(200)
                            Text("500 items").tag(500)
                            Text("1000 items").tag(1000)
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
                .padding(6)
            } label: {
                Text("Retention")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Clear history")
                            .font(.system(size: 14))
                        Text("Removes all unpinned items. History also clears automatically when the Mac restarts; pinned items always survive.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        manager.clearHistory()
                    } label: {
                        Text("Clear")
                    }
                }
                .padding(6)
            }

            Spacer()
        }
        .padding(20)
    }

    private var imageLimitBinding: Binding<Int> {
        Binding(get: { AppState.shared.maxImages }, set: { AppState.shared.maxImages = $0 })
    }

    private var historyCapBinding: Binding<Int> {
        Binding(get: { AppState.shared.historyCap }, set: { AppState.shared.historyCap = $0 })
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose apps whose copies should be ignored"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
            let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            manager.addIgnoredApp(bundleID: bundleID, name: name, path: url.path)
        }
    }
}
