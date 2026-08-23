import SwiftUI
import UniformTypeIdentifiers

struct ShelfPane: View {
    private enum Section: String, CaseIterable, Identifiable {
        case activation = "Activation"
        case interaction = "Interaction"

        var id: String { rawValue }
    }

    private var state: AppState { AppState.shared }
    private var manager: ShelfManager { ShelfManager.shared }

    @State private var section: Section = .activation
    @State private var selectedApp: IgnoredApp.ID?

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView {
                VStack(spacing: 14) {
                    switch section {
                    case .activation: activation
                    case .interaction: interaction
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Activation

    private var activation: some View {
        VStack(spacing: 14) {
            GroupBox {
                VStack(spacing: 10) {
                    row("Enable shelf", subtitle: "A floating tray you can drop files, text and links onto while moving them somewhere else.") {
                        Toggle("", isOn: enabledBinding).toggleStyle(.switch).labelsHidden()
                    }
                    Divider()
                    row("Activate with shake gesture", subtitle: "Shake the cursor while dragging.") {
                        Toggle("", isOn: shakeBinding).toggleStyle(.switch).labelsHidden()
                    }
                    row("Sensitivity", subtitle: nil) {
                        Picker("", selection: sensitivityBinding) {
                            ForEach(ShakeSensitivity.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        .disabled(!state.shelfEnabled || !state.shelfShakeEnabled)
                    }
                    row("Default shelf location", subtitle: "For shelves created without shaking.") {
                        Picker("", selection: locationBinding) {
                            ForEach(ShelfLocation.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                }
                .padding(6)
            } label: {
                Text("Shelf Activation")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Ignored applications")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .help("Shaking while one of these apps is frontmost never opens a shelf.")
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
                    .frame(minHeight: 140)

                    HStack(spacing: 12) {
                        Button { addApp() } label: { Image(systemName: "plus") }
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
        }
    }

    // MARK: - Interaction

    private var interaction: some View {
        VStack(spacing: 14) {
            GroupBox {
                VStack(spacing: 10) {
                    row("Convert text to plain text", subtitle: "Dragged text keeps its formatting by default.") {
                        Toggle("", isOn: plainTextBinding).toggleStyle(.switch).labelsHidden()
                    }
                    Divider()
                    row(
                        "Always copy items when dragging out",
                        subtitle: "macOS moves items within a volume and copies them across volumes. Turn this on to always copy — holding ⌥ does the same for one drag."
                    ) {
                        Toggle("", isOn: alwaysCopyBinding).toggleStyle(.switch).labelsHidden()
                    }
                    row("Close shelf after dragging out", subtitle: nil) {
                        Picker("", selection: closeBehaviorBinding) {
                            ForEach(ShelfCloseBehavior.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 230)
                    }
                }
                .padding(6)
            } label: {
                Text("Shelf Interaction")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Close all shelves")
                            .font(.system(size: 14))
                        Text("Shelves hold references, so closing one never deletes the files you put on it. Anything OneBar wrote itself — dropped text and images — is cleaned up.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button { manager.closeAll() } label: { Text("Close All") }
                        .disabled(manager.shelves.isEmpty)
                }
                .padding(6)
            }
        }
    }

    // MARK: - Layout helper

    private func row<Control: View>(
        _ title: String,
        subtitle: String?,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Flexible label plus a priority control, rather than a Spacer:
            // a Spacer lets the label claim its unwrapped ideal width and
            // pushes the control off the trailing edge.
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .layoutPriority(1)
        }
    }

    // MARK: - Bindings

    /// Toggling the shelf or the shake has to re-register the mouse monitors —
    /// changing a setting does not reconfigure a service by itself here.
    private var enabledBinding: Binding<Bool> {
        Binding(get: { state.shelfEnabled }, set: {
            state.shelfEnabled = $0
            if !$0 { ShelfManager.shared.closeAll() }
            ShakeDetector.shared.restart()
        })
    }

    private var shakeBinding: Binding<Bool> {
        Binding(get: { state.shelfShakeEnabled }, set: {
            state.shelfShakeEnabled = $0
            ShakeDetector.shared.restart()
        })
    }

    private var sensitivityBinding: Binding<ShakeSensitivity> {
        Binding(get: { state.shelfShakeSensitivity }, set: { state.shelfShakeSensitivity = $0 })
    }

    private var locationBinding: Binding<ShelfLocation> {
        Binding(get: { state.shelfLocation }, set: { state.shelfLocation = $0 })
    }

    private var plainTextBinding: Binding<Bool> {
        Binding(get: { state.shelfPlainText }, set: { state.shelfPlainText = $0 })
    }

    private var alwaysCopyBinding: Binding<Bool> {
        Binding(get: { state.shelfAlwaysCopy }, set: { state.shelfAlwaysCopy = $0 })
    }

    private var closeBehaviorBinding: Binding<ShelfCloseBehavior> {
        Binding(get: { state.shelfCloseBehavior }, set: { state.shelfCloseBehavior = $0 })
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose apps where shaking should not open a shelf"

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

