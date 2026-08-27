import AppKit
import SwiftUI

/// Name, icon and location for one registered script.
///
/// A sheet rather than more controls in the row: the path is the important part
/// of a custom action and the part most likely to go wrong, and a row wide
/// enough to show one leaves no room for anything else.
struct CustomActionEditor: View {
    let original: CustomShelfAction
    let onSave: (CustomShelfAction) -> Void
    let onCancel: () -> Void

    @State private var draft: CustomShelfAction
    @State private var missing: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    init(
        action: CustomShelfAction,
        onSave: @escaping (CustomShelfAction) -> Void,
        onCancel: @escaping () -> Void
    ) {
        original = action
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: action)
        _missing = State(initialValue: action.resolveURL() == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: draft.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(.quaternary)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(runnerDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                Text("Shown under the button and in the menus. Left empty, the file's own name is used.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(CustomShelfAction.symbolChoices, id: \.self) { choice in
                        Button {
                            draft.symbol = choice
                        } label: {
                            Image(systemName: choice)
                                .font(.system(size: 14))
                                .foregroundStyle(draft.symbol == choice ? Color.accentColor : .secondary)
                                .frame(width: 34, height: 30)
                                .background {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(draft.symbol == choice
                                            ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                                            : AnyShapeStyle(.quaternary))
                                }
                        }
                        .buttonStyle(.plain)
                        .help(choice)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Script")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: missing ? "exclamationmark.triangle.fill" : "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(missing ? .orange : .secondary)
                    Text(abbreviated(draft.path))
                        .font(.system(size: 11))
                        .foregroundStyle(missing ? .orange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                }
                HStack(spacing: 8) {
                    Button("Show in Finder") { reveal() }
                        .controlSize(.small)
                        .disabled(missing)
                    Button("Open") { open() }
                        .controlSize(.small)
                        .disabled(missing)
                        .help("Open the script in your usual editor")
                    Button("Choose Another…") { choose() }
                        .controlSize(.small)
                    Spacer()
                }
                if missing {
                    Text("This file is no longer where it was. Choose it again to point the action at it.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var displayName: String {
        CustomShelfAction.sanitised(name: draft.name, path: draft.path)
    }

    private var runnerDescription: String {
        switch draft.runner {
        case .shell: return "Shell script"
        case .automator: return "Automator workflow"
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func reveal() {
        guard let url = draft.resolveURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func open() {
        guard let url = draft.resolveURL() else { return }
        NSWorkspace.shared.open(url)
    }

    private func choose() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.treatsFilePackagesAsDirectories = false
        picker.message = "Choose a script or an Automator workflow"
        picker.prompt = "Choose"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        draft.path = url.standardizedFileURL.path
        missing = false
    }
}
