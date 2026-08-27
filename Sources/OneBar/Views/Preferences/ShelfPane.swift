import SwiftUI
import UniformTypeIdentifiers

struct ShelfPane: View {
    private enum Section: String, CaseIterable, Identifiable {
        case activation = "Activation"
        case interaction = "Interaction"
        case actions = "Actions"
        case shelves = "Shelves"

        var id: String { rawValue }
    }

    private var state: AppState { AppState.shared }
    private var manager: ShelfManager { ShelfManager.shared }

    @State private var section: Section = .activation
    @State private var selectedApp: IgnoredApp.ID?
    @State private var hasNotchedDisplay = false
    /// Read once when the pane appears rather than on every redraw: measuring a
    /// folder walks it.
    @State private var outputFolderBytes = 0
    /// The Preferences preview is the strip itself, so what is shown here and
    /// what appears under a shelf cannot drift apart.
    @State private var previewModel = ShelfInstantActionBarModel()
    @State private var editingAction: CustomShelfAction?

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
                    case .actions: actions
                    case .shelves: shelves
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            refreshNotchAvailability()
            outputFolderBytes = ShelfStore.shared.outputFolderSize()
            refreshInstantActionPreview()
        }
        .onChange(of: state.shelfInstantActionIDs) { _, _ in
            refreshInstantActionPreview()
        }
        // Renaming or re-iconing a custom action changes a button too.
        .onChange(of: CustomActionStore.shared.actions) { _, _ in
            refreshInstantActionPreview()
        }
        .sheet(item: $editingAction) { action in
            CustomActionEditor(action: action) { edited in
                store.update(edited)
                editingAction = nil
            } onCancel: {
                editingAction = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            refreshNotchAvailability()
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
                    Divider()
                    row(
                        "Drop to notch",
                        subtitle: hasNotchedDisplay
                            ? "Drag files onto the notch to create a shelf. This remains available when shake activation is off."
                            : "Requires a display with a notch."
                    ) {
                        Toggle("", isOn: notchBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(!state.shelfEnabled || !hasNotchedDisplay)
                    }
                    row("Notch highlight", subtitle: nil) {
                        Picker("", selection: notchHighlightBinding) {
                            ForEach(NotchHighlight.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                        .disabled(
                            !state.shelfEnabled
                                || !state.shelfNotchDrop
                                || !hasNotchedDisplay
                        )
                    }
                    Divider()
                    row(
                        "New and notch shelf location",
                        subtitle: "Used by notch drops, New Shelf, and shelf shortcuts. A shake shelf opens at the cursor instead, but retracts to here."
                    ) {
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
                    Divider()
                    row("Use colour to distinguish shelves", subtitle: "Gives each open shelf its own indicator colour. A shelf you colour yourself keeps the colour you picked.") {
                        Toggle("", isOn: colorLabelsBinding).toggleStyle(.switch).labelsHidden()
                    }
                    row("New shelves open as", subtitle: nil) {
                        Picker("", selection: layoutBinding) {
                            ForEach(ShelfLayout.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                    Divider()
                    row("Automatically retract", subtitle: "After its first accepted drop, a new shelf moves aside once.") {
                        Toggle("", isOn: autoRetractBinding).toggleStyle(.switch).labelsHidden()
                    }
                    row("Move aside to", subtitle: "A shake happens wherever the pointer is, so “nearest” sends every shelf somewhere different. A settled edge stacks them together.") {
                        Picker("", selection: autoRetractEdgeBinding) {
                            ForEach(ShelfCollapseEdge.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    .disabled(!state.shelfAutoRetract)

                    Divider()

                    row("Snap into place", subtitle: "Aligns a shelf to display edges and other shelves after you move it. Hold ⌘ during that move to suppress snapping.") {
                        Toggle("", isOn: snapBinding).toggleStyle(.switch).labelsHidden()
                    }
                    row("Restrict to current Space", subtitle: "Applies to new shelves; each shelf can override it from Customize or its overflow menu.") {
                        Toggle("", isOn: keepInSpaceBinding).toggleStyle(.switch).labelsHidden()
                    }
                    row("Double-click shelf header", subtitle: nil) {
                        Picker("", selection: doubleClickBinding) {
                            ForEach(ShelfDoubleClickAction.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    Divider()
                    row("Show output in", subtitle: outputRevealNote) {
                        Picker("", selection: outputRevealBinding) {
                            ForEach(ShelfOutputReveal.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    if state.shelfOutputReveal.usesChosenFolder {
                        Divider()

                        row("Save action output in", subtitle: "Where Compress, Convert, Resize, Remove Metadata and Merge to PDF write. Convert and Resize can override it for one run.") {
                            HStack(spacing: 6) {
                                Text(outputFolderLabel)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Button("Choose…") { chooseOutputFolder() }
                                    .controlSize(.small)
                                if !state.shelfOutputFolder.isEmpty {
                                    Button("Reset") { state.shelfOutputFolder = "" }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }

                    Divider()

                    row(
                        "OneBar's output folder",
                        subtitle: "Holds \(outputFolderSize). Nothing here is deleted on its own — an output is a file you asked for. Clearing it leaves any shelf item that still points at one showing as missing."
                    ) {
                        HStack(spacing: 6) {
                            Button("Reveal") { revealOutputFolder() }
                                .controlSize(.small)
                            Button("Clear") { clearOutputFolder() }
                                .controlSize(.small)
                                .disabled(outputFolderBytes == 0)
                        }
                    }

                    Divider()

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

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    row(
                        "Show action buttons under a new shelf",
                        subtitle: "When a shake summons a shelf in the middle of a drag, a row of buttons appears beneath it. Dropping on one runs that action straight away — the files never land on the shelf."
                    ) {
                        Toggle("", isOn: instantActionsBinding).toggleStyle(.switch).labelsHidden()
                    }

                    if !instantActions.isEmpty {
                        Divider()
                        HStack {
                            Spacer()
                            ShelfInstantActionBarView(model: previewModel)
                            Spacer()
                        }
                        .opacity(state.shelfInstantActions ? 1 : 0.4)
                    }
                }
                .padding(6)
            } label: {
                Text("Instant Actions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if instantActions.isEmpty {
                        Text("No buttons — a shelf summoned mid-drag will appear on its own.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(Array(instantActions.enumerated()), id: \.element.id) { index, action in
                            HStack(spacing: 8) {
                                Image(systemName: action.symbol)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(action.activityLabel)
                                    .font(.system(size: 13))
                                Text(action.category.title)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Button {
                                    move(from: index, to: index - 1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                                .help("Move left in the strip")
                                Button {
                                    move(from: index, to: index + 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == instantActions.count - 1)
                                .help("Move right in the strip")
                                Button {
                                    state.shelfInstantActionIDs.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Take this button off the strip")
                            }
                        }
                    }

                    Divider()

                    HStack {
                        Menu("Add Button") {
                            ForEach(ShelfInstantAction.Category.allCases) { category in
                                let unused = unusedInstantActions.filter { $0.category == category }
                                if !unused.isEmpty {
                                    SwiftUI.Section(category.title) {
                                        ForEach(unused) { action in
                                            Button(action.activityLabel) {
                                                state.shelfInstantActionIDs.append(action.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: 130)
                        .disabled(
                            unusedInstantActions.isEmpty
                                || instantActions.count >= ShelfInstantAction.maxCount
                        )
                        Spacer()
                        Button("Restore Defaults") {
                            state.shelfInstantActionIDs = ShelfInstantAction.defaultIDs
                        }
                        .controlSize(.small)
                    }

                    Text("Up to \(ShelfInstantAction.maxCount) buttons. Convert Image and Resize Image themselves are not offered here — they open a dialog, and a drop that asks a question is not instant.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            } label: {
                Text("Buttons")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            customActions
        }
        .disabled(!state.shelfEnabled)
    }

    // MARK: - Custom actions

    private var customActions: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("A script of your own, run over whatever you drop on it. The files arrive as arguments, and anything it leaves in $ONEBAR_OUTPUT_DIR comes back onto the shelf. Shell scripts and Automator workflows both work.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.actions.isEmpty {
                    Text("No custom actions")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(store.actions) { action in
                        customActionRow(action)
                    }
                }

                Divider()

                HStack {
                    Button("Add…") { addCustomAction() }
                        .controlSize(.small)
                    Button("Example Script") { writeExampleScript() }
                        .controlSize(.small)
                        .help("Writes a working script to your Desktop and adds it, so there is something to try")
                    Spacer()
                    Button("Reveal scripts.json") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.revealURL])
                    }
                    .controlSize(.small)
                }

                Text("A custom action runs with your own privileges on the files you give it. Only add scripts you have read.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        } label: {
            Text("Custom Actions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func customActionRow(_ action: CustomShelfAction) -> some View {
        let missing = action.resolveURL() == nil
        HStack(spacing: 8) {
            Image(systemName: action.symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(action.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help("This script is no longer where it was")
            }
            Spacer()
            Button { editingAction = action } label: {
                Label("Edit", systemImage: "pencil")
            }
            .controlSize(.small)
            .help("Change the name, icon or script this action uses")
            Button { store.move(action.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(store.actions.first?.id == action.id)
            Button { store.move(action.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(store.actions.last?.id == action.id)
            Button { store.remove(action.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove this action. The script itself is left alone.")
        }
    }

    private var store: CustomActionStore { CustomActionStore.shared }

    private func addCustomAction() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.treatsFilePackagesAsDirectories = false
        picker.message = "Choose a script or an Automator workflow"
        picker.prompt = "Add"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        // Straight into the editor: a script added from a picker has the file's
        // name and a default icon, which is exactly the state somebody wants to
        // change immediately.
        editingAction = store.add(path: url.path)
    }

    /// Somewhere to start. Registering a working script is the fastest way to
    /// see what the contract actually is, and it saves a first attempt failing
    /// on a missing executable bit or a misremembered variable name.
    private func writeExampleScript() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/OneBar Example Action.sh")
        let script = """
        #!/bin/sh
        # A OneBar custom action.
        #
        # The files you dropped arrive as arguments.
        # Anything written to $ONEBAR_OUTPUT_DIR comes back onto the shelf.
        # Anything printed here is shown only if the script fails.

        for f in "$@"; do
          name=$(basename "$f")
          sips -Z 800 "$f" --out "$ONEBAR_OUTPUT_DIR/$name" >/dev/null
        done

        """
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            HUD.show("Could not write the example", symbol: "exclamationmark.triangle")
            return
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        store.add(path: url.path, name: "Shrink to 800px", symbol: "photo")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var instantActions: [ShelfInstantAction] {
        ShelfInstantAction.resolve(state.shelfInstantActionIDs)
    }

    private var unusedInstantActions: [ShelfInstantAction] {
        let used = Set(state.shelfInstantActionIDs)
        return ShelfInstantAction.catalogue.filter { !used.contains($0.id) }
    }

    private func move(from index: Int, to destination: Int) {
        var ids = state.shelfInstantActionIDs
        guard ids.indices.contains(index), ids.indices.contains(destination) else { return }
        ids.swapAt(index, destination)
        state.shelfInstantActionIDs = ids
    }

    private var instantActionsBinding: Binding<Bool> {
        Binding(get: { state.shelfInstantActions }, set: { state.shelfInstantActions = $0 })
    }

    // MARK: - Shelves

    private var shelves: some View {
        VStack(spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    row(
                        "Maximum shelves at once",
                        subtitle: "Note: every open shelf is a live window that redraws along with everything else on screen, and a docked one keeps watching the pointer. A lot of them at once costs frame rate. Five is a comfortable number; raise it only if you need to, and expect it to be felt."
                    ) {
                        HStack(spacing: 6) {
                            Text("\(state.shelfMaxCount)")
                                .font(.system(size: 12).monospacedDigit())
                                .frame(width: 18, alignment: .trailing)
                            Stepper("", value: maxCountBinding, in: 1...20)
                                .labelsHidden()
                        }
                    }

                    Divider()

                    HStack {
                        Text(shelfCountSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("New Shelf") { manager.newShelf(at: nil) }
                            .controlSize(.small)
                            .disabled(!state.shelfEnabled || manager.isAtShelfLimit)
                    }
                    Divider()
                    if manager.shelves.isEmpty {
                        Text("No shelves open")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(manager.shelves, id: \.id) { shelf in
                            HStack(spacing: 8) {
                                Circle().fill(shelf.model.color).frame(width: 8, height: 8)
                                Text(shelf.model.title)
                                    .font(.system(size: 13))
                                Text(shelf.model.items.count == 1 ? "1 item" : "\(shelf.model.items.count) items")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                if shelf.model.isPinned {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Close") { manager.close(shelf) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(6)
            } label: {
                Text("Open Shelves")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if manager.pinned.isEmpty {
                        Text("No pinned shelves are closed")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(manager.pinned) { snapshot in
                            HStack(spacing: 8) {
                                Circle().fill(ShelfManager.color(named: snapshot.colorName))
                                    .frame(width: 8, height: 8)
                                Text(snapshot.displayName)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Spacer()
                                Button("Reopen") { manager.reopen(snapshot) }
                                    .controlSize(.small)
                                    .disabled(!state.shelfEnabled)
                                Button { manager.forget(snapshot) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Forget this pinned shelf")
                            }
                        }
                    }
                }
                .padding(6)
            } label: {
                Text("Closed Pinned Shelves")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A shelf you close is kept here for a while, so closing one you still needed is not final. Pinned shelves come back on their own at launch and never appear in this list.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if manager.recent.isEmpty {
                        Text("Nothing closed recently")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(manager.recent) { snapshot in
                            HStack(spacing: 8) {
                                Circle().fill(ShelfManager.color(named: snapshot.colorName))
                                    .frame(width: 8, height: 8)
                                Text(snapshot.displayName)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("Reopen") { manager.reopen(snapshot) }
                                    .controlSize(.small)
                                    .disabled(!state.shelfEnabled)
                                Button {
                                    manager.forget(snapshot)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Forget this shelf and delete anything OneBar wrote for it")
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Clear List") { manager.clearRecents() }
                                .controlSize(.small)
                        }
                    }
                }
                .padding(6)
            } label: {
                Text("Recently Closed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Layout helper

    private func refreshInstantActionPreview() {
        previewModel.actions = instantActions
        previewModel.color = AppState.shared.accentColor
        previewModel.forcesAvailable = true
    }

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
            ShelfManager.shared.setEnabled($0)
        })
    }

    private var shakeBinding: Binding<Bool> {
        Binding(get: { state.shelfShakeEnabled }, set: {
            state.shelfShakeEnabled = $0
            ShelfDragObserver.shared.restart()
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

    private var colorLabelsBinding: Binding<Bool> {
        Binding(get: { state.shelfColorLabels }, set: {
            state.shelfColorLabels = $0
            manager.setColorLabels($0)
        })
    }

    private var outputFolderSize: String {
        let bytes = outputFolderBytes
        guard bytes > 0 else { return "nothing yet" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func revealOutputFolder() {
        let directory = ShelfStore.shared.outputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
    }

    private func clearOutputFolder() {
        let removed = ShelfStore.shared.clearOutputFolder()
        outputFolderBytes = ShelfStore.shared.outputFolderSize()
        HUD.show(
            removed == 1 ? "Removed 1 file" : "Removed \(removed) files",
            symbol: "trash"
        )
    }

    private var shelfCountSummary: String {
        let open = manager.shelves.count
        let limit = state.shelfMaxCount
        guard open < limit else { return "All \(limit) shelves are open." }
        return "\(open) of \(limit) open. Create an empty shelf at the default location."
    }

    private var maxCountBinding: Binding<Int> {
        Binding(get: { state.shelfMaxCount }, set: { state.shelfMaxCount = max(1, $0) })
    }

    private var autoRetractEdgeBinding: Binding<ShelfCollapseEdge> {
        Binding(get: { state.shelfAutoRetractEdge }, set: { state.shelfAutoRetractEdge = $0 })
    }

    private var outputRevealBinding: Binding<ShelfOutputReveal> {
        Binding(get: { state.shelfOutputReveal }, set: { state.shelfOutputReveal = $0 })
    }

    /// Finder only reveals a result that went somewhere to be found. One left
    /// in OneBar's own folder is already on the shelf, and opening a Library
    /// path on top of that helps nobody — so the setting quietly does less, and
    /// says so rather than looking broken.
    private var outputRevealNote: String? {
        guard state.shelfOutputReveal == .both, state.shelfOutputFolder.isEmpty else { return nil }
        return "With no folder chosen, output stays in OneBar's own folder and Finder is not opened — the result is on the shelf. Choose a folder below to have it revealed."
    }

    private var outputFolderLabel: String {
        let path = state.shelfOutputFolder
        guard !path.isEmpty else { return "OneBar's output folder" }
        return URL(filePath: path).lastPathComponent
    }

    private func chooseOutputFolder() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = "Choose"
        picker.message = "Where should action output be saved?"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        state.shelfOutputFolder = url.path
    }

    private var layoutBinding: Binding<ShelfLayout> {
        Binding(get: { state.shelfLayout }, set: { state.shelfLayout = $0 })
    }

    private var autoRetractBinding: Binding<Bool> {
        Binding(get: { state.shelfAutoRetract }, set: { state.shelfAutoRetract = $0 })
    }

    private var snapBinding: Binding<Bool> {
        Binding(get: { state.shelfSnap }, set: { state.shelfSnap = $0 })
    }

    private var keepInSpaceBinding: Binding<Bool> {
        Binding(get: { state.shelfKeepInSpace }, set: { state.shelfKeepInSpace = $0 })
    }

    private var doubleClickBinding: Binding<ShelfDoubleClickAction> {
        Binding(get: { state.shelfDoubleClick }, set: { state.shelfDoubleClick = $0 })
    }

    private var notchBinding: Binding<Bool> {
        Binding(get: { state.shelfNotchDrop }, set: {
            state.shelfNotchDrop = $0
            ShelfDragObserver.shared.restart()
        })
    }

    private var notchHighlightBinding: Binding<NotchHighlight> {
        Binding(get: { state.shelfNotchHighlight }, set: { state.shelfNotchHighlight = $0 })
    }

    private func refreshNotchAvailability() {
        hasNotchedDisplay = ShelfWindowGeometry.hasNotchedDisplay
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
